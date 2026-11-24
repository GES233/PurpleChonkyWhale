defmodule PurpleChonkyWhale.AgentRun do
  @moduledoc """
  One supervised process per active execution within a `PurpleChonkyWhale.Session`.

  `AgentRun` owns transient execution state only — never a second conversation
  history. It binds `session_id` and `run_id` across LLM and tool events,
  persists `:"run/start"` before model work begins, and guarantees that every
  run settles **at most once** with a single terminal event
  (`:"run/completed"`, `:"run/failed"`, or `:"run/cancelled"`).

  ## Cancellation

  `cancel/2` performs cooperative, resource-aware cancellation:

    1. Sets the run's cancellation flag so the step loop halts at the next
       step, chunk, or tool boundary.
    2. Invokes the active `ReqLLM.StreamResponse`'s `cancel` function and
       terminates the stream consumer task if streaming is in flight.
    3. Sends `:shutdown` to any in-flight tool runner processes, triggering
       `PurpleChonkyWhale.Executor.Runner` to kill live OS process trees while
       leaving already-settled processes untouched.
    4. Seals unsettled tool calls in assistant call order: calls whose
       execution had started are recorded as `type: "outcome_unknown",
       state: "started"`, while calls that had not yet started are recorded as
       `type: "cancelled", state: "not_started"`.
  """

  use GenServer

  alias PurpleChonkyWhale.{AgentLoop, AgentRunSupervisor, Session}
  alias Dexterous.Context
  alias ReqLLM.StreamResponse

  @type status :: :running | :cancelling | :completed | :failed | :cancelled
  @type run_ref :: pid() | String.t()

  ## Public API

  @doc "Generate a fresh `run_id`."
  @spec generate_id() :: String.t()
  def generate_id do
    "run_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  @doc """
  Start a supervised `AgentRun`.

  Required options:

    * `:session` — session `pid()`
    * `:client` (or `:llm`) — `%PurpleChonkyWhale.LLM.Client{}`
    * `:tools` — `%PurpleChonkyWhale.Tools{}`

  Optional options:

    * `:run_id` — explicit run identifier (default `generate_id/0`)
    * `:session_id` — session identifier override (default `Session.id(session)`)
    * `:prompt` — user message string to append before `:"run/start"`
    * `:parts` — optional content parts (attachments) stored on the prompt's
      `:"user/message"` event, e.g. images built with
      `PurpleChonkyWhale.ToolResult.image_part/2`
    * `:max_steps` — step budget (default `100`)
    * `:tool_concurrency` — max concurrent tool calls per batch
    * `:supervisor` — `%AgentRunSupervisor{}` handle (defaults to the
      application-wide run supervisor)
  """
  @spec start(keyword()) :: {:ok, pid(), String.t()} | {:error, term()}
  def start(opts) when is_list(opts) do
    case Keyword.pop(opts, :supervisor) do
      {nil, opts} -> AgentRunSupervisor.start_run(opts)
      {sup, opts} -> AgentRunSupervisor.start_run(sup, opts)
    end
  end

  @doc false
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Return the `run_id` of `run`."
  @spec run_id(run_ref()) :: String.t()
  def run_id(run) do
    run |> resolve_pid!() |> GenServer.call(:run_id)
  end

  @doc "Query the current status and outcome of `run`."
  @spec status(run_ref()) :: %{
          run_id: String.t(),
          session_id: term(),
          status: status(),
          outcome: term()
        }
  def status(run) do
    run |> resolve_pid!() |> GenServer.call(:status)
  end

  @doc """
  Await the terminal outcome of `run`. Returns `{:ok, final_text}`,
  `{:error, {:cancelled, reason}}`, or `{:error, reason}`.
  """
  @spec await(run_ref(), timeout()) :: {:ok, String.t()} | {:error, term()}
  def await(run, timeout \\ :infinity) do
    run |> resolve_pid!() |> GenServer.call(:await, timeout)
  end

  @doc """
  Cooperatively cancel `run`. Idempotent: if the run has already settled,
  returns `{:ok, settled_status}` without writing a second terminal event.
  """
  @spec cancel(run_ref(), term()) :: {:ok, status()}
  def cancel(run, reason \\ "cancelled by caller") do
    run |> resolve_pid!() |> GenServer.call({:cancel, reason}, :infinity)
  end

  @doc """
  Append a steering user message to the run's session. If a tool batch is
  currently open, `Session.messages/1` holds the message until all tool
  results in the batch settle.
  """
  @spec steer(run_ref(), String.t()) :: {:ok, Session.event()} | {:error, term()}
  def steer(run, content) when is_binary(content) do
    run |> resolve_pid!() |> GenServer.call({:steer, content})
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    session = Keyword.fetch!(opts, :session)
    client = Keyword.get(opts, :client) || Keyword.fetch!(opts, :llm)
    tools = Keyword.fetch!(opts, :tools)
    registry = Keyword.get(opts, :registry, PurpleChonkyWhale.AgentRunRegistry)

    session_id = Keyword.get_lazy(opts, :session_id, fn -> Session.id(session) end)
    run_id = Keyword.get_lazy(opts, :run_id, &generate_id/0)

    with {:ok, _} <- Registry.register(registry, {:run, run_id}, session_id),
         {:ok, _} <- Registry.register(registry, {:session, session_id}, run_id) do
      session_ref = Process.monitor(session)
      cancel_table = :ets.new(:pcw_run_cancel, [:set, :public])

      {:ok, _} = Session.seal_unsettled(session, type: :outcome_unknown)

      if prompt = Keyword.get(opts, :prompt) do
        data =
          case Keyword.get(opts, :parts) do
            parts when is_list(parts) and parts != [] ->
              %{"content" => prompt, "runId" => run_id, "parts" => parts}

            _ ->
              %{"content" => prompt, "runId" => run_id}
          end

        {:ok, _} = Session.append(session, :"user/message", data)
      end

      {:ok, _} =
        Session.append(session, :"run/start", %{
          "runId" => run_id,
          "sessionId" => to_string(session_id)
        })

      emit_run_event(client.scope, :"run/start", %{
        run_id: run_id,
        session_id: session_id,
        status: :running
      })

      {worker_pid, worker_ref} =
        spawn_worker(self(), client, session, tools, session_id, run_id, cancel_table, opts)

      {:ok,
       %{
         run_id: run_id,
         session_id: session_id,
         session: session,
         session_ref: session_ref,
         scope: client.scope,
         registry: registry,
         cancel_table: cancel_table,
         worker_pid: worker_pid,
         worker_ref: worker_ref,
         active_stream: nil,
         status: :running,
         settled?: false,
         outcome: nil,
         await_waiters: [],
         cancel_waiters: []
       }}
    else
      {:error, {:already_registered, existing_pid}} ->
        {:stop, {:already_running, existing_pid}}
    end
  end

  @impl true
  def handle_call(:run_id, _from, state) do
    {:reply, state.run_id, state}
  end

  def handle_call(:status, _from, state) do
    reply = %{
      run_id: state.run_id,
      session_id: state.session_id,
      status: state.status,
      outcome: state.outcome
    }

    {:reply, reply, state}
  end

  def handle_call(:await, from, state) do
    if state.settled? do
      {:reply, state.outcome, state}
    else
      {:noreply, %{state | await_waiters: [from | state.await_waiters]}}
    end
  end

  def handle_call({:cancel, reason}, from, state) do
    cond do
      state.settled? ->
        {:reply, {:ok, state.status}, state}

      state.status == :cancelling ->
        {:noreply, %{state | cancel_waiters: [from | state.cancel_waiters]}}

      true ->
        :ets.insert(state.cancel_table, {:cancel, reason})
        cancel_active_resources(state)

        {:noreply,
         %{
           state
           | status: :cancelling,
             cancel_waiters: [from | state.cancel_waiters]
         }}
    end
  end

  def handle_call({:steer, content}, _from, state) do
    reply =
      Session.append(state.session, :"user/message", %{
        "content" => content,
        "runId" => state.run_id
      })

    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:active_stream, stream_info}, state) do
    # If cancellation was requested just before the stream registered,
    # cancel it immediately.
    if state.status == :cancelling and stream_info != nil do
      cancel_stream_info(stream_info)
    end

    {:noreply, %{state | active_stream: stream_info}}
  end

  def handle_cast({:tool_started, call_id, pid}, state) do
    :ets.insert(state.cancel_table, {{:started_call, call_id}, true})
    :ets.insert(state.cancel_table, {{:active_tool, call_id}, pid})

    if state.status == :cancelling and is_pid(pid) and Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:worker_done, pid, result}, %{worker_pid: pid} = state) do
    if is_reference(state.worker_ref), do: Process.demonitor(state.worker_ref, [:flush])
    state = settle_from_worker_result(state, result)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{worker_ref: ref} = state) do
    state =
      case cancel_reason(state.cancel_table) do
        {:cancel, cancel_reason} ->
          settle_once(state, :cancelled, {:error, {:cancelled, cancel_reason}}, cancel_reason)

        false ->
          settle_once(state, :failed, {:error, {:worker_crashed, reason}}, reason)
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{session_ref: ref} = state) do
    if not state.settled? do
      :ets.insert(state.cancel_table, {:cancel, :session_closed})
      cancel_active_resources(state)
      if is_pid(state.worker_pid), do: Process.exit(state.worker_pid, :shutdown)
    end

    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    try do
      :ets.delete(state.cancel_table)
    catch
      :error, :badarg -> :ok
    end

    :ok
  end

  ## Internal

  defp spawn_worker(run_pid, client, session, tools, session_id, run_id, cancel_table, opts) do
    max_steps = Keyword.get(opts, :max_steps, 100)
    tool_concurrency = Keyword.get(opts, :tool_concurrency, System.schedulers_online())

    spawn_monitor(fn ->
      loop_opts = [
        run_id: run_id,
        session_id: session_id,
        max_steps: max_steps,
        tool_concurrency: tool_concurrency,
        on_stream: fn stream_info ->
          GenServer.cast(run_pid, {:active_stream, stream_info})
        end,
        on_tool_start: fn call_id, task_pid ->
          :ets.insert(cancel_table, {{:started_call, call_id}, true})
          :ets.insert(cancel_table, {{:active_tool, call_id}, task_pid})
          GenServer.cast(run_pid, {:tool_started, call_id, task_pid})
        end,
        should_cancel?: fn ->
          cancel_reason(cancel_table)
        end
      ]

      result = AgentLoop.run(client, session, tools, loop_opts)
      send(run_pid, {:worker_done, self(), result})
    end)
  end

  defp cancel_reason(cancel_table) do
    case :ets.lookup(cancel_table, :cancel) do
      [{:cancel, reason}] -> {:cancel, reason}
      [] -> false
    end
  catch
    :error, :badarg -> false
  end

  defp cancel_active_resources(state) do
    if state.active_stream do
      cancel_stream_info(state.active_stream)
    end

    active_tools =
      state.cancel_table
      |> :ets.match({{:active_tool, :_}, :"$1"})
      |> List.flatten()

    Enum.each(active_tools, fn pid ->
      if is_pid(pid) and Process.alive?(pid) do
        Process.exit(pid, :shutdown)
      end
    end)
  end

  defp cancel_stream_info({%StreamResponse{} = response, pid}) do
    cancel_stream_info(response)

    if is_pid(pid) and Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end
  end

  defp cancel_stream_info(%StreamResponse{cancel: cancel} = response) do
    try do
      if is_function(cancel, 0), do: cancel.()
      if response.metadata_handle, do: StreamResponse.close(response)
    catch
      _, _ -> :ok
    end
  end

  defp cancel_stream_info(_other), do: :ok

  defp settle_from_worker_result(state, {:ok, text}) do
    case cancel_reason(state.cancel_table) do
      {:cancel, reason} ->
        settle_once(state, :cancelled, {:error, {:cancelled, reason}}, reason)

      false ->
        settle_once(state, :completed, {:ok, text}, text)
    end
  end

  defp settle_from_worker_result(state, {:error, {:cancelled, reason}}) do
    settle_once(state, :cancelled, {:error, {:cancelled, reason}}, reason)
  end

  defp settle_from_worker_result(state, {:error, reason} = error) do
    case cancel_reason(state.cancel_table) do
      {:cancel, cancel_reason} ->
        settle_once(state, :cancelled, {:error, {:cancelled, cancel_reason}}, cancel_reason)

      false ->
        settle_once(state, :failed, error, reason)
    end
  end

  defp settle_once(%{settled?: true} = state, _status, _outcome, _detail), do: state

  defp settle_once(state, status, outcome, detail) do
    started_ids =
      state.cancel_table
      |> :ets.match({{:started_call, :"$1"}, :_})
      |> List.flatten()
      |> MapSet.new(&to_string/1)

    seal_reason =
      case status do
        :cancelled -> format_detail(detail)
        _ -> "tool call interrupted before completion"
      end

    try do
      Session.seal_unsettled(state.session,
        run_id: state.run_id,
        started_call_ids: started_ids,
        reason: seal_reason
      )

      {event_type, event_data} = terminal_event(state.run_id, state.session_id, status, detail)
      Session.append(state.session, event_type, event_data)

      emit_run_event(state.scope, event_type, %{
        run_id: state.run_id,
        session_id: state.session_id,
        status: status,
        outcome: outcome
      })
    catch
      :exit, _ -> :ok
    end

    Registry.unregister(state.registry, {:session, state.session_id})

    Enum.each(state.await_waiters, &GenServer.reply(&1, outcome))
    Enum.each(state.cancel_waiters, &GenServer.reply(&1, {:ok, status}))

    %{
      state
      | status: status,
        settled?: true,
        outcome: outcome,
        active_stream: nil,
        worker_pid: nil,
        await_waiters: [],
        cancel_waiters: []
    }
  end

  defp terminal_event(run_id, session_id, :completed, text) do
    {:"run/completed",
     %{
       "runId" => run_id,
       "sessionId" => to_string(session_id),
       "status" => "completed",
       "text" => to_string(text)
     }}
  end

  defp terminal_event(run_id, session_id, :cancelled, reason) do
    {:"run/cancelled",
     %{
       "runId" => run_id,
       "sessionId" => to_string(session_id),
       "status" => "cancelled",
       "reason" => format_detail(reason)
     }}
  end

  defp terminal_event(run_id, session_id, :failed, reason) do
    {:"run/failed",
     %{
       "runId" => run_id,
       "sessionId" => to_string(session_id),
       "status" => "failed",
       "error" => format_detail(reason)
     }}
  end

  defp format_detail(detail) when is_binary(detail), do: detail
  defp format_detail(detail), do: inspect(detail)

  defp emit_run_event(nil, _event, _payload), do: :ok

  defp emit_run_event(scope, event, payload) do
    ctx = Context.new(scope)
    Context.emit(ctx, event, payload)
  end

  defp resolve_pid!(pid) when is_pid(pid), do: pid

  defp resolve_pid!(run_id) when is_binary(run_id) do
    case AgentRunSupervisor.lookup(run_id) do
      {:ok, pid} -> pid
      :error -> raise ArgumentError, "unknown or terminated run_id: #{run_id}"
    end
  end
end
