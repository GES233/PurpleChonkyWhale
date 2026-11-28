defmodule Clearance do
  @moduledoc """
  Authorization for agent tool calls: the layer that decides *whether* an
  action may run.

  Clearance is deliberately the sibling of two things it does not own:

    * `PurpleChonkyWhale.Security.Grant` (kernel) is the *currency* — the
      structured capability grant a `tools/pre-execute` listener returns as
      `{:allow, %Grant{}}`. Clearance issues grants; it does not define their
      structure or narrowing semantics.
    * `PurpleChonkyWhale.Sandbox` (kernel) is the *barrier* — how OS processes
      are actually confined once a call was allowed.

  A decision is one of three things: auto-allow from `:auto_allow`
  capabilities, allow because an unexpired lease covers the call, or "needs a
  human". The last one is serialized by `Clearance.Policy` so a concurrent
  tool batch queues behind a single prompt instead of racing several.

  ## Wiring

  Mount `Clearance.Component` as a composition entry (it provides `:policy`),
  or start `Clearance.Policy` yourself and attach `listener/1` to the
  `:"tools/pre-execute"` waterfall of an existing composition:

      {:ok, policy} = Clearance.Policy.start_link(asker: &MyApp.ask/1)
      {:ok, _disposer} = Context.on(ctx, :"tools/pre-execute", Clearance.listener(policy))

  A headless application passes `Clearance.Asker.DenyAll` (or its own asker)
  and keeps the same lease semantics as an interactive one.
  """

  alias Clearance.Policy
  alias PurpleChonkyWhale.Security.Grant

  @doc "Authorize one tool call payload. Fails closed if the policy is gone."
  @spec check(pid(), map(), timeout()) :: {:allow, Grant.t()} | {:deny, String.t()}
  def check(policy, call, timeout \\ :infinity) when is_pid(policy) and is_map(call) do
    Policy.check(policy, call, timeout)
  end

  @doc """
  Build a `:\"tools/pre-execute\"` waterfall listener backed by `policy`.

  The listener narrows nothing by itself: it fills `call.decision` with
  `{:allow, grant}` or `{:deny, reason}` and calls the next listener.
  """
  @spec listener(pid()) :: (map(), (map() -> map()) -> map())
  def listener(policy) when is_pid(policy) do
    fn call, next ->
      case check(policy, call) do
        {:allow, %Grant{} = grant} ->
          next.(%{call | decision: {:allow, grant}})

        {:deny, reason} ->
          %{call | decision: {:deny, reason}}
      end
    end
  end

  @doc "Active (non-expired) TTL leases held by `policy`, newest first."
  @spec leases(pid()) :: [Grant.t()]
  def leases(policy) when is_pid(policy), do: Policy.leases(policy)

  @doc "Add a TTL lease to `policy` programmatically."
  @spec grant_lease(pid(), [atom()], keyword()) :: {:ok, Grant.t()}
  def grant_lease(policy, capabilities, opts \\ [])
      when is_pid(policy) and is_list(capabilities) do
    Policy.grant_lease(policy, capabilities, opts)
  end

  @doc "Revoke all active TTL leases."
  @spec revoke_all(pid()) :: :ok
  def revoke_all(policy) when is_pid(policy), do: Policy.revoke_all(policy)

  @doc "Replace or clear the interactive asker."
  @spec set_asker(pid(), Clearance.Asker.asker() | nil) :: :ok
  def set_asker(policy, asker) when is_pid(policy), do: Policy.set_asker(policy, asker)
end
