defmodule DarkChonkyWhale.AgentLoop do
  @moduledoc """
  The default driver: runs a turn as a sequence of steps — stream a model
  response, append it to the session log, execute its tool calls through the
  tools pipeline, append their results, repeat — until the model answers
  without calling tools, or the step budget runs out.

  The loop reads the model's view from the session projection
  (`Session.messages/1`) and keeps no history of its own: model-visible
  means logged.
  """

  alias DarkChonkyWhale.{Session, ToolResult, Tools}
  alias DarkChonkyWhale.LLM.Client
  alias ReqLLM.Message.ReasoningDetails
  alias ReqLLM.Provider.ChunkAccumulator
  alias ReqLLM.{StreamChunk, StreamResponse, ToolCall}

  @default_max_steps 100

  @doc """
  Run one turn: seals any unsettled tool calls from an earlier interrupted
  turn, logs `:"turn/start"`, runs the step loop, then seals any mid-turn
  interrupted calls and logs `:"turn/end"` (even when the loop errors).
  Returns `{:ok, final_text}` or `{:error, _}`.

  Options:

    * `:max_steps` — step budget for the turn (default #{@default_max_steps})
  """
  @spec run(Client.t(), pid(), Tools.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(%Client{} = client, session, %Tools{} = tools, opts \\ []) do
    max_steps = Keyword.get(opts, :max_steps, @default_max_steps)
    {:ok, _} = Session.seal_unsettled(session)
    {:ok, _} = Session.append(session, :"turn/start", %{})

    try do
      steps(client, session, tools, max_steps, 0)
    after
      # Best-effort bookkeeping: if the session died mid-turn, the original
      # error must not be masked by a failure to close the turn.
      try do
        Session.seal_unsettled(session)
        Session.append(session, :"turn/end", %{})
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp steps(_client, _session, _tools, max, max), do: {:error, :max_steps_exceeded}

  defp steps(client, session, tools, max_steps, n) do
    {:ok, _} = Session.append(session, :"step/start", %{"n" => n})

    with {:ok, tool_specs} <- tool_specs(tools),
         {:ok, response} <- Client.stream(client, Session.messages(session), tools: tool_specs),
         {:ok, classified} <- consume_stream(response) do
      settle(classified, client, session, tools, max_steps, n)
    end
  end

  defp settle(%{type: :final_answer} = result, _client, session, _tools, _max, _n) do
    append_assistant(session, result)
    {:ok, result.text}
  end

  defp settle(%{type: :tool_calls} = result, client, session, tools, max_steps, n) do
    append_assistant(session, result)
    execute_calls(session, tools, result.tool_calls)
    steps(client, session, tools, max_steps, n + 1)
  end

  defp consume_stream(%StreamResponse{stream: stream, model: model} = response) do
    try do
      chunks = Enum.to_list(stream)
      acc = ChunkAccumulator.reduce(ChunkAccumulator.new(), chunks)

      text = ChunkAccumulator.finalize_text(acc)
      thinking = ChunkAccumulator.finalize_thinking(acc)
      tool_calls = ChunkAccumulator.finalize_tool_calls_for_response(acc)
      finish_reason = ChunkAccumulator.finalize_finish_reason(acc)
      reasoning_details = extract_reasoning_details(acc, chunks, model)

      actionable_tool_calls = Enum.reject(tool_calls, &ToolCall.flagged_builtin?/1)

      type =
        if actionable_tool_calls != [] or
             finish_reason in [:tool_calls, "tool_calls", :tool_use, "tool_use"] do
          :tool_calls
        else
          :final_answer
        end

      {:ok,
       %{
         type: type,
         text: text,
         thinking: thinking,
         reasoning_details: reasoning_details,
         tool_calls: tool_calls
       }}
    rescue
      error in [ReqLLM.Error.API.Stream, ReqLLM.Error.API.Request, ReqLLM.Error.API.Timeout] ->
        {:error, error}
    after
      if response.metadata_handle, do: StreamResponse.close(response)
    end
  end

  defp extract_reasoning_details(acc, chunks, model) do
    case ChunkAccumulator.finalize_reasoning_details(acc) do
      details when is_list(details) and details != [] ->
        details

      _ ->
        extract_reasoning_from_thinking_chunks(chunks, provider_of(model))
    end
  end

  defp extract_reasoning_from_thinking_chunks(chunks, provider) do
    thinking_chunks =
      Enum.filter(chunks, fn
        %StreamChunk{type: :thinking} -> true
        _ -> false
      end)

    case thinking_chunks do
      [] ->
        []

      list ->
        text = Enum.map_join(list, "", &(&1.text || ""))

        merged_meta =
          Enum.reduce(list, %{}, fn %StreamChunk{metadata: meta}, acc ->
            Map.merge(acc, meta || %{})
          end)

        signature = merged_meta[:signature] || merged_meta["signature"]

        if signature != nil or Map.has_key?(merged_meta, :provider) do
          [
            %ReasoningDetails{
              text: text,
              signature: signature,
              encrypted?: (merged_meta[:encrypted?] || signature != nil) == true,
              provider: merged_meta[:provider] || provider,
              format: merged_meta[:format],
              index: 0,
              provider_data: merged_meta[:provider_data] || %{}
            }
          ]
        else
          []
        end
    end
  end

  defp provider_of(%{provider: provider}) when is_atom(provider), do: provider
  defp provider_of(_model), do: nil

  defp append_assistant(session, result) do
    data =
      %{
        "content" => result.text,
        "tool_calls" =>
          Enum.map(result.tool_calls, fn call ->
            %{"id" => call.id, "name" => call.name, "input" => call.arguments}
            |> maybe_put_call_metadata(Map.get(call, :metadata))
          end)
      }
      |> maybe_put_thinking(Map.get(result, :thinking))
      |> maybe_put_reasoning_details(Map.get(result, :reasoning_details))

    {:ok, _} = Session.append(session, :"assistant/message", data)
  end

  defp maybe_put_call_metadata(map, meta) when is_map(meta) and map_size(meta) > 0 do
    Map.put(map, "metadata", stringify_keys(meta))
  end

  defp maybe_put_call_metadata(map, _meta), do: map

  defp maybe_put_thinking(map, thinking) when is_binary(thinking) and thinking != "" do
    Map.put(map, "thinking", thinking)
  end

  defp maybe_put_thinking(map, _thinking), do: map

  defp maybe_put_reasoning_details(map, details) when is_list(details) and details != [] do
    Map.put(map, "reasoning_details", Enum.map(details, &encode_reasoning_detail/1))
  end

  defp maybe_put_reasoning_details(map, _details), do: map

  defp encode_reasoning_detail(%ReasoningDetails{} = detail) do
    %{
      "text" => detail.text,
      "signature" => detail.signature,
      "encrypted" => detail.encrypted? == true,
      "provider" => detail.provider && to_string(detail.provider),
      "format" => detail.format,
      "index" => detail.index || 0,
      "provider_data" => stringify_keys(detail.provider_data || %{})
    }
  end

  defp encode_reasoning_detail(detail) when is_map(detail), do: stringify_keys(detail)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {to_string(k), stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp execute_calls(_session, _tools, []), do: :ok

  defp execute_calls(session, tools, [call]) do
    result = Tools.execute(tools, call.name, call.arguments)
    append_tool_result(session, call, result)
  end

  defp execute_calls(session, tools, calls) do
    calls
    |> Task.async_stream(
      fn call -> {call, Tools.execute(tools, call.name, call.arguments)} end,
      timeout: :infinity,
      ordered: true
    )
    |> Enum.each(fn {:ok, {call, result}} ->
      append_tool_result(session, call, result)
    end)

    :ok
  end

  defp append_tool_result(session, call, result) do
    {:ok, _} =
      Session.append(session, :"tool/result", %{
        "message" => ToolResult.from_result(call.id, call.name, result)
      })

    :ok
  end

  # Our Tool schemas are already JSON Schema maps, which ReqLLM.tool/1
  # accepts directly as :parameter_schema. ReqLLM requires a :callback for
  # its own local-execution path; ours never runs (execution goes through
  # the Tools pipeline), so a placeholder satisfies the validation.
  # ReqLLM.tool/1 raises on an invalid schema — a programming error, which
  # the run's `after` still closes the turn around.
  defp tool_specs(tools) do
    {:ok,
     Enum.map(Tools.schemas(tools), fn schema ->
       ReqLLM.tool(
         name: schema.name,
         description: schema.description,
         parameter_schema: schema.parameters,
         callback: fn _args -> nil end
       )
     end)}
  end
end
