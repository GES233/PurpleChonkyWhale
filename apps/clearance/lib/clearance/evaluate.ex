defmodule Clearance.Evaluate do
  @moduledoc """
  The decision ladder, as a pure function: `run/3` answers "allow, deny, or
  ask?" from a snapshot of policy state, and `resolve/3` turns an asker's
  choice into a grant (plus, for a lease choice, the lease to store).

  Keeping both halves pure is what makes the ladder testable without a
  process: the GenServer only owns state, ordering, and the ask lifecycle.

  Ladder order matters:

    1. a `:deny` lint verdict is final — no lease, no ask, no override
    2. capabilities covered by `:auto_allow` pass without a prompt
    3. an unexpired lease covering the call passes without a prompt
    4. no asker configured means deny (non-interactive fail-closed)
    5. otherwise the call needs approval

  Steps 2 and 3 are skipped for high-risk calls, so a standing lease can
  never authorize something the policy wants a human to see every time.
  """

  alias PurpleChonkyWhale.Security.Grant

  @type decision ::
          {:allow, Grant.t()} | {:deny, String.t()} | {:needs_ask, map()}

  @doc """
  Decide one call against a policy snapshot (the keys `Clearance.Policy`
  takes: `:leases`, `:auto_allow`, `:asker`, `:lint`, `:lint_tools`,
  `:force_ask?`, `:approval_caps`, `:protected_dirs`).
  """
  @spec run(map(), map(), integer()) :: decision()
  def run(call, policy, now_ms) when is_map(call) and is_map(policy) do
    name = Map.get(call, :name, "")
    args = Map.get(call, :arguments, %{})
    caps = Map.get(call, :capabilities, [:unknown])

    lint = lint(policy, name, args)
    high_risk? = high_risk?(policy, lint, caps, name, args)
    lease = matching_lease(Map.get(policy, :leases), name, caps, now_ms)

    cond do
      lint.verdict == :deny ->
        {:deny, "blocked by shell lint: #{Enum.join(lint.reasons, "; ")}"}

      not high_risk? and auto_allowed?(caps, policy) ->
        {:allow,
         Grant.new(capabilities: caps, source: :policy, reason: "auto-allowed capability")}

      not high_risk? and lease != nil ->
        {:allow,
         Grant.new(
           capabilities: caps,
           tools: lease.tools,
           expires_at: lease.expires_at,
           source: :lease,
           reason: lease.reason || "active TTL lease"
         )}

      Map.get(policy, :asker) == nil ->
        {:deny, no_asker_reason(name, caps, lint)}

      true ->
        {:needs_ask, %{name: name, args: args, caps: caps, lint: lint, high_risk?: high_risk?}}
    end
  end

  @doc """
  Resolve an asker's choice for the pending call.

  Returns `{decision, lease_to_store}`; `lease_to_store` is `nil` unless the
  asker chose `{:lease, ttl_ms}` and the call was leaseable.
  """
  @spec resolve(Clearance.Asker.choice(), map(), integer()) ::
          {{:allow, Grant.t()} | {:deny, String.t()}, Grant.t() | nil}
  def resolve(:once, active, _now_ms) do
    grant =
      Grant.new(
        capabilities: active.caps,
        tools: [active.name],
        network?: if(active.network_requested?, do: true, else: nil),
        source: :once,
        reason: "approved once by user"
      )

    {{:allow, grant}, nil}
  end

  def resolve({:lease, ttl_ms}, active, now_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
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

      grant =
        Grant.new(
          capabilities: active.caps,
          expires_at: lease.expires_at,
          source: :lease,
          reason: lease.reason
        )

      {{:allow, grant}, lease}
    else
      {{:deny, "standing leases are not permitted for high-risk or #{active.name} calls"}, nil}
    end
  end

  def resolve({:allow, %Grant{} = custom}, active, now_ms) do
    if Grant.allows?(custom, active.name, active.caps, now_ms) do
      {{:allow, custom}, nil}
    else
      {{:deny, "custom grant does not cover #{active.name}"}, nil}
    end
  end

  def resolve(_other, _active, _now_ms), do: {{:deny, "denied by user"}, nil}

  ## Internals

  defp lint(%{lint: fun, lint_tools: tools} = policy, name, args)
       when is_function(fun, 2) and is_list(tools) do
    if name in tools do
      fun.(args, protected_dirs: Map.get(policy, :protected_dirs, []))
    else
      ok_lint()
    end
  end

  defp lint(_policy, _name, _args), do: ok_lint()

  defp ok_lint, do: %{verdict: :ok, risk: :low, reasons: []}

  defp high_risk?(policy, lint, caps, name, args) do
    lint.verdict == :ask or
      Enum.any?(Map.get(policy, :approval_caps, [:unknown, :mcp]), fn cap -> cap in caps end) or
      force_ask?(policy, name, args, caps)
  end

  defp force_ask?(%{force_ask?: fun}, name, args, caps) when is_function(fun, 3) do
    fun.(name, args, caps) not in [nil, false]
  end

  defp force_ask?(_policy, _name, _args, _caps), do: false

  defp auto_allowed?(caps, policy) when is_list(caps) do
    allow = MapSet.new(Map.get(policy, :auto_allow, []))
    :unknown not in caps and MapSet.subset?(MapSet.new(caps), allow)
  end

  defp matching_lease(leases, name, caps, now_ms) when is_list(leases) do
    Enum.find(leases, &Grant.allows?(&1, name, caps, now_ms))
  end

  defp matching_lease(_leases, _name, _caps, _now_ms), do: nil

  defp no_asker_reason(name, caps, lint) do
    case lint.reasons do
      [] -> "tool #{name} (#{inspect(caps)}) requires approval (non-interactive policy)"
      reasons -> "tool #{name} requires approval: #{Enum.join(reasons, "; ")}"
    end
  end
end
