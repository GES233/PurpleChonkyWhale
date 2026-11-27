defmodule PurpleChonkyWhale.Tool do
  @moduledoc """
  The tool contract: a declarative schema plus an execution function.

  A tool is a plain module (not a component — tools are cheap, and the ones
  that need coeffects get them through the execution environment the
  registry hands over):

      defmodule MyTool do
        @behaviour PurpleChonkyWhale.Tool

        @impl true
        def schema do
          %{
            name: "my_tool",
            description: "Does a thing",
            parameters: %{
              "type" => "object",
              "properties" => %{"arg" => %{"type" => "string"}},
              "required" => ["arg"]
            }
          }
        end

        @impl true
        def execute(%{"arg" => arg}, env) do
          {:ok, "got #\{arg} from #\{inspect(env)}"}
        end
      end

  `execute/2` receives the model-supplied arguments (string keys, as decoded
  from the tool call's JSON) and the registry's execution environment (see
  `PurpleChonkyWhale.Tools`). It returns `{:ok, output}` — any JSON-encodable
  term — or `{:error, reason}`; an uncaught exception is caught by the
  pipeline and reported as `{:error, %{type: :crashed}}`.

  For multi-part output (e.g. text plus an image), return
  `{:ok, {:parts, parts}}` with parts built by
  `PurpleChonkyWhale.ToolResult.text_part/1` and
  `PurpleChonkyWhale.ToolResult.image_part/2`.
  """

  @typedoc "A tool's declarative schema; `parameters` is a JSON Schema map."
  @type schema :: %{name: String.t(), description: String.t(), parameters: map()}

  @typedoc "Capability tag declared by a tool module for policy gating."
  @type capability ::
          :fs_read | :fs_write | :exec | :net | :hmr | :memory | :ui | :mcp | :unknown

  @typedoc "The execution environment handed to `execute/2` by the registry."
  @type env :: map()

  @callback schema() :: schema()
  @callback execute(args :: map(), env()) :: {:ok, term()} | {:error, term()}
  @callback capabilities() :: [capability()]
  @optional_callbacks capabilities: 0

  alias PurpleChonkyWhale.Security.PathGuard

  @doc """
  Return the capabilities declared by `module`.

  Tools that omit `capabilities/0` (or return a non-list value) default to
  `[:unknown]` so permission policies fail closed on undeclared tools.
  """
  @spec capabilities(module()) :: [capability()]
  def capabilities(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :capabilities, 0) do
      case module.capabilities() do
        caps when is_list(caps) ->
          if Enum.all?(caps, &is_atom/1), do: caps, else: [:unknown]

        _other ->
          [:unknown]
      end
    else
      [:unknown]
    end
  end

  @doc """
  Resolve a model-supplied path against the environment's `:cwd` (falling
  back to the process cwd). Absolute paths pass through unchanged.

  Prefer `authorize_path/3` in tools so workspace boundaries, symlinks and the
  write self-destruct floor are enforced.
  """
  @spec resolve_path(env(), String.t()) :: String.t()
  def resolve_path(env, path) when is_binary(path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.join(env[:cwd] || File.cwd!(), path)
    end
  end

  @doc """
  Resolve and authorize a model-supplied path for `:read` or `:write` via
  `PurpleChonkyWhale.Security.PathGuard`.
  """
  @spec authorize_path(env() | keyword(), term(), PathGuard.access()) ::
          {:ok, String.t()} | {:error, String.t()}
  def authorize_path(env, path, access) when access in [:read, :write] do
    PathGuard.authorize(env, path, access)
  end
end
