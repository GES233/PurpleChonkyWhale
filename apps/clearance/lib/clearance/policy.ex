defmodule Clearance.Policy do
  # Declared before the moduledoc, which interpolates them.
  @default_auto_allow [:fs_read, :ui, :memory]
  @default_lease_ttl_ms 15 * 60_000
  @default_approval_caps [:unknown, :mcp]

  @moduledoc """
  One authorization process: owns the active leases, serializes approval
  prompts, and answers `Clearance.check/3`.

  State is deliberately small — the leases (newest first), the single
  in-flight approval, and a FIFO of callers waiting for it. A caller whose
  call needs approval while another prompt is open is queued, not refused;
  when the prompt resolves, queued calls are re-evaluated first, so a lease
  granted by the earlier prompt is reused instead of asking again.

  ## Options

    * `:asker` — `(request -> choice)`; `nil` means non-interactive, so
      anything that needs approval is denied. See `Clearance.Asker`.
    * `:auto_allow` — capabilities allowed without approval (default
      `#{inspect(@default_auto_allow)}`)
    * `:lease_ttl_ms` — default TTL for a lease the asker grants (default
      `#{@default_lease_ttl_ms}`)
    * `:initial_leases` — a capability atom, a `{capabilities, ttl_ms}` tuple,
      or a `%PurpleChonkyWhale.Security.Grant{}`
    * `:lint` — `(args, opts -> %{verdict: :ok | :ask | :deny, reasons: [...]})`,
      applied to the tools named in `:lint_tools`
    * `:lint_tools` — tool names the lint applies to (default `[]`)
    * `:force_ask?` — `(name, args, caps -> boolean)` that forces approval
    * `:approval_caps` — capabilities that always require approval (default
      `#{inspect(@default_approval_caps)}`); their calls can never hold a
      standing lease
    * `:protected_dirs` — passed to the lint as `:protected_dirs`
  """

  use GenServer

  alias Clearance.{Evaluate, Request}
  alias PurpleChonkyWhale.Security.Grant

  ## API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    case Keyword.pop(opts, :name) do
      {nil, opts} -> GenServer.start_link(__MODULE__, opts)
      {name, opts} -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Authorize one tool call. Fails closed if this server is gone."
  @spec check(pid(), map(), timeout()) :: {:allow, Grant.t()} | {:deny, String.t()}
  def check(policy, call, timeout \\ :infinity) when is_pid(policy) and is_map(call) do
    GenServer.call(policy, {:check, call}, timeout)
  catch
    :exit, _reason -> {:deny, "policy server unavailable"}
  end

  @spec leases(pid()) :: [Grant.t()]
  def leases(policy) when is_pid(policy), do: GenServer.call(policy, :leases)

  @spec grant_lease(pid(), [atom()], keyword()) :: {:ok, Grant.t()}
  def grant_lease(policy, capabilities, opts \\ [])
      when is_pid(policy) and is_list(capabilities) do
    GenServer.call(policy, {:grant_lease, capabilities, opts})
  end

  @spec revoke_all(pid()) :: :ok
  def revoke_all(policy) when is_pid(policy), do: GenServer.call(policy, :revoke_all)

  @spec set_asker(pid(), Clearance.Asker.asker() | nil) :: :ok
  def set_asker(policy, asker) when is_pid(policy) do
    GenServer.call(policy, {:set_asker, asker})
  end

  ## Server

  @impl true
  def init(opts) do
    now_ms = System.monotonic_time(:millisecond)
    lease_ttl_ms = Keyword.get(opts, :lease_ttl_ms, @default_lease_ttl_ms)

    initial_leases =
      opts
      |> Keyword.get(:initial_leases, [])
      |> Enum.map(&normalize_initial_lease(&1, lease_ttl_ms, now_ms))
      |> Enum.reject(&Grant.expired?(&1, now_ms))

    state = %{
      auto_allow: opts |> Keyword.get(:auto_allow, @default_auto_allow) |> MapSet.new(),
      asker: normalize_asker(Keyword.get(opts, :asker)),
      lease_ttl_ms: lease_ttl_ms,
      leases: initial_leases,
      lint: Keyword.get(opts, :lint),
      lint_tools: Keyword.get(opts, :lint_tools, []),
      force_ask?: Keyword.get(opts, :force_ask?, fn _, _, _ -> false end),
      approval_caps: Keyword.get(opts, :approval_caps, @default_approval_caps),
      protected_dirs: Keyword.get(opts, :protected_dirs, []),
      active: nil,
      queue: :queue.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:check, call}, from, state) do
    now_ms = System.monotonic_time(:millisecond)
    state = prune_leases(state, now_ms)

    if state.active == nil do
      case Evaluate.run(call, snapshot(state), now_ms) do
        {:allow, grant} ->
          {:reply, {:allow, grant}, state}

        {:deny, reason} ->
          {:reply, {:deny, reason}, state}

        {:needs_ask, request_ctx} ->
          {:noreply, start_ask(state, from, call, request_ctx)}
      end
    else
      {caller_pid, _tag} = from
      caller_ref = Process.monitor(caller_pid)
      item = %{from: from, caller_ref: caller_ref, call: call}
      {:noreply, %{state | queue: :queue.in(item, state.queue)}}
    end
  end

  def handle_call(:leases, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    state = prune_leases(state, now_ms)
    {:reply, state.leases, state}
  end

  def handle_call({:grant_lease, capabilities, opts}, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    ttl_ms = Keyword.get(opts, :ttl_ms, state.lease_ttl_ms)
    tools = Keyword.get(opts, :tools, :any)
    reason = Keyword.get(opts, :reason, "granted lease (#{div(ttl_ms, 1000)}s)")

    lease =
      Grant.new(
        [
          capabilities: capabilities,
          tools: tools,
          ttl_ms: ttl_ms,
          source: :lease,
          reason: reason
        ],
        now_ms
      )

    state =
      state
      |> prune_leases(now_ms)
      |> Map.update!(:leases, &[lease | &1])

    {:reply, {:ok, lease}, state}
  end

  def handle_call(:revoke_all, _from, state) do
    {:reply, :ok, %{state | leases: []}}
  end

  def handle_call({:set_asker, asker}, _from, state) do
    {:reply, :ok, %{state | asker: normalize_asker(asker)}}
  end

  @impl true
  def handle_info(
        {:clearance_ask_result, ask_ref, choice},
        %{active: %{ask_ref: ask_ref}} = state
      ) do
    active = state.active
    Process.demonitor(active.ask_mon, [:flush])
    Process.demonitor(active.caller_ref, [:flush])

    now_ms = System.monotonic_time(:millisecond)
    {decision, lease} = Evaluate.resolve(choice, active, now_ms)

    state = if lease, do: %{state | leases: [lease | state.leases]}, else: state

    GenServer.reply(active.from, decision)
    {:noreply, dispatch_next(%{state | active: nil})}
  end

  def handle_info(
        {:DOWN, ask_mon, :process, _pid, _reason},
        %{active: %{ask_mon: ask_mon}} = state
      ) do
    Process.demonitor(state.active.caller_ref, [:flush])
    GenServer.reply(state.active.from, {:deny, "approval prompt aborted"})
    {:noreply, dispatch_next(%{state | active: nil})}
  end

  def handle_info(
        {:DOWN, caller_ref, :process, _pid, _reason},
        %{active: %{caller_ref: caller_ref}} = state
      ) do
    Process.demonitor(state.active.ask_mon, [:flush])
    Process.exit(state.active.ask_pid, :kill)
    {:noreply, dispatch_next(%{state | active: nil})}
  end

  def handle_info({:DOWN, caller_ref, :process, _pid, _reason}, state) do
    filtered =
      state.queue
      |> :queue.to_list()
      |> Enum.reject(&(&1.caller_ref == caller_ref))
      |> :queue.from_list()

    {:noreply, %{state | queue: filtered}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Internals

  defp snapshot(state) do
    Map.take(state, [
      :leases,
      :auto_allow,
      :asker,
      :lint,
      :lint_tools,
      :force_ask?,
      :approval_caps,
      :protected_dirs
    ])
  end

  defp start_ask(state, from, call, request_ctx) do
    {caller_pid, _tag} = from
    caller_ref = Process.monitor(caller_pid)
    ask_ref = make_ref()
    server = self()
    asker = state.asker
    request = Request.build(call, request_ctx, state)

    {ask_pid, ask_mon} =
      spawn_monitor(fn ->
        choice =
          try do
            asker.(request)
          rescue
            _ -> :deny
          catch
            _, _ -> :deny
          end

        send(server, {:clearance_ask_result, ask_ref, choice})
      end)

    %{
      state
      | active: %{
          from: from,
          caller_ref: caller_ref,
          ask_pid: ask_pid,
          ask_mon: ask_mon,
          ask_ref: ask_ref,
          call: call,
          name: request_ctx.name,
          caps: request_ctx.caps,
          high_risk?: request_ctx.high_risk?,
          network_requested?: request.network_requested?,
          leaseable: request.leaseable_capabilities
        }
    }
  end

  defp dispatch_next(state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, item}, rest} ->
        state = %{state | queue: rest}
        now_ms = System.monotonic_time(:millisecond)
        state = prune_leases(state, now_ms)

        case Evaluate.run(item.call, snapshot(state), now_ms) do
          {:allow, grant} ->
            Process.demonitor(item.caller_ref, [:flush])
            GenServer.reply(item.from, {:allow, grant})
            dispatch_next(state)

          {:deny, reason} ->
            Process.demonitor(item.caller_ref, [:flush])
            GenServer.reply(item.from, {:deny, reason})
            dispatch_next(state)

          {:needs_ask, request_ctx} ->
            Process.demonitor(item.caller_ref, [:flush])
            start_ask(state, item.from, item.call, request_ctx)
        end
    end
  end

  defp prune_leases(state, now_ms) do
    %{state | leases: Enum.reject(state.leases, &Grant.expired?(&1, now_ms))}
  end

  defp normalize_asker(fun) when is_function(fun, 1), do: fun
  defp normalize_asker(_), do: nil

  defp normalize_initial_lease(%Grant{} = grant, _default_ttl, _now_ms), do: grant

  defp normalize_initial_lease({caps, ttl_ms}, _default_ttl, now_ms) when is_list(caps) do
    Grant.new([capabilities: caps, ttl_ms: ttl_ms, source: :lease], now_ms)
  end

  defp normalize_initial_lease(cap, default_ttl, now_ms) when is_atom(cap) do
    Grant.new([capabilities: [cap], ttl_ms: default_ttl, source: :lease], now_ms)
  end
end
