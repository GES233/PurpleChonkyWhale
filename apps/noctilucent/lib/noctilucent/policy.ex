defmodule Noctilucent.Policy do
  @moduledoc """
  Application-level permission policy (`L3`) for `Noctilucent` compositions.

  Mounted as a `Dexterous.Component` (`provide: [:policy]`) alongside `:tools`
  and `:sessions`, `Noctilucent.Policy` owns:

    * Static command risk classification via `Noctilucent.Policy.ShellLint`
      (unconditional floor for catastrophic shell/PowerShell patterns plus
      high-risk escalation).
    * Capability-based auto-allow rules (`[:fs_read, :ui, :memory]` by
      default), failing closed on `:unknown`, `:mcp`, `:fs_write`, `:exec`,
      and `:hmr`.
    * Bounded TTL capability leases (`%PurpleChonkyWhale.Security.Grant{}` with
      monotonic deadlines) that never cover `:unknown`, `:mcp`, or high-risk
      calls.
    * Serialized interactive approval prompting: concurrent tool batches in
      `AgentLoop` queue through the policy server one prompt at a time, and
      later queued calls automatically reuse a lease granted by an earlier
      prompt in the same batch.
  """

  use GenServer
  use Dexterous.Component, provide: [:policy]

  alias Dexterous.Context
  alias Noctilucent.Policy.ShellLint
  alias PurpleChonkyWhale.Security.Grant

  @default_auto_allow [:fs_read, :ui, :memory]
  @default_lease_ttl_ms 15 * 60_000

  @type ask_choice :: :once | {:lease, pos_integer()} | :deny | {:allow, Grant.t()}
  @type ask_fun :: (map() -> ask_choice())

  ## Component

  @impl Dexterous.Component
  def apply(ctx, config) do
    {:ok, pid} = start_link(config)
    Process.unlink(pid)
    Context.track(ctx, pid)

    {:ok, _disposer} = Context.on(ctx, :"tools/pre-execute", listener(pid))
    Context.set(ctx, :policy, pid)
  end

  ## Public API

  @doc "Start a policy server. Options: `:persona`, `:cwd`, `:home`, `:protected_dirs`, `:auto_allow`, `:ask`, `:lease_ttl_ms`, `:initial_leases`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Build a `:\"tools/pre-execute\"` waterfall listener backed by `policy`."
  @spec listener(pid()) :: (map(), (map() -> map()) -> map())
  def listener(policy) when is_pid(policy) do
    fn call, next ->
      case authorize(policy, call) do
        {:allow, %Grant{} = grant} ->
          next.(%{call | decision: {:allow, grant}})

        {:deny, reason} ->
          %{call | decision: {:deny, reason}}
      end
    end
  end

  @doc "Authorize a tool call payload against `policy`. Fails closed if `policy` is unreachable."
  @spec authorize(pid(), map(), timeout()) :: {:allow, Grant.t()} | {:deny, String.t()}
  def authorize(policy, call, timeout \\ :infinity) when is_pid(policy) and is_map(call) do
    GenServer.call(policy, {:authorize, call}, timeout)
  catch
    :exit, _reason -> {:deny, "policy server unavailable"}
  end

  @doc "Return active (non-expired) TTL leases held by `policy`."
  @spec leases(pid()) :: [Grant.t()]
  def leases(policy) when is_pid(policy) do
    GenServer.call(policy, :leases)
  end

  @doc "Add a TTL lease to `policy` programmatically."
  @spec grant_lease(pid(), [atom()], keyword()) :: {:ok, Grant.t()}
  def grant_lease(policy, capabilities, opts \\ [])
      when is_pid(policy) and is_list(capabilities) do
    GenServer.call(policy, {:grant_lease, capabilities, opts})
  end

  @doc "Revoke all active TTL leases."
  @spec revoke_all(pid()) :: :ok
  def revoke_all(policy) when is_pid(policy) do
    GenServer.call(policy, :revoke_all)
  end

  @doc "Replace or clear the interactive `:ask` callback."
  @spec set_ask(pid(), ask_fun() | nil) :: :ok
  def set_ask(policy, ask_fun) when is_pid(policy) do
    GenServer.call(policy, {:set_ask, ask_fun})
  end

  ## GenServer

  @impl GenServer
  def init(opts) do
    home = Keyword.get(opts, :home)
    protected_dirs = derive_protected_dirs(home, Keyword.get(opts, :protected_dirs))
    auto_allow = opts |> Keyword.get(:auto_allow, @default_auto_allow) |> MapSet.new()
    lease_ttl_ms = Keyword.get(opts, :lease_ttl_ms, @default_lease_ttl_ms)
    now_ms = System.monotonic_time(:millisecond)

    initial_leases =
      opts
      |> Keyword.get(:initial_leases, [])
      |> Enum.map(&normalize_initial_lease(&1, lease_ttl_ms, now_ms))
      |> Enum.reject(&Grant.expired?(&1, now_ms))

    state = %{
      persona: Keyword.get(opts, :persona, :personal),
      cwd: Keyword.get(opts, :cwd),
      protected_dirs: protected_dirs,
      auto_allow: auto_allow,
      ask: normalize_ask(Keyword.get(opts, :ask)),
      lease_ttl_ms: lease_ttl_ms,
      leases: initial_leases,
      active: nil,
      queue: :queue.new()
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:authorize, call}, from, state) do
    now_ms = System.monotonic_time(:millisecond)
    state = prune_leases(state, now_ms)

    if state.active == nil do
      case evaluate_fast(state, call, now_ms) do
        {:reply, decision, state} ->
          {:reply, decision, state}

        {:needs_ask, request_ctx} ->
          state = start_ask(state, from, call, request_ctx)
          {:noreply, state}
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

  def handle_call({:set_ask, ask_fun}, _from, state) do
    {:reply, :ok, %{state | ask: normalize_ask(ask_fun)}}
  end

  @impl GenServer
  def handle_info({:policy_ask_result, ask_ref, choice}, %{active: %{ask_ref: ask_ref}} = state) do
    Process.demonitor(state.active.ask_mon, [:flush])
    Process.demonitor(state.active.caller_ref, [:flush])

    now_ms = System.monotonic_time(:millisecond)
    {decision, state} = resolve_ask_choice(state, state.active, choice, now_ms)
    GenServer.reply(state.active.from, decision)

    state = dispatch_next(%{state | active: nil})
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ask_mon, :process, _pid, _reason},
        %{active: %{ask_mon: ask_mon}} = state
      ) do
    Process.demonitor(state.active.caller_ref, [:flush])
    GenServer.reply(state.active.from, {:deny, "approval prompt aborted"})
    state = dispatch_next(%{state | active: nil})
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, caller_ref, :process, _pid, _reason},
        %{active: %{caller_ref: caller_ref}} = state
      ) do
    Process.demonitor(state.active.ask_mon, [:flush])
    Process.exit(state.active.ask_pid, :kill)
    state = dispatch_next(%{state | active: nil})
    {:noreply, state}
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

  ## Evaluation & Queueing

  defp evaluate_fast(state, call, now_ms) do
    name = Map.get(call, :name, "")
    args = Map.get(call, :arguments, %{})
    caps = Map.get(call, :capabilities, [:unknown])

    lint =
      if name == "execute" do
        ShellLint.inspect(args, protected_dirs: state.protected_dirs)
      else
        %{verdict: :ok, risk: :low, reasons: []}
      end

    high_risk? =
      lint.verdict == :ask or
        :mcp in caps or
        :unknown in caps or
        (name == "execute" and Map.get(args, "runtime") == "elixir")

    cond do
      lint.verdict == :deny ->
        {:reply, {:deny, "blocked by shell lint: #{Enum.join(lint.reasons, "; ")}"}, state}

      not high_risk? and auto_allowed?(caps, state.auto_allow) ->
        grant =
          Grant.new(
            capabilities: caps,
            source: :policy,
            reason: "auto-allowed capability"
          )

        {:reply, {:allow, grant}, state}

      not high_risk? and matching_lease(state.leases, name, caps, now_ms) != nil ->
        lease = matching_lease(state.leases, name, caps, now_ms)

        grant =
          Grant.new(
            capabilities: caps,
            tools: lease.tools,
            expires_at: lease.expires_at,
            source: :lease,
            reason: lease.reason || "active TTL lease"
          )

        {:reply, {:allow, grant}, state}

      is_nil(state.ask) ->
        reason =
          case lint.reasons do
            [] -> "tool #{name} (#{inspect(caps)}) requires approval (non-interactive policy)"
            reasons -> "tool #{name} requires approval: #{Enum.join(reasons, "; ")}"
          end

        {:reply, {:deny, reason}, state}

      true ->
        {:needs_ask, %{name: name, args: args, caps: caps, lint: lint, high_risk?: high_risk?}}
    end
  end

  defp start_ask(state, from, call, request_ctx) do
    {caller_pid, _tag} = from
    caller_ref = Process.monitor(caller_pid)
    ask_ref = make_ref()
    server = self()
    ask_fun = state.ask

    leaseable =
      if request_ctx.high_risk? do
        []
      else
        Enum.reject(request_ctx.caps, &(&1 in [:unknown, :mcp]))
      end

    request = %{
      tool: request_ctx.name,
      arguments: request_ctx.args,
      capabilities: request_ctx.caps,
      summary: summarize_call(request_ctx.name, request_ctx.args),
      warnings: request_ctx.lint.reasons,
      high_risk?: request_ctx.high_risk?,
      leaseable_capabilities: leaseable,
      default_lease_ms: state.lease_ttl_ms,
      session_id: Map.get(call, :session_id),
      run_id: Map.get(call, :run_id),
      tool_call_id: Map.get(call, :tool_call_id)
    }

    {ask_pid, ask_mon} =
      spawn_monitor(fn ->
        choice =
          try do
            ask_fun.(request)
          rescue
            _ -> :deny
          catch
            _, _ -> :deny
          end

        send(server, {:policy_ask_result, ask_ref, choice})
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
          leaseable: leaseable
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

        case evaluate_fast(state, item.call, now_ms) do
          {:reply, decision, state} ->
            Process.demonitor(item.caller_ref, [:flush])
            GenServer.reply(item.from, decision)
            dispatch_next(state)

          {:needs_ask, request_ctx} ->
            Process.demonitor(item.caller_ref, [:flush])
            start_ask(state, item.from, item.call, request_ctx)
        end
    end
  end

  defp resolve_ask_choice(state, active, :once, _now_ms) do
    grant =
      Grant.new(
        capabilities: active.caps,
        tools: [active.name],
        source: :once,
        reason: "approved once by user"
      )

    {{:allow, grant}, state}
  end

  defp resolve_ask_choice(state, active, {:lease, ttl_ms}, now_ms)
       when is_integer(ttl_ms) and ttl_ms > 0 do
    if active.leaseable != [] and not active.high_risk? do
      lease =
        Grant.new(
          [
            capabilities: active.leaseable,
            ttl_ms: ttl_ms,
            source: :lease,
            reason: "user lease (#{div(ttl_ms, 1000)}s)"
          ],
          now_ms
        )

      state = %{state | leases: [lease | state.leases]}

      grant =
        Grant.new(
          capabilities: active.caps,
          expires_at: lease.expires_at,
          source: :lease,
          reason: lease.reason
        )

      {{:allow, grant}, state}
    else
      # High-risk / unknown / MCP calls cannot create standing leases; fail
      # closed to a single-use grant only if explicitly confirmed as :once, or
      # deny lease attempts on non-leaseable capabilities.
      {{:deny, "standing leases are not permitted for high-risk or #{active.name} calls"}, state}
    end
  end

  defp resolve_ask_choice(state, active, {:allow, %Grant{} = custom}, now_ms) do
    if Grant.allows?(custom, active.name, active.caps, now_ms) do
      {{:allow, custom}, state}
    else
      {{:deny, "custom grant does not cover #{active.name}"}, state}
    end
  end

  defp resolve_ask_choice(state, _active, _other, _now_ms) do
    {{:deny, "denied by user"}, state}
  end

  defp auto_allowed?(caps, auto_allow) when is_list(caps) do
    :unknown not in caps and MapSet.subset?(MapSet.new(caps), auto_allow)
  end

  defp matching_lease(leases, name, caps, now_ms) do
    Enum.find(leases, &Grant.allows?(&1, name, caps, now_ms))
  end

  defp prune_leases(state, now_ms) do
    %{state | leases: Enum.reject(state.leases, &Grant.expired?(&1, now_ms))}
  end

  defp normalize_ask(fun) when is_function(fun, 1), do: fun
  defp normalize_ask(_), do: nil

  defp normalize_initial_lease(%Grant{} = grant, _default_ttl, _now_ms), do: grant

  defp normalize_initial_lease({caps, ttl_ms}, _default_ttl, now_ms) when is_list(caps) do
    Grant.new([capabilities: caps, ttl_ms: ttl_ms, source: :lease], now_ms)
  end

  defp normalize_initial_lease(cap, default_ttl, now_ms) when is_atom(cap) do
    Grant.new([capabilities: [cap], ttl_ms: default_ttl, source: :lease], now_ms)
  end

  defp derive_protected_dirs(home, nil) do
    user_dsh =
      case System.user_home() do
        nil -> []
        user_home -> [Path.join(user_home, ".dsh")]
      end

    Enum.uniq(Enum.filter([home], &is_binary/1) ++ user_dsh)
  end

  defp derive_protected_dirs(_home, dirs) when is_list(dirs), do: dirs

  defp summarize_call("execute", args) do
    runtime = Map.get(args, "runtime", "shell")
    code = args |> Map.get("code", "") |> String.trim()
    preview = if String.length(code) > 160, do: String.slice(code, 0, 160) <> "...", else: code
    "execute (#{runtime}): #{preview}"
  end

  defp summarize_call(name, %{"file_path" => path}) when is_binary(path) do
    "#{name} -> #{path}"
  end

  defp summarize_call(name, args) do
    "#{name} #{inspect(args)}"
  end
end
