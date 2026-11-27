defmodule PurpleChonkyWhale.Security.GrantTest do
  use ExUnit.Case, async: true

  alias PurpleChonkyWhale.Security.Grant

  test "allows? checks capabilities, tool scope, and monotonic expiry" do
    now = 1_000
    grant = Grant.new([capabilities: [:fs_read, :fs_write], tools: ["read", "write"], ttl_ms: 500], now)

    assert Grant.allows?(grant, "read", [:fs_read], 1_200)
    assert Grant.allows?(grant, "write", [:fs_write], 1_499)
    refute Grant.allows?(grant, "edit", [:fs_write], 1_200)
    refute Grant.allows?(grant, "read", [:exec], 1_200)
    refute Grant.allows?(grant, "read", [:unknown], 1_200)
    refute Grant.allows?(grant, "read", [:fs_read], 1_500)
    assert Grant.expired?(grant, 1_500)
    assert Grant.remaining_ms(grant, 1_200) == 300
  end

  test "narrow/2 monotonically intersects capabilities, tools, roots, runtimes, and deadlines" do
    a =
      Grant.new(
        [
          capabilities: [:fs_read, :fs_write, :exec],
          tools: :any,
          writable_roots: ["/a", "/b"],
          allowed_runtimes: ["shell", "python"],
          ttl_ms: 10_000,
          reason: "policy"
        ],
        1_000
      )

    b =
      Grant.new(
        [
          capabilities: [:fs_write, :exec],
          tools: ["write"],
          writable_roots: ["/b", "/c"],
          allowed_runtimes: ["shell"],
          ttl_ms: 2_000,
          reason: "narrower"
        ],
        1_000
      )

    narrowed = Grant.narrow(a, b)

    assert narrowed.capabilities == MapSet.new([:fs_write, :exec])
    assert narrowed.tools == MapSet.new(["write"])
    assert narrowed.writable_roots == ["/b"]
    assert narrowed.allowed_runtimes == ["shell"]
    assert narrowed.expires_at == 3_000
    assert narrowed.reason == "policy; narrower"
  end

  test "apply_to_env/2 can only narrow env permissions, never widen them" do
    grant =
      Grant.new(
        capabilities: [:exec, :fs_write],
        allowed_runtimes: ["shell", "elixir"],
        writable_roots: ["/allowed", "/extra"]
      )

    env = %{
      cwd: "/work",
      allowed_runtimes: ["shell", "python"],
      writable_roots: ["/allowed"]
    }

    gated = Grant.apply_to_env(grant, env)

    # "elixir" was not in env[:allowed_runtimes], so grant cannot introduce it.
    assert gated.allowed_runtimes == ["shell"]
    # "/extra" was not in env[:writable_roots], so grant cannot introduce it.
    assert gated.writable_roots == ["/allowed"]
    assert gated.grant == grant
  end
end
