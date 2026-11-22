defmodule DarkChonkyWhale.Session do
  @moduledoc """
  One session log: an append-only sequence of durable events — the source of
  the context the model sees.

  Current files start with a physical header (`type: "session", version: 1`),
  followed by events. The header has no sequence number. An event is
  `%{seq, id, parent_id, type, at, data}`; the log assigns all envelope fields,
  persists them before advancing memory, and replays them on open. Headerless
  files from the original format are legacy v0: they keep their legacy disk
  shape, including on later appends, and receive the current envelope in memory.

  The event vocabulary follows DSH's turn flow. Model-visible types, the ones
  the `messages/1` projection folds into `ReqLLM.Message`s:

    * `:"system/message"` — `%{content}`
    * `:"user/message"` — `%{content}`
    * `:"assistant/message"` — `%{content, thinking, reasoning_details, tool_calls: [%{id, name, input, metadata}]}`
      (`thinking`, `reasoning_details`, and `tool_calls` optional)
    * `:"tool/result"` — canonical `%{"message" => toolResult}` or the legacy
      flat `%{tool_call_id, name, output}` payload

  An assistant tool-call batch is indivisible in the provider projection:
  results are emitted in assistant call order, and messages that arrived while
  the batch was open are emitted after its results. Projecting an unsettled
  batch raises rather than sending an invalid conversation to a provider;
  `seal_unsettled/2` closes an interrupted batch by appending synthetic error
  `:"tool/result"` events for any dangling calls.

  Turn/step markers (`:"turn/start"`, `:"step/start"`, …), run lifecycle events
  (`:"run/start"`, `:"run/completed"`, `:"run/failed"`, `:"run/cancelled"`),
  and any other type are durable facts but not model-visible. Every append is
  broadcast on the scope's event bus as `:"session/event"` with
  `%{session: id, event: event}`.

  Known gaps versus DSH's session log: no generation chain.
  """

  use GenServer

  alias DarkChonkyWhale.ToolResult
  alias Dexterous.Context

  @format_version 1

  @type id :: term()
  @type event :: %{
          seq: non_neg_integer(),
          id: String.t(),
          parent_id: String.t() | nil,
          type: atom() | String.t(),
          at: integer(),
          data: map()
        }

  ## API

  def start_link(opts) do
    case Keyword.pop(opts, :name) do
      {nil, opts} -> GenServer.start_link(__MODULE__, opts)
      {name, opts} -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Return the session's identifier."
  @spec id(pid()) :: id()
  def id(pid), do: GenServer.call(pid, :id)

  @doc "Append an event of `type` with `data`. Returns `{:ok, event}` or `{:error, reason}`."
  @spec append(pid(), atom(), map()) :: {:ok, event()} | {:error, map()}
  def append(pid, type, data) when is_atom(type) and is_map(data) do
    GenServer.call(pid, {:append, type, data})
  end

  @doc "All events, in order."
  @spec events(pid()) :: [event()]
  def events(pid), do: GenServer.call(pid, :events)

  @doc "The model-visible projection: events folded into `ReqLLM.Message`s."
  @spec messages(pid()) :: [ReqLLM.Message.t()]
  def messages(pid) do
    pid |> events() |> project_events()
  end

  @doc """
  Seal any unsettled tool calls in the current open batch by appending synthetic
  error `:"tool/result"` events in assistant call order. Returns `{:ok, sealed_events}`.

  Accepts either a binary reason or keyword/map options:

    * `:reason` — human-readable interruption/cancellation reason
    * `:type` — `:outcome_unknown` (default when `:started_call_ids` is omitted)
      or `:cancelled`
    * `:started_call_ids` — collection of call IDs whose execution started;
      those calls are sealed with `type: "outcome_unknown", state: "started"`,
      while unstarted calls in the batch are sealed with
      `type: "cancelled", state: "not_started"`
    * `:run_id` — optional run identifier bound to the sealed results
  """
  @spec seal_unsettled(pid(), String.t() | keyword() | map()) :: {:ok, [event()]}
  def seal_unsettled(pid, opts \\ [])

  def seal_unsettled(pid, reason) when is_binary(reason) do
    GenServer.call(pid, {:seal_unsettled, %{reason: reason}})
  end

  def seal_unsettled(pid, opts) when is_list(opts) do
    GenServer.call(pid, {:seal_unsettled, Map.new(opts)})
  end

  def seal_unsettled(pid, opts) when is_map(opts) do
    GenServer.call(pid, {:seal_unsettled, opts})
  end

  ## Server

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    dir = Keyword.fetch!(opts, :dir)
    scope = Keyword.fetch!(opts, :scope)
    File.mkdir_p!(dir)
    path = Path.join(dir, "session-#{id}.jsonl")

    {header, events, format, persisted?} = read_back(path, id, opts)
    {calls, settled, open_batch} = index_tool_calls(events)

    {:ok,
     %{
       id: id,
       path: path,
       scope: scope,
       header: header,
       events_rev: Enum.reverse(events),
       next_seq: length(events),
       last_event_id: events |> List.last() |> then(&(&1 && &1.id)),
       calls: calls,
       settled: settled,
       open_batch: open_batch,
       format: format,
       persisted?: persisted?
     }}
  end

  @impl true
  def handle_call(:id, _from, state) do
    {:reply, state.id, state}
  end

  def handle_call({:append, type, data}, _from, state) do
    case validate_tool_result(type, data, state) do
      :ok ->
        {event, state} = do_append_event(type, data, state)
        {:reply, {:ok, event}, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:seal_unsettled, opts}, _from, state) do
    reason =
      Map.get(opts, :reason) || Map.get(opts, "reason") ||
        "tool call interrupted before completion"

    default_type = Map.get(opts, :type) || Map.get(opts, "type")

    started_ids =
      normalize_id_set(Map.get(opts, :started_call_ids) || Map.get(opts, "started_call_ids"))

    explicit_run_id = Map.get(opts, :run_id) || Map.get(opts, "run_id")

    {sealed_rev, state} =
      Enum.reduce(state.open_batch, {[], state}, fn {id, name, call_run_id}, {acc, st} ->
        result = build_sealed_result(id, name, reason, default_type, started_ids)
        run_id = explicit_run_id || call_run_id

        payload =
          if run_id != nil do
            %{"runId" => to_string(run_id), "message" => result}
          else
            %{"message" => result}
          end

        {event, st} = do_append_event(:"tool/result", payload, st)
        {[event | acc], st}
      end)

    {:reply, {:ok, Enum.reverse(sealed_rev)}, state}
  end

  def handle_call(:events, _from, state) do
    {:reply, Enum.reverse(state.events_rev), state}
  end

  defp normalize_id_set(nil), do: nil
  defp normalize_id_set(%MapSet{} = set), do: set
  defp normalize_id_set(list) when is_list(list), do: MapSet.new(list, &to_string/1)

  defp build_sealed_result(id, name, reason, default_type, started_ids) do
    resolved_type =
      cond do
        default_type in [:cancelled, "cancelled"] ->
          :cancelled

        default_type in [:outcome_unknown, "outcome_unknown"] ->
          :outcome_unknown

        is_struct(started_ids, MapSet) ->
          if MapSet.member?(started_ids, to_string(id)), do: :outcome_unknown, else: :cancelled

        true ->
          :outcome_unknown
      end

    case resolved_type do
      :cancelled -> ToolResult.cancelled(id, name, reason)
      :outcome_unknown -> ToolResult.outcome_unknown(id, name, reason)
    end
  end

  ## Append

  defp do_append_event(type, data, state) do
    event = %{
      seq: state.next_seq,
      id: event_id(state.format, state.next_seq),
      parent_id: state.last_event_id,
      type: type,
      at: System.system_time(:millisecond),
      data: sanitize(data)
    }

    persist!(state, event)
    broadcast(state.scope, state.id, event)

    {calls, settled, open_batch} =
      index_tool_call(type, event.data, state.calls, state.settled, state.open_batch)

    state = %{
      state
      | events_rev: [event | state.events_rev],
        next_seq: state.next_seq + 1,
        last_event_id: event.id,
        calls: calls,
        settled: settled,
        open_batch: open_batch,
        persisted?: true
    }

    {event, state}
  end

  defp validate_tool_result(:"tool/result", data, state) do
    case ToolResult.call_id(data) do
      nil ->
        {:error, %{type: :unknown_tool_call, message: "tool result has no tool call id"}}

      id ->
        result_run_id = data["runId"] || data["run_id"]

        cond do
          MapSet.member?(state.settled, id) ->
            {:error, %{type: :duplicate_tool_result, message: "tool call already settled: #{id}"}}

          not Map.has_key?(state.calls, id) ->
            {:error, %{type: :unknown_tool_call, message: "unknown tool call: #{id}"}}

          stale_run_id?(state.calls[id], result_run_id) ->
            expected = state.calls[id].run_id

            {:error,
             %{
               type: :stale_run_result,
               message: "tool result runId #{result_run_id} does not match call runId #{expected}"
             }}

          true ->
            :ok
        end
    end
  end

  defp validate_tool_result(_type, _data, _state), do: :ok

  defp stale_run_id?(%{run_id: expected}, actual)
       when is_binary(expected) and is_binary(actual) and expected != actual,
       do: true

  defp stale_run_id?(_call_info, _actual), do: false

  ## Projection

  defp project_events(events) do
    {messages_rev, batch} = Enum.reduce(events, {[], nil}, &project_event/2)

    if batch do
      unsettled = Enum.reject(batch.ids, &Map.has_key?(batch.results, &1))
      raise ArgumentError, "cannot project unsettled tool calls: #{Enum.join(unsettled, ", ")}"
    end

    Enum.reverse(messages_rev)
  end

  defp project_event(%{type: :"tool/result", data: data} = event, {_out, nil}) do
    message = canonical_result(data, event.at)
    raise ArgumentError, "tool result has no open tool-call batch: #{message["toolCallId"]}"
  end

  defp project_event(%{type: :"tool/result", data: data} = event, {out, batch}) do
    message = canonical_result(data, event.at)
    id = message["toolCallId"]

    if id in batch.ids and not Map.has_key?(batch.results, id) do
      results = Map.put(batch.results, id, message)
      batch = %{batch | results: results}

      if Enum.all?(batch.ids, &Map.has_key?(results, &1)) do
        out = emit(out, Enum.map(batch.ids, &ToolResult.to_reqllm(results[&1])))

        batch.deferred
        |> Enum.reverse()
        |> Enum.reduce({out, nil}, &project_event/2)
      else
        {out, batch}
      end
    else
      raise ArgumentError, "unknown or duplicate tool result: #{id}"
    end
  end

  defp project_event(%{type: type} = event, {out, batch})
       when type in [:"system/message", :"user/message", :"assistant/message"] do
    if batch do
      {out, %{batch | deferred: [event | batch.deferred]}}
    else
      case project_message(event) do
        {message, []} -> {[message | out], nil}
        {message, ids} -> {[message | out], %{ids: ids, results: %{}, deferred: []}}
      end
    end
  end

  defp project_event(_event, state), do: state

  defp project_message(%{type: :"system/message", data: data}) do
    {ReqLLM.Context.system(data["content"]), []}
  end

  defp project_message(%{type: :"user/message", data: data}) do
    {ReqLLM.Context.user(data["content"]), []}
  end

  defp project_message(%{type: :"assistant/message", data: data}) do
    tool_calls =
      for call <- data["tool_calls"] || [] do
        project_tool_call(call)
      end

    message =
      (data["content"] || "")
      |> ReqLLM.Context.assistant(tool_calls: tool_calls)
      |> maybe_project_thinking(data["thinking"])
      |> maybe_project_reasoning_details(data["reasoning_details"])

    ids = Enum.map(data["tool_calls"] || [], & &1["id"])
    {message, ids}
  end

  defp project_tool_call(call) do
    input = call["input"] || %{}
    args_json = if is_binary(input), do: input, else: Jason.encode!(input)
    tc = ReqLLM.ToolCall.new(call["id"], call["name"], args_json)

    case call["metadata"] do
      meta when is_map(meta) and map_size(meta) > 0 ->
        ReqLLM.ToolCall.put_metadata(tc, atomize_known_metadata_keys(meta))

      _ ->
        tc
    end
  end

  defp atomize_known_metadata_keys(meta) do
    Map.new(meta, fn
      {"thought_signature", v} -> {:thought_signature, v}
      {"signature", v} -> {:signature, v}
      {k, v} -> {k, v}
    end)
  end

  defp maybe_project_thinking(message, thinking) when is_binary(thinking) and thinking != "" do
    %{message | content: message.content ++ [ReqLLM.Message.ContentPart.thinking(thinking)]}
  end

  defp maybe_project_thinking(message, _thinking), do: message

  defp maybe_project_reasoning_details(message, details)
       when is_list(details) and details != [] do
    decoded =
      details
      |> Enum.with_index()
      |> Enum.map(fn {item, idx} -> decode_reasoning_detail(item, idx) end)

    %{message | reasoning_details: decoded}
  end

  defp maybe_project_reasoning_details(message, _details), do: message

  defp decode_reasoning_detail(%ReqLLM.Message.ReasoningDetails{} = detail, _idx), do: detail

  defp decode_reasoning_detail(item, fallback_idx) when is_map(item) do
    %ReqLLM.Message.ReasoningDetails{
      text: item["text"] || item[:text],
      signature: item["signature"] || item[:signature],
      encrypted?: (item["encrypted"] || item[:encrypted?] || item["signature_encrypted"]) == true,
      provider: decode_provider_atom(item["provider"] || item[:provider]),
      format: item["format"] || item[:format],
      index: item["index"] || item[:index] || fallback_idx,
      provider_data: item["provider_data"] || item[:provider_data] || %{}
    }
  end

  defp decode_provider_atom(nil), do: nil
  defp decode_provider_atom(provider) when is_atom(provider), do: provider

  defp decode_provider_atom(provider) when is_binary(provider) do
    String.to_existing_atom(provider)
  rescue
    ArgumentError -> nil
  end

  defp canonical_result(%{"message" => %{"role" => "toolResult"}} = data, _at),
    do: data["message"]

  defp canonical_result(data, at), do: ToolResult.from_legacy(data, at)

  defp emit(out, messages), do: Enum.reverse(messages, out)

  ## Tool-call index

  defp index_tool_calls(events) do
    Enum.reduce(events, {%{}, MapSet.new(), []}, fn event, {calls, settled, open_batch} ->
      index_tool_call(event.type, event.data, calls, settled, open_batch)
    end)
  end

  defp index_tool_call(:"assistant/message", data, calls, settled, open_batch) do
    run_id = data["runId"] || data["run_id"]

    Enum.reduce(data["tool_calls"] || [], {calls, settled, open_batch}, fn call,
                                                                           {calls, settled,
                                                                            open_batch} ->
      id = call["id"]
      name = call["name"]
      call_run_id = call["runId"] || call["run_id"] || run_id

      open_batch =
        Enum.reject(open_batch, fn {open_id, _, _} -> open_id == id end) ++
          [{id, name, call_run_id}]

      {Map.put(calls, id, %{name: name, run_id: call_run_id}), MapSet.delete(settled, id),
       open_batch}
    end)
  end

  defp index_tool_call(:"tool/result", data, calls, settled, open_batch) do
    case ToolResult.call_id(data) do
      nil ->
        {calls, settled, open_batch}

      id ->
        open_batch = Enum.reject(open_batch, fn {open_id, _, _} -> open_id == id end)
        {calls, MapSet.put(settled, id), open_batch}
    end
  end

  defp index_tool_call(_type, _data, calls, settled, open_batch),
    do: {calls, settled, open_batch}

  ## Persistence

  defp read_back(path, id, opts) do
    lines = if File.exists?(path), do: path |> File.stream!() |> Enum.to_list(), else: []

    case lines do
      [] ->
        {new_header(id, opts), [], :v1, false}

      [first | rest] ->
        case Jason.decode!(first) do
          %{"type" => "session", "version" => @format_version} = header ->
            {header, Enum.map(rest, &decode_current/1), :v1, true}

          %{"type" => "session", "version" => version} ->
            raise ArgumentError, "unsupported session format version: #{inspect(version)}"

          _legacy ->
            {header, events} = decode_legacy([first | rest], id)
            {header, events, :v0, true}
        end
    end
  end

  defp new_header(id, opts) do
    %{
      "type" => "session",
      "version" => @format_version,
      "id" => to_string(id),
      "created_at" => System.system_time(:millisecond),
      "cwd" => Keyword.get(opts, :cwd, File.cwd!())
    }
  end

  defp decode_legacy(lines, id) do
    events = Enum.map(lines, &decode_legacy_event/1)

    header = %{
      "type" => "session",
      "version" => 0,
      "id" => to_string(id),
      "created_at" => (List.first(events) || %{at: System.system_time(:millisecond)}).at,
      "cwd" => File.cwd!()
    }

    {header, events}
  end

  defp decode_current(line) do
    decoded = Jason.decode!(line)

    %{
      seq: decoded["seq"],
      id: decoded["id"],
      parent_id: decoded["parent_id"],
      type: decode_type(decoded["type"]),
      at: decoded["at"],
      data: decoded["data"] || %{}
    }
  end

  defp decode_legacy_event(line) do
    decoded = Jason.decode!(line)
    seq = decoded["seq"]

    %{
      seq: seq,
      id: legacy_event_id(seq),
      parent_id: if(seq > 0, do: legacy_event_id(seq - 1), else: nil),
      type: decode_type(decoded["type"]),
      at: decode_legacy_time(decoded["at"]),
      data: decoded["data"] || %{}
    }
  end

  defp decode_legacy_time(at) when is_integer(at), do: at

  defp decode_legacy_time(at) when is_binary(at) do
    at |> DateTime.from_iso8601() |> elem(1) |> DateTime.to_unix(:millisecond)
  end

  defp persist!(state, event) do
    event_line = encode_event(state.format, event)

    contents =
      case {state.format, state.persisted?} do
        {:v1, false} -> Jason.encode!(state.header) <> "\n" <> event_line
        _ -> event_line
      end

    File.write!(state.path, contents, [:append])
  end

  defp encode_event(:v1, event) do
    Jason.encode!(%{
      "seq" => event.seq,
      "id" => event.id,
      "parent_id" => event.parent_id,
      "type" => Atom.to_string(event.type),
      "at" => event.at,
      "data" => event.data
    }) <> "\n"
  end

  defp encode_event(:v0, event) do
    Jason.encode!(%{
      "seq" => event.seq,
      "type" => Atom.to_string(event.type),
      "at" => event.at |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601(),
      "data" => event.data
    }) <> "\n"
  end

  defp event_id(:v0, seq), do: legacy_event_id(seq)

  defp event_id(:v1, _seq),
    do: "evt_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp legacy_event_id(seq), do: "evt_legacy_#{seq}"

  defp decode_type(type) when is_binary(type) do
    String.to_existing_atom(type)
  rescue
    ArgumentError -> type
  end

  # JSON is UTF-8, but payloads can carry raw bytes (e.g. GBK console output
  # captured by a tool). Scrub invalid UTF-8 to the replacement char rather
  # than let Jason raise and take the whole session process down.
  defp sanitize(term) when is_binary(term), do: String.replace_invalid(term)

  defp sanitize(term) when is_map(term),
    do: Map.new(term, fn {key, value} -> {sanitize(key), sanitize(value)} end)

  defp sanitize(term) when is_list(term), do: Enum.map(term, &sanitize/1)
  defp sanitize(term), do: term

  defp broadcast(scope, id, event) do
    ctx = Context.new(scope)
    Context.emit(ctx, :"session/event", %{session: id, event: event})
  end
end
