defmodule Clearance.EvaluateTest do
  use ExUnit.Case, async: true

  alias Clearance.Evaluate
  alias PurpleChonkyWhale.Security.Grant

  @now 10_000

  defp policy(overrides \\ []) do
    Map.merge(
      %{
        leases: [],
        auto_allow: [:fs_read],
        asker: nil,
        lint: nil,
        lint_tools: [],
        force_ask?: fn _, _, _ -> false end,
        approval_caps: [:unknown, :mcp],
        protected_dirs: []
      },
      Map.new(overrides)
    )
  end

  defp call(name, caps, args \\ %{}) do
    %{name: name, arguments: args, capabilities: caps}
  end

  defp ask_once, do: fn _request -> :once end

  describe "the ladder" do
    test "auto-allows a capability in the allow list without an asker" do
      assert {:allow, %Grant{source: :policy, reason: "auto-allowed capability"}} =
               Evaluate.run(call("read", [:fs_read]), policy(), @now)
    end

    test "denies a non-allowed capability when there is no asker" do
      assert {:deny, reason} = Evaluate.run(call("write", [:fs_write]), policy(), @now)
      assert reason =~ "requires approval (non-interactive policy)"
    end

    test "asks when an asker exists" do
      assert {:needs_ask, ctx} =
               Evaluate.run(call("write", [:fs_write]), policy(asker: ask_once()), @now)

      assert ctx.name == "write"
      assert ctx.caps == [:fs_write]
      refute ctx.high_risk?
    end

    test "unknown and mcp capabilities are high risk even with an asker" do
      assert {:needs_ask, %{high_risk?: true}} =
               Evaluate.run(call("mcp_srv_do", [:mcp]), policy(asker: ask_once()), @now)

      assert {:needs_ask, %{high_risk?: true}} =
               Evaluate.run(call("undeclared", [:unknown]), policy(asker: ask_once()), @now)
    end

    test "a deny lint verdict is final: no ask, no lease, no override" do
      lint = fn _args, _opts -> %{verdict: :deny, risk: :high, reasons: ["wipe"]} end

      policy =
        policy(
          asker: ask_once(),
          lint: lint,
          lint_tools: ["execute"],
          leases: [
            Grant.new(capabilities: [:exec], expires_at: @now + 60_000, source: :lease)
          ]
        )

      assert {:deny, "blocked by shell lint: wipe"} =
               Evaluate.run(call("execute", [:exec], %{"code" => "rm -rf /"}), policy, @now)
    end

    test "an ask lint verdict forces approval even for an auto-allowed capability" do
      lint = fn _args, _opts -> %{verdict: :ask, risk: :high, reasons: ["network"]} end

      policy = policy(asker: ask_once(), lint: lint, lint_tools: ["execute"])

      assert {:needs_ask, %{high_risk?: true}} =
               Evaluate.run(call("execute", [:fs_read], %{"code" => "curl x"}), policy, @now)
    end

    test "force_ask? escalates without touching capabilities" do
      policy =
        policy(asker: ask_once(), force_ask?: fn name, _args, _caps -> name == "execute" end)

      assert {:needs_ask, %{high_risk?: true}} =
               Evaluate.run(call("execute", [:exec]), policy, @now)
    end

    test "an unexpired lease allows without asking" do
      lease =
        Grant.new(capabilities: [:fs_write], expires_at: @now + 60_000, source: :lease)

      assert {:allow, %Grant{source: :lease, expires_at: expires_at}} =
               Evaluate.run(call("write", [:fs_write]), policy(leases: [lease]), @now)

      assert expires_at == @now + 60_000
    end

    test "an expired lease does not authorize" do
      lease = Grant.new(capabilities: [:fs_write], expires_at: @now - 1, source: :lease)

      assert {:deny, _reason} =
               Evaluate.run(call("write", [:fs_write]), policy(leases: [lease]), @now)
    end

    test "high-risk calls ignore a matching lease" do
      lint = fn _args, _opts -> %{verdict: :ask, risk: :high, reasons: ["network"]} end

      policy =
        policy(
          asker: ask_once(),
          lint: lint,
          lint_tools: ["execute"],
          leases: [Grant.new(capabilities: [:exec], expires_at: @now + 60_000)]
        )

      assert {:needs_ask, %{high_risk?: true}} =
               Evaluate.run(call("execute", [:exec], %{"code" => "curl x"}), policy, @now)
    end
  end

  describe "resolve/3" do
    defp active(overrides \\ []) do
      Map.merge(
        %{
          name: "write",
          caps: [:fs_write],
          high_risk?: false,
          network_requested?: false,
          leaseable: [:fs_write]
        },
        Map.new(overrides)
      )
    end

    test ":once grants exactly one call and carries network when requested" do
      assert {{:allow, %Grant{source: :once, network?: true} = grant}, nil} =
               Evaluate.resolve(:once, active(network_requested?: true), @now)

      assert MapSet.member?(grant.tools, "write")
    end

    test "{:lease, ttl} returns the lease to store and a scoped grant" do
      assert {{:allow, %Grant{source: :lease} = grant}, %Grant{} = lease} =
               Evaluate.resolve({:lease, 30_000}, active(), @now)

      assert lease.expires_at == @now + 30_000
      assert grant.expires_at == lease.expires_at
    end

    test "high-risk calls cannot create a standing lease" do
      assert {{:deny, reason}, nil} =
               Evaluate.resolve({:lease, 30_000}, active(high_risk?: true, leaseable: []), @now)

      assert reason =~ "standing leases are not permitted"
    end

    test "a custom grant is honoured only when it covers the call" do
      covering = Grant.new(capabilities: [:fs_write], tools: ["write"], source: :once)
      assert {{:allow, ^covering}, nil} = Evaluate.resolve({:allow, covering}, active(), @now)

      narrow = Grant.new(capabilities: [:fs_read], tools: ["write"])
      assert {{:deny, reason}, nil} = Evaluate.resolve({:allow, narrow}, active(), @now)
      assert reason =~ "custom grant does not cover"
    end

    test "anything else is a denial" do
      assert {{:deny, "denied by user"}, nil} = Evaluate.resolve(:deny, active(), @now)
      assert {{:deny, "denied by user"}, nil} = Evaluate.resolve(:nonsense, active(), @now)
    end
  end
end
