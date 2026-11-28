defmodule Clearance.PolicyTest do
  use ExUnit.Case, async: true

  alias Clearance.Policy
  alias PurpleChonkyWhale.Security.Grant

  defp start(opts), do: start_supervised!({Policy, opts})

  defp write_call,
    do: %{name: "write", arguments: %{"file_path" => "a.txt"}, capabilities: [:fs_write]}

  test "auto-allowed capabilities never reach the asker" do
    test_pid = self()

    policy =
      start(
        auto_allow: [:fs_read],
        asker: fn _request ->
          send(test_pid, :asked)
          :deny
        end
      )

    assert {:allow, %Grant{source: :policy}} =
             Policy.check(policy, %{name: "read", capabilities: [:fs_read]})

    refute_received :asked
  end

  test "a one-shot approval allows the call and stores no lease" do
    policy = start(asker: fn _request -> :once end)

    assert {:allow, %Grant{source: :once}} = Policy.check(policy, write_call())
    assert Policy.leases(policy) == []
  end

  test "a lease answer stores a lease that the next call reuses without asking" do
    {:ok, answers} = Agent.start_link(fn -> [{:lease, 30_000}, :deny] end)

    asker = fn _request -> Agent.get_and_update(answers, fn [head | tail] -> {head, tail} end) end
    policy = start(asker: asker)

    assert {:allow, %Grant{source: :lease}} = Policy.check(policy, write_call())
    assert [%Grant{}] = Policy.leases(policy)

    # If this asked again the agent would answer :deny and the assertion would fail.
    assert {:allow, %Grant{source: :lease}} = Policy.check(policy, write_call())
  end

  test "programmatic leases can be granted and revoked" do
    policy = start(asker: fn _request -> :deny end)

    assert {:ok, %Grant{} = lease} = Policy.grant_lease(policy, [:fs_write], ttl_ms: 60_000)
    assert [^lease] = Policy.leases(policy)

    assert {:allow, _} = Policy.check(policy, write_call())

    assert :ok = Policy.revoke_all(policy)
    assert Policy.leases(policy) == []
    assert {:deny, "denied by user"} = Policy.check(policy, write_call())
  end

  test "no asker means non-interactive fail-closed" do
    policy = start([])

    assert {:deny, reason} = Policy.check(policy, write_call())
    assert reason =~ "requires approval (non-interactive policy)"
  end

  test "a crashing asker fails closed instead of taking the policy down" do
    policy = start(asker: fn _request -> raise "prompt exploded" end)

    assert {:deny, "denied by user"} = Policy.check(policy, write_call())
    assert Process.alive?(policy)
  end

  test "the asker receives the request map built for it" do
    test_pid = self()

    policy =
      start(
        asker: fn request ->
          send(test_pid, {:request, request})
          :deny
        end
      )

    assert {:deny, _} = Policy.check(policy, write_call())
    assert_received {:request, request}
    assert request.tool == "write"
    assert request.leaseable_capabilities == [:fs_write]
    refute request.high_risk?
    assert request.summary =~ "write"
  end
end
