defmodule PurpleChonkyWhale.Sandbox do
  @moduledoc """
  The `:sandbox` seam provider (`L2`): bounds how external OS processes — both
  `Executor.Runner` plans and stdio `MCP` servers — are launched.

      %DexterousLoader.Entry{
        id: :sandbox,
        component: PurpleChonkyWhale.Sandbox,
        config: [
          backend: PurpleChonkyWhale.Sandbox.Host,
          mode: :workspace_write,
          cwd: File.cwd!(),
          network?: :on_grant,
          fail_open?: false
        ]
      }

  Config:

    * `:backend` — module implementing `PurpleChonkyWhale.Sandbox.Backend`
      (defaults to `PurpleChonkyWhale.Sandbox.Host`)
    * `:mode` — `:read_only | :workspace_write | :full_access`
    * `:cwd`, `:writable_roots`, `:readable_roots`, `:network?`, `:fail_open?`,
      `:env_allowlist` — passed to `PurpleChonkyWhale.Sandbox.Profile`
    * `:backend_opts` — keyword options forwarded to the backend callbacks

  By default `fail_open?` is `false`: if a backend reports itself unavailable
  (for example `Sandbox.Docker` when Docker is absent), `wrap_plan/4` and
  `wrap_stdio/2` return `{:error, reason}` rather than silently falling back
  to unsandboxed host execution.
  """

  use Dexterous.Component, provide: [:sandbox]

  alias Dexterous.Context
  alias PurpleChonkyWhale.Sandbox.{Host, Profile}

  @type t :: %__MODULE__{
          backend: module(),
          profile: Profile.t(),
          opts: keyword(),
          scope: Context.scope() | nil
        }

  defstruct [:backend, :profile, :opts, :scope]

  ## Component

  @impl Dexterous.Component
  def apply(ctx, config) do
    sandbox = from_config(config, ctx.scope)
    Context.set(ctx, :sandbox, sandbox)
  end

  @doc """
  Build a `%Sandbox{}` handle synchronously from component config. Useful when
  a caller (such as `PurpleChonkyWhale.Tools` starting stdio MCP servers) needs
  the handle at initialization time without racing another component's fiber.
  """
  @spec from_config(t() | keyword() | map(), Context.scope() | nil) :: t()
  def from_config(config, scope \\ nil)

  def from_config(%__MODULE__{} = sandbox, scope) do
    %{sandbox | scope: sandbox.scope || scope}
  end

  def from_config(config, scope) when is_list(config) or is_map(config) do
    cfg = Keyword.new(config)
    backend = Keyword.get(cfg, :backend, Host)
    profile = cfg |> Keyword.get(:profile, cfg) |> Profile.new()
    opts = Keyword.get(cfg, :backend_opts, [])

    %__MODULE__{
      backend: backend,
      profile: profile,
      opts: opts,
      scope: scope
    }
  end

  @doc """
  Wrap a materialized `Executor.Runner.plan()` through `sandbox`.

  Merges `env` and `env[:grant]` monotonically onto `sandbox.profile`, checks
  backend availability (failing closed unless `profile.fail_open?` is `true`),
  and delegates to `backend.wrap_plan/4`.
  """
  @spec wrap_plan(t(), map(), map(), map()) :: {:ok, map()} | {:error, String.t()}
  def wrap_plan(%__MODULE__{} = sandbox, plan, run_ctx, env \\ %{})
      when is_map(plan) and is_map(run_ctx) and is_map(env) do
    effective_profile = Profile.merge_env_and_grant(sandbox.profile, env, env[:grant])

    case sandbox.backend.available?(sandbox.opts) do
      :ok ->
        sandbox.backend.wrap_plan(plan, run_ctx, effective_profile, sandbox.opts)

      {:error, reason} ->
        if effective_profile.fail_open? do
          {:ok, plan}
        else
          {:error, "sandbox backend #{inspect(sandbox.backend)} unavailable: #{reason}"}
        end
    end
  end

  @doc """
  Wrap `{:stdio, stdio_opts}` MCP transport options through `sandbox`.

  Fails closed unless `sandbox.profile.fail_open?` is `true`.
  """
  @spec wrap_stdio(t(), keyword()) :: {:ok, keyword()} | {:error, String.t()}
  def wrap_stdio(%__MODULE__{} = sandbox, stdio_opts) when is_list(stdio_opts) do
    effective_profile = Profile.merge_env_and_grant(sandbox.profile, %{}, nil)

    case sandbox.backend.available?(sandbox.opts) do
      :ok ->
        sandbox.backend.wrap_stdio(stdio_opts, effective_profile, sandbox.opts)

      {:error, reason} ->
        if effective_profile.fail_open? do
          {:ok, stdio_opts}
        else
          {:error, "sandbox backend #{inspect(sandbox.backend)} unavailable: #{reason}"}
        end
    end
  end
end
