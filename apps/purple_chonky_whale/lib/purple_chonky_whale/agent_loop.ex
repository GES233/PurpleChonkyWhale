defmodule PurpleChonkyWhale.AgentLoop do
  @moduledoc """
  The default driver: runs a turn as a sequence of steps — stream a model
  response, append it to the session log, execute its tool calls through the
  tools pipeline, append their results, repeat — until the model answers
  without calling tools, or the step budget runs out.

  The loop reads the model's view from the session projection
  (`Session.messages/1`) and keeps no history of its own: model-visible
  means logged.
  """

  alias PurpleChonkyWhale.{Session, ToolResult, Tools}
  alias PurpleChonkyWhale.LLM.Client
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
    * `:run_id` — optional execution identifier threaded through events and
      persisted records
    * `:session_id` — optional session identifier override (defaults to
      `Session.id(session)`)
    * `:tool_concurrency` — maximum concurrent tool calls in a batch
      (default `System.schedulers_online()`)
    * `:on_stream` — optional `(StreamResponse.t() -> any())` callback invoked
      when a provider stream opens and `(nil -> any())` when it closes
    * `:on_tool_start` — optional `(String.t(), pid() -> any())` callback
      invoked when a tool call begins executing
    * `:should_cancel?` — optional `(-> false | {:cancel, term()})` predicate
      polled at step, chunk, and tool boundaries
  """
  @spec run(Client.t(), pid(), Tools.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(%Client{} = client, session, %Tools{} = tools, opts \\ []) do
    max_steps = Keyword.get(opts, :max_steps, @default_max_steps)
    run_id = Keyword.get(opts, :run_id)
    session_id = Keyword.get(opts, :session_id) || safe_session_id(session)

    client = Client.with_context(client, %{session_id: session_id, run_id: run_id})
    tools = Tools.with_env(tools, %{session_id: session_id, run_id: run_id})

    tracker = :ets.new(:pcw_turn_tracker, [:set, :public])

    loop_ctx = %{
      run_id: run_id,
      session_id: session_id,
      tracker: tracker,
      tool_specs: [],
      tool_concurrency: Keyword.get(opts, :tool_concurrency, System.schedulers_online()),
      on_stream: Keyword.get(opts, :on_stream, fn _ -> :ok end),
      on_tool_start: Keyword.get(opts, :on_tool_start, fn _, _ -> :ok end),
      should_cancel?: Keyword.get(opts, :should_cancel?, fn -> false end)
    }

    {:ok, _} = Session.seal_unsettled(session, type: :outcome_unknown, run_id: run_id)
    {:ok, _} = Session.append(session, :"turn/start", maybe_put_run_id(%{}, run_id))

    try do
      # Built once per run, not once per step: the tool list never changes
      # mid-turn, and rebuilding ReqLLM specs on every step is pure waste
      # (a hundred steps × a dozen tools, plus whatever MCP merged in).
      steps(client, session, tools, max_steps, 0, %{loop_ctx | tool_specs: tool_specs!(tools)})
    after
      # Best-effort bookkeeping: if the session died mid-turn, the original
      # error must not be masked by a failure to close the turn.
      try do
        stop_active_tool_tasks(tracker)
        started_ids = started_call_ids(tracker)
        :ets.delete(tracker)

        seal_reason =
          case loop_ctx.should_cancel?.() do
            {:cancel, reason} -> format_cancel_reason(reason)
            _ -> "tool call interrupted before completion"
          end

        Session.seal_unsettled(session,
          run_id: run_id,
          started_call_ids: started_ids,
          reason: seal_reason
        )

        Session.append(session, :"turn/end", maybe_put_run_id(%{}, run_id))
      catch
        :exit, _ -> :ok
        :error, _ -> :ok
      end
    end
  end

  defp safe_session_id(session) do
    Session.id(session)
  catch
    :exit, _ -> nil
  end

  defp maybe_put_run_id(map, nil), do: map
  defp maybe_put_run_id(map, run_id), do: Map.put(map, "runId", to_string(run_id))

  defp started_call_ids(tracker) do
    tracker
    |> :ets.match({{:started, :"$1"}, :_})
    |> List.flatten()
    |> MapSet.new(&to_string/1)
  end

  defp stop_active_tool_tasks(tracker) do
    active_pids =
      tracker
      |> :ets.match({{:active_task, :_}, :"$1"})
      |> List.flatten()

    Enum.each(active_pids, fn pid ->
      if pid != self() and Process.alive?(pid) do
        ref = Process.monitor(pid)
        Process.exit(pid, :shutdown)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          500 ->
            Process.exit(pid, :kill)
            Process.demonitor(ref, [:flush])
        end
      end
    end)
  end

  defp format_cancel_reason(reason) when is_binary(reason), do: reason
  defp format_cancel_reason(reason), do: "cancelled: #{inspect(reason)}"

  defp steps(_client, _session, _tools, max, max, _loop_ctx), do: {:error, :max_steps_exceeded}

  defp steps(client, session, tools, max_steps, n, loop_ctx) do
    case loop_ctx.should_cancel?.() do
      {:cancel, reason} ->
        {:error, {:cancelled, reason}}

      false ->
        {:ok, _} =
          Session.append(
            session,
            :"step/start",
            maybe_put_run_id(%{"n" => n}, loop_ctx.run_id)
          )

        with {:ok, response} <-
               Client.stream(client, Session.messages(session), tools: loop_ctx.tool_specs),
             {:ok, classified} <- consume_stream(response, loop_ctx) do
          settle(classified, client, session, tools, max_steps, n, loop_ctx)
        end
    end
  end

  defp settle(%{type: :final_answer} = result, _client, session, _tools, _max, _n, loop_ctx) do
    append_assistant(session, result, loop_ctx.run_id)
    {:ok, result.text}
  end

  defp settle(%{type: :tool_calls} = result, client, session, tools, max_steps, n, loop_ctx) do
    append_assistant(session, result, loop_ctx.run_id)

    case execute_calls(session, tools, result.tool_calls, loop_ctx) do
      :ok ->
        steps(client, session, tools, max_steps, n + 1, loop_ctx)

      {:error, _} = error ->
        error
    end
  end

  defp consume_stream(%StreamResponse{stream: stream, model: model} = response, loop_ctx) do
    try do
      case collect_chunks(stream, response, loop_ctx) do
        {:ok, chunks} ->
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

        {:error, _} = error ->
          error
      end
    after
      loop_ctx.on_stream.(nil)
      if response.metadata_handle, do: StreamResponse.close(response)
    end
  end

  defp collect_chunks(stream, response, loop_ctx) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        result =
          try do
            stream
            |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
              case loop_ctx.should_cancel?.() do
                {:cancel, reason} ->
                  cancel_stream_response(response)
                  {:halt, {:error, {:cancelled, reason}}}

                false ->
                  {:cont, {:ok, [chunk | acc]}}
              end
            end)
            |> case do
              {:ok, rev} -> {:ok, Enum.reverse(rev)}
              {:error, _} = error -> error
            end
          rescue
            error in [
              ReqLLM.Error.API.Stream,
              ReqLLM.Error.API.Request,
              ReqLLM.Error.API.Timeout
            ] ->
              {:error, error}
          end

        send(parent, {:stream_collected, self(), result})
      end)

    :ets.insert(loop_ctx.tracker, {{:active_task, :stream}, pid})
    loop_ctx.on_stream.({response, pid})

    try do
      receive do
        {:stream_collected, ^pid, result} ->
          Process.demonitor(ref, [:flush])
          result

        {:DOWN, ^ref, :process, ^pid, reason} ->
          cancel_stream_response(response)

          case loop_ctx.should_cancel?.() do
            {:cancel, cancel_reason} -> {:error, {:cancelled, cancel_reason}}
            false -> {:error, {:stream_crashed, reason}}
          end
      end
    after
      try do
        :ets.delete(loop_ctx.tracker, {:active_task, :stream})
      catch
        :error, :badarg -> :ok
      end
    end
  end

  defp cancel_stream_response(%StreamResponse{cancel: cancel} = response) do
    if is_function(cancel, 0), do: cancel.()
    if response.metadata_handle, do: StreamResponse.close(response)
    :ok
  catch
    _, _ -> :ok
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

  defp append_assistant(session, result, run_id) do
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
      |> maybe_put_run_id(run_id)

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

  defp execute_calls(_session, _tools, [], _loop_ctx), do: :ok

  defp execute_calls(session, tools, [call], loop_ctx) do
    case execute_one_call(tools, call, loop_ctx) do
      {:ok, result} ->
        append_tool_result(session, call, result, loop_ctx.run_id)
        :ok

      {:cancelled, reason} ->
        {:error, {:cancelled, reason}}
    end
  end

  defp execute_calls(session, tools, calls, loop_ctx) do
    outcomes =
      calls
      |> Task.async_stream(
        fn call -> {call, execute_one_call(tools, call, loop_ctx)} end,
        timeout: :infinity,
        ordered: true,
        max_concurrency: loop_ctx.tool_concurrency
      )
      |> Enum.map(fn
        {:ok, {call, outcome}} -> {call, outcome}
        {:exit, reason} -> {:exit, reason}
      end)

    cancelled =
      Enum.find_value(outcomes, fn
        {_call, {:cancelled, reason}} -> {:cancelled, reason}
        {:exit, :shutdown} -> loop_ctx.should_cancel?.() || {:cancelled, :shutdown}
        _ -> nil
      end)

    Enum.each(outcomes, fn
      {call, {:ok, result}} ->
        # Only persist completed tool results if the run has not been cancelled
        # mid-batch; otherwise let the after-block seal unsettled calls cleanly.
        if loop_ctx.should_cancel?.() == false do
          append_tool_result(session, call, result, loop_ctx.run_id)
        end

      _ ->
        :ok
    end)

    case cancelled || loop_ctx.should_cancel?.() do
      {:cancel, reason} -> {:error, {:cancelled, reason}}
      {:cancelled, reason} -> {:error, {:cancelled, reason}}
      false -> :ok
    end
  end

  defp execute_one_call(tools, call, loop_ctx) do
    case loop_ctx.should_cancel?.() do
      {:cancel, reason} ->
        {:cancelled, reason}

      false ->
        id_str = to_string(call.id)
        parent = self()
        :ets.insert(loop_ctx.tracker, {{:started, id_str}, true})

        {pid, ref} =
          spawn_monitor(fn ->
            res = Tools.execute(tools, call.name, call.arguments, %{tool_call_id: id_str})
            send(parent, {:tool_done, self(), res})
          end)

        :ets.insert(loop_ctx.tracker, {{:active_task, id_str}, pid})
        loop_ctx.on_tool_start.(id_str, pid)

        try do
          receive do
            {:tool_done, ^pid, result} ->
              Process.demonitor(ref, [:flush])
              {:ok, result}

            {:DOWN, ^ref, :process, ^pid, reason} ->
              case loop_ctx.should_cancel?.() do
                {:cancel, cancel_reason} ->
                  {:cancelled, cancel_reason}

                false ->
                  {:ok,
                   {:error, %{type: :crashed, message: "tool runner exited: #{inspect(reason)}"}}}
              end
          end
        after
          try do
            :ets.delete(loop_ctx.tracker, {:active_task, id_str})
          catch
            :error, :badarg -> :ok
          end
        end
    end
  end

  defp append_tool_result(session, call, result, run_id) do
    payload =
      %{"message" => ToolResult.from_result(call.id, call.name, result)}
      |> maybe_put_run_id(run_id)

    {:ok, _} = Session.append(session, :"tool/result", payload)
    :ok
  end

  # Our Tool schemas are already JSON Schema maps, which ReqLLM.tool/1
  # accepts directly as :parameter_schema. ReqLLM requires a :callback for
  # its own local-execution path; ours never runs (execution goes through
  # the Tools pipeline), so a placeholder satisfies the validation.
  # ReqLLM.tool/1 raises on an invalid schema — a programming error, which
  # the run's `after` still closes the turn around.
  defp tool_specs!(tools) do
    Enum.map(Tools.schemas(tools), fn schema ->
      ReqLLM.tool(
        name: schema.name,
        description: schema.description,
        parameter_schema: schema.parameters,
        callback: fn _args -> nil end
      )
    end)
  end
end
