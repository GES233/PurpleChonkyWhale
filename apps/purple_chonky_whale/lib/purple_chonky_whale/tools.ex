defmodule PurpleChonkyWhale.Tools do
  @moduledoc """
  The `:tools` seam provider: a registry of tool modules with a guarded
  execution pipeline.

      %DexterousLoader.Entry{
        id: :tools,
        component: PurpleChonkyWhale.Tools,
        config: [tools: [MyTool, AnotherTool], env: %{cwd: File.cwd!()}]
      }

  Config:

    * `:tools` — the tool modules (each implementing `PurpleChonkyWhale.Tool`)
    * `:env` — the execution environment handed to every `execute/2`
      (e.g. `%{cwd: ...}`), defaults to `%{}`
    * `:require_grant?` — when `true`, every tool call must obtain a valid
      `{:allow, %PurpleChonkyWhale.Security.Grant{}}` from `:"tools/pre-execute"`
      whose capabilities, tool scope and TTL cover the target tool; defaults to
      `false` for bare kernel compositions
    * `:mcp_servers` — MCP server declarations (see
      `PurpleChonkyWhale.MCP`), defaults to `[]` (no processes, no behaviour
      change). Each server's tools are registered as ordinary tools named
      `mcp_<server>_<tool>` and run through the very same pipeline below —
      approval hooks on `tools/pre-execute` cover them. A name collision
      with a static tool is won by the static tool (with a warning).
    * `:mcp_backend` — internal; the client backend handed to
      `PurpleChonkyWhale.MCP`, defaults to `Anubis.Client` and is swapped
      for a fake in tests (mirroring `PurpleChonkyWhale.LLM`'s `:backend`)

  The provision is a `%Tools{}` handle; consumers `inject: [:tools]`.
  Without `update/3`, a config change reconciles through a full rebuild,
  which is also the correct semantics for the MCP connections (reconnect).

  ## The execution pipeline

  `execute/3` and `execute/4` run a call through the scope's events (consumers
  of the seam subscribe with `Context.on/3`):

    * `:"tools/pre-execute"` — a *fail-closed, monotonic waterfall* over
      `%{name:, arguments:, capabilities:, decision:, session_id:, run_id:, tool_call_id:}`.
      Listeners may rewrite arguments or narrow `decision` to
      `{:allow, %PurpleChonkyWhale.Security.Grant{}}` or `{:deny, reason}`.
      Decisions are strictly monotonic across the chain: a `{:deny, reason}`
      cannot be undone by later or wrapping listeners, multiple grants are
      intersected via `Grant.narrow/2`, and any listener crash or invalid
      payload/decision fails closed to `:denied`.
    * `:"tools/post-execute"` — an *emit* with
      `%{name:, arguments:, result:, duration_ms:, session_id:, run_id:, tool_call_id:}`
      for every settled call.

  Results are typed: `{:ok, output}` or `{:error, %{type:, message:}}` with
  `:type` one of `:unknown_tool | :denied | :crashed`.
  """

  use Dexterous.Component, provide: [:tools]

  require Logger

  alias Dexterous.{Context, Store}
  alias PurpleChonkyWhale.{MCP, Tool}
  alias PurpleChonkyWhale.Security.Grant

  @typedoc "The tool registry handle, the value bound to the `:tools` coeffect."
  @type t :: %__MODULE__{
          tools: %{String.t() => module()},
          env: map(),
          scope: Context.scope(),
          mcp: MCP.t() | nil,
          require_grant?: boolean()
        }

  defstruct [:tools, :env, :scope, :mcp, require_grant?: false]

  @pre_event :"tools/pre-execute"
  @post_event :"tools/post-execute"

  ## Component

  @impl true
  def apply(ctx, config) do
    static_tools =
      Map.new(Keyword.get(config, :tools, []), fn module -> {module.schema().name, module} end)

    {mcp_tools, mcp} = start_mcp(ctx, config)

    collisions = Enum.filter(Map.keys(mcp_tools), &Map.has_key?(static_tools, &1))

    if collisions != [] do
      Logger.warning(
        "MCP tools colliding with static tools are dropped: #{Enum.join(collisions, ", ")}"
      )
    end

    tools = Map.merge(mcp_tools, static_tools)

    env = Keyword.get(config, :env, %{})
    require_grant? = Keyword.get(config, :require_grant?, false) == true

    Context.set(ctx, :tools, %__MODULE__{
      tools: tools,
      env: env,
      scope: ctx.scope,
      mcp: mcp,
      require_grant?: require_grant?
    })
  end

  # No `:mcp_servers` (the default) means no processes and zero behaviour
  # change. Otherwise the MCP clients are owned through Context.track/2
  # disposers, not links, like Sessions' subprocesses: both trap exits, and
  # a trapping process dies when its parent (the fiber's transient apply
  # process) exits.
  defp start_mcp(ctx, config) do
    case Keyword.get(config, :mcp_servers, []) do
      [] ->
        {%{}, nil}

      servers ->
        backend = Keyword.get(config, :mcp_backend, Anubis.Client)
        {:ok, mcp} = MCP.start_link(servers, backend: backend)
        registry_pid = Process.whereis(mcp.registry)

        Process.unlink(mcp.sup)
        Process.unlink(registry_pid)
        Context.track(ctx, mcp.sup)
        Context.track(ctx, registry_pid)

        {MCP.tool_modules(mcp, backend: backend), mcp}
    end
  end

  ## Registry

  @doc "Return a copy of `registry` with `extra_env` merged into its base environment."
  @spec with_env(t(), map() | keyword()) :: t()
  def with_env(%__MODULE__{} = registry, extra_env) do
    %{registry | env: Map.merge(registry.env || %{}, Map.new(extra_env))}
  end

  @doc """
  The registered tool schemas, sorted by name.

  Sorted on purpose: the registry is a map, so `Map.values/1` order is
  incidental (name order for a small map, hash order past 32 entries) and
  changes as tools are added or MCP servers merge in. The model-facing tool
  list is the prefix of the request, i.e. the part providers cache, so the
  order has to be a property of the tools, not of the map's internals.
  """
  @spec schemas(t()) :: [PurpleChonkyWhale.Tool.schema()]
  def schemas(%__MODULE__{} = registry) do
    registry.tools
    |> Map.values()
    |> Enum.map(& &1.schema())
    |> Enum.sort_by(& &1.name)
  end

  @doc "The tool module registered under `name`, or `:error`."
  @spec lookup(t(), String.t()) :: {:ok, module()} | :error
  def lookup(%__MODULE__{} = registry, name), do: Map.fetch(registry.tools, name)

  @doc """
  Run the tool `name` with `arguments` through the pipeline. Optional `call_env`
  merges per-call identities (`:session_id`, `:run_id`, `:tool_call_id`) into the
  environment handed to the tool module and emitted events. Never raises for
  tool-level failures: see the module doc for the result contract.
  """
  @spec execute(t(), String.t(), map(), map() | keyword()) :: {:ok, term()} | {:error, map()}
  def execute(%__MODULE__{} = registry, name, arguments, call_env \\ %{})
      when is_map(arguments) do
    ctx = Context.new(registry.scope)
    env = derive_env(registry, call_env)

    case lookup(registry, name) do
      :error ->
        result = {:error, %{type: :unknown_tool, message: "unknown tool: #{name}"}}
        emit_post(ctx, name, arguments, result, 0, env)
        result

      {:ok, module} ->
        caps = Tool.capabilities(module)
        initial_decision = if registry.require_grant?, do: :pending, else: :run

        call = %{
          name: name,
          arguments: arguments,
          capabilities: caps,
          decision: initial_decision,
          session_id: env[:session_id],
          run_id: env[:run_id],
          tool_call_id: env[:tool_call_id]
        }

        final_call = run_pre_execute(ctx, call, registry.require_grant?)
        enforce_and_run(registry, final_call, env, ctx)
    end
  end

  defp derive_env(%__MODULE__{} = registry, call_env) do
    (registry.env || %{})
    |> Map.put_new(:scope, registry.scope)
    |> Map.merge(Map.new(call_env))
  end

  defp run_pre_execute(ctx, call, require_grant?) do
    ref = make_ref()
    key = {__MODULE__, ref}
    Process.put(key, call.decision)

    try do
      listeners = Store.listeners_for(ctx.scope, @pre_event)
      result = run_pre_chain(listeners, call, key, require_grant?)
      floor = Process.get(key)

      case result do
        %{name: out_name, arguments: out_args} when is_binary(out_name) and is_map(out_args) ->
          merged = monotonic_decision(floor, Map.get(result, :decision), require_grant?)
          %{result | decision: merged}

        %{} ->
          %{call | decision: {:deny, "invalid pre-execute payload: missing name or arguments"}}

        _other ->
          %{call | decision: {:deny, "invalid pre-execute payload"}}
      end
    rescue
      exception ->
        %{call | decision: {:deny, "pre-execute hook failed: #{Exception.message(exception)}"}}
    catch
      :throw, {:invalid_pre_payload, _other} ->
        %{call | decision: {:deny, "invalid pre-execute payload"}}

      kind, reason ->
        %{call | decision: {:deny, "pre-execute hook failed: #{kind}: #{inspect(reason)}"}}
    after
      Process.delete(key)
    end
  end

  defp run_pre_chain([], payload, key, require_grant?) do
    record_decision(payload, key, require_grant?)
  end

  defp run_pre_chain([listener | rest], payload, key, require_grant?) do
    payload = record_decision(payload, key, require_grant?)

    out =
      case Function.info(listener, :arity) do
        {:arity, 1} ->
          next_payload = listener.(payload) |> record_decision(key, require_grant?)
          run_pre_chain(rest, next_payload, key, require_grant?)

        {:arity, 2} ->
          listener.(payload, fn new_payload ->
            next_payload = record_decision(new_payload, key, require_grant?)
            run_pre_chain(rest, next_payload, key, require_grant?)
          end)
      end

    record_decision(out, key, require_grant?)
  end

  defp record_decision(payload, key, require_grant?) when is_map(payload) do
    floor = Process.get(key)
    merged = monotonic_decision(floor, Map.get(payload, :decision), require_grant?)
    Process.put(key, merged)
    Map.put(payload, :decision, merged)
  end

  defp record_decision(other, _key, _require_grant?) do
    throw({:invalid_pre_payload, other})
  end

  # Strictly monotonic decision lattice:
  #   :run (only when require_grant? == false) -> :pending / {:allow, %Grant{}} -> {:deny, reason}
  # Once denied, no listener may un-deny; two grants combine via Grant.narrow/2.
  defp monotonic_decision({:deny, _} = deny, _candidate, _require_grant?), do: deny
  defp monotonic_decision(_current, {:deny, _} = deny, _require_grant?), do: deny

  defp monotonic_decision(current, candidate, require_grant?) do
    cond do
      not valid_decision?(candidate) ->
        {:deny, "invalid pre-execute decision: #{inspect(candidate)}"}

      match?({:allow, %Grant{}}, current) and match?({:allow, %Grant{}}, candidate) ->
        {:allow, grant_a} = current
        {:allow, grant_b} = candidate
        {:allow, Grant.narrow(grant_a, grant_b)}

      match?({:allow, %Grant{}}, current) ->
        current

      match?({:allow, %Grant{}}, candidate) ->
        candidate

      current == :pending ->
        :pending

      candidate == :pending ->
        :pending

      require_grant? ->
        :pending

      true ->
        :run
    end
  end

  defp valid_decision?(:run), do: true
  defp valid_decision?(:pending), do: true
  defp valid_decision?({:allow, %Grant{}}), do: true
  defp valid_decision?(_other), do: false

  defp enforce_and_run(_registry, %{decision: {:deny, reason}}, _env, _ctx) do
    {:error, %{type: :denied, message: to_string(reason)}}
  end

  defp enforce_and_run(registry, call, env, ctx) do
    case lookup(registry, call.name) do
      :error ->
        result = {:error, %{type: :unknown_tool, message: "unknown tool: #{call.name}"}}
        emit_post(ctx, call.name, call.arguments, result, 0, env)
        result

      {:ok, module} ->
        caps = Tool.capabilities(module)

        case call.decision do
          {:allow, %Grant{} = grant} ->
            if Grant.allows?(grant, call.name, caps) do
              run_module(module, call, Grant.apply_to_env(grant, env), ctx)
            else
              {:error, %{type: :denied, message: denial_message(grant, call.name, caps)}}
            end

          :run when not registry.require_grant? ->
            run_module(module, call, env, ctx)

          :run ->
            {:error,
             %{
               type: :denied,
               message: "denied: tool #{call.name} requires an explicit capability grant"
             }}

          _other ->
            {:error,
             %{
               type: :denied,
               message: "denied: no matching capability grant for #{call.name}"
             }}
        end
    end
  end

  defp denial_message(%Grant{} = grant, name, caps) do
    cond do
      Grant.expired?(grant, System.monotonic_time(:millisecond)) ->
        "denied: capability grant for #{name} has expired"

      grant.tools != :any and not MapSet.member?(grant.tools, name) ->
        "denied: capability grant does not cover tool #{name}"

      true ->
        missing =
          caps
          |> MapSet.new()
          |> MapSet.difference(grant.capabilities)
          |> MapSet.to_list()

        "denied: grant missing required capabilities #{inspect(missing)} for #{name}"
    end
  end

  defp run_module(module, call, env, ctx) do
    started = System.monotonic_time(:millisecond)

    result =
      try do
        module.execute(call.arguments, env)
      rescue
        exception -> {:error, %{type: :crashed, message: Exception.message(exception)}}
      catch
        kind, reason -> {:error, %{type: :crashed, message: "#{kind}: #{inspect(reason)}"}}
      end

    duration = System.monotonic_time(:millisecond) - started
    emit_post(ctx, call.name, call.arguments, result, duration, env)
    result
  end

  defp emit_post(ctx, name, arguments, result, duration_ms, env) do
    Context.emit(ctx, @post_event, %{
      name: name,
      arguments: arguments,
      result: result,
      duration_ms: duration_ms,
      session_id: env[:session_id],
      run_id: env[:run_id],
      tool_call_id: env[:tool_call_id]
    })
  end
end
