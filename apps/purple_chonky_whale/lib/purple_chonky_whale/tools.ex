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

    * `:"tools/pre-execute"` — a *waterfall* over
      `%{name:, arguments:, decision: :run, session_id:, run_id:, tool_call_id:}`.
      Listeners may rewrite the arguments, or deny the call by transforming
      `decision` to `{:deny, reason}` (typically also declining `next.()` to
      short-circuit the chain). This is where approval policy hooks in.
    * `:"tools/post-execute"` — an *emit* with
      `%{name:, arguments:, result:, duration_ms:, session_id:, run_id:, tool_call_id:}`
      for every settled call.

  Results are typed: `{:ok, output}` or `{:error, %{type:, message:}}` with
  `:type` one of `:unknown_tool | :denied | :crashed`.
  """

  use Dexterous.Component, provide: [:tools]

  require Logger

  alias Dexterous.Context
  alias PurpleChonkyWhale.MCP

  @typedoc "The tool registry handle, the value bound to the `:tools` coeffect."
  @type t :: %__MODULE__{
          tools: %{String.t() => module()},
          env: map(),
          scope: Context.scope(),
          mcp: MCP.t() | nil
        }

  defstruct [:tools, :env, :scope, :mcp]

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

    Context.set(ctx, :tools, %__MODULE__{tools: tools, env: env, scope: ctx.scope, mcp: mcp})
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

  @doc "The registered tool schemas, in registration-independent name order."
  @spec schemas(t()) :: [PurpleChonkyWhale.Tool.schema()]
  def schemas(%__MODULE__{} = registry) do
    registry.tools |> Map.values() |> Enum.map(& &1.schema())
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

    call = %{
      name: name,
      arguments: arguments,
      decision: :run,
      session_id: env[:session_id],
      run_id: env[:run_id],
      tool_call_id: env[:tool_call_id]
    }

    call = Context.waterfall(ctx, @pre_event, call)

    case call.decision do
      :run -> run(registry, call, env, ctx)
      {:deny, reason} -> {:error, %{type: :denied, message: to_string(reason)}}
    end
  end

  defp derive_env(%__MODULE__{} = registry, call_env) do
    (registry.env || %{})
    |> Map.put_new(:scope, registry.scope)
    |> Map.merge(Map.new(call_env))
  end

  defp run(registry, call, env, ctx) do
    started = System.monotonic_time(:millisecond)

    result =
      with {:ok, module} <- lookup(registry, call.name) do
        try do
          module.execute(call.arguments, env)
        rescue
          exception -> {:error, %{type: :crashed, message: Exception.message(exception)}}
        catch
          kind, reason -> {:error, %{type: :crashed, message: "#{kind}: #{inspect(reason)}"}}
        end
      else
        :error -> {:error, %{type: :unknown_tool, message: "unknown tool: #{call.name}"}}
      end

    Context.emit(ctx, @post_event, %{
      name: call.name,
      arguments: call.arguments,
      result: result,
      duration_ms: System.monotonic_time(:millisecond) - started,
      session_id: env[:session_id],
      run_id: env[:run_id],
      tool_call_id: env[:tool_call_id]
    })

    result
  end
end
