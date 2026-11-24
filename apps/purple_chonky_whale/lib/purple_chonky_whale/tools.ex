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

  The provision is a `%Tools{}` handle; consumers `inject: [:tools]`.

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

  alias Dexterous.Context

  @typedoc "The tool registry handle, the value bound to the `:tools` coeffect."
  @type t :: %__MODULE__{tools: %{String.t() => module()}, env: map(), scope: Context.scope()}

  defstruct [:tools, :env, :scope]

  @pre_event :"tools/pre-execute"
  @post_event :"tools/post-execute"

  ## Component

  @impl true
  def apply(ctx, config) do
    tools =
      Map.new(Keyword.get(config, :tools, []), fn module -> {module.schema().name, module} end)

    env = Keyword.get(config, :env, %{})

    Context.set(ctx, :tools, %__MODULE__{tools: tools, env: env, scope: ctx.scope})
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
