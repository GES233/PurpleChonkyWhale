defmodule Noctilucent.Policy do
  @moduledoc """
  Noctilucent's `:policy` component: `Clearance` plus this application's
  opinions.

  The decision engine lives in `Clearance`. What stays here is everything
  that is genuinely a Noctilucent choice:

    * the shell / PowerShell / Python / Elixir static analysis
      (`Clearance.Lint`), wired in as `Clearance`'s `:lint` for
      the `execute` tool
    * `runtime: "elixir"` always asks, because that runtime evaluates inside
      this BEAM with no isolation
    * the default protected directories derived from the persona's `home`
    * the `:ask` option name the CLI and presets already use (mapped onto
      `Clearance`'s `:asker`)

  Everything else — auto-allow, leases, prompt serialization, fail-closed
  behaviour — is the shared engine, so a headless application can mount
  `Clearance.Component` with `Clearance.Asker.DenyAll` and get the same
  semantics without copying this module.
  """

  use Dexterous.Component, provide: [:policy]

  alias Dexterous.Context
  alias Clearance.Lint

  @default_auto_allow [:fs_read, :ui, :memory]
  @default_lease_ttl_ms 15 * 60_000

  ## Component

  @impl Dexterous.Component
  def apply(ctx, config) do
    {:ok, pid} = Clearance.Policy.start_link(clearance_opts(config))
    Process.unlink(pid)
    Context.track(ctx, pid)

    {:ok, _disposer} = Context.on(ctx, :"tools/pre-execute", Clearance.listener(pid))
    Context.set(ctx, :policy, pid)
  end

  ## Delegation to the shared engine

  @doc "Start a policy server with Noctilucent's defaults. Options are `Clearance.Policy`'s."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    Clearance.Policy.start_link(clearance_opts(opts))
  end

  @doc "Authorize a tool call payload. Fails closed if the policy is unreachable."
  @spec authorize(pid(), map(), timeout()) ::
          {:allow, PurpleChonkyWhale.Security.Grant.t()} | {:deny, String.t()}
  def authorize(policy, call, timeout \\ :infinity) do
    Clearance.check(policy, call, timeout)
  end

  @doc "Build a `:\"tools/pre-execute\"` waterfall listener backed by `policy`."
  @spec listener(pid()) :: (map(), (map() -> map()) -> map())
  def listener(policy), do: Clearance.listener(policy)

  @doc "Active (non-expired) TTL leases held by `policy`."
  @spec leases(pid()) :: [PurpleChonkyWhale.Security.Grant.t()]
  def leases(policy), do: Clearance.leases(policy)

  @doc "Add a TTL lease to `policy` programmatically."
  @spec grant_lease(pid(), [atom()], keyword()) ::
          {:ok, PurpleChonkyWhale.Security.Grant.t()}
  def grant_lease(policy, capabilities, opts \\ []) do
    Clearance.grant_lease(policy, capabilities, opts)
  end

  @doc "Revoke all active TTL leases."
  @spec revoke_all(pid()) :: :ok
  def revoke_all(policy), do: Clearance.revoke_all(policy)

  @doc "Replace or clear the interactive asker."
  @spec set_ask(pid(), Clearance.Asker.asker() | nil) :: :ok
  def set_ask(policy, ask_fun), do: Clearance.set_asker(policy, ask_fun)

  ## Noctilucent's policy configuration

  defp clearance_opts(config) do
    [
      asker: Keyword.get(config, :asker) || Keyword.get(config, :ask),
      auto_allow: Keyword.get(config, :auto_allow, @default_auto_allow),
      lease_ttl_ms: Keyword.get(config, :lease_ttl_ms, @default_lease_ttl_ms),
      initial_leases: Keyword.get(config, :initial_leases, []),
      protected_dirs:
        derive_protected_dirs(Keyword.get(config, :home), Keyword.get(config, :protected_dirs)),
      lint: &Lint.inspect/2,
      lint_tools: ["execute"],
      force_ask?: &force_ask?/3
    ]
  end

  defp force_ask?("execute", args, _caps), do: Map.get(args, "runtime") == "elixir"
  defp force_ask?(_name, _args, _caps), do: false

  defp derive_protected_dirs(home, nil) do
    user_dsh =
      case System.user_home() do
        nil -> []
        user_home -> [Path.join(user_home, ".dsh")]
      end

    Enum.uniq(Enum.filter([home], &is_binary/1) ++ user_dsh)
  end

  defp derive_protected_dirs(_home, dirs) when is_list(dirs), do: dirs
end
