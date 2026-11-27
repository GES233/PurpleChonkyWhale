defmodule Noctilucent.PolicyTest do
  use ExUnit.Case, async: false

  alias Noctilucent.Policy
  alias PurpleChonkyWhale.{Tool, Tools}
  alias PurpleChonkyWhale.Tools.{Executor, Read, Write}
  alias Dexterous.Context

  @moduletag :tmp_dir

  defmodule UndeclaredTool do
    @moduledoc false
    @behaviour Tool

    @impl true
    def schema do
      %{name: "undeclared", description: "No capabilities/0", parameters: %{"type" => "object"}}
    end

    @impl true
    def execute(_args, _env), do: {:ok, "ran"}
  end

  defmodule FakeMcpTool do
    @moduledoc false
    @behaviour Tool

    @impl true
    def capabilities, do: [:mcp]

    @impl true
    def schema do
      %{name: "mcp_srv_do", description: "MCP", parameters: %{"type" => "object"}}
    end

    @impl true
    def execute(_args, _env), do: {:ok, "mcp-ran"}
  end

  defp mount_stack(dir, policy_opts) do
    scope = :"policy_test_#{System.unique_integer([:positive])}"
    ctx = Context.new(scope)

    {:ok, _} =
      Context.use(ctx, Tools,
        tools: [Read, Write, Executor, UndeclaredTool, FakeMcpTool],
        require_grant?: true,
        env: %{cwd: dir, protected_dirs: [Path.join(dir, ".protected")]}
      )

    {:ok, _} =
      Context.use(ctx, Policy, Keyword.merge([cwd: dir], policy_opts))

    tools = await_binding(ctx, :tools)
    policy = await_binding(ctx, :policy)
    {ctx, tools, policy}
  end

  test "auto-allows fs_read while failing closed on fs_write/exec/unknown/mcp without ask", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "hello.txt"), "hi")
    {_ctx, tools, _policy} = mount_stack(dir, [])

    assert {:ok, "1\thi"} = Tools.execute(tools, "read", %{"file_path" => "hello.txt"})

    assert {:error, %{type: :denied}} =
             Tools.execute(tools, "write", %{"file_path" => "out.txt", "content" => "no"})

    assert {:error, %{type: :denied}} =
             Tools.execute(tools, "execute", %{"code" => "echo hi"})

    assert {:error, %{type: :denied}} = Tools.execute(tools, "undeclared", %{})
    assert {:error, %{type: :denied}} = Tools.execute(tools, "mcp_srv_do", %{})
  end

  test "one-shot approval and TTL lease flow with deterministic ask agent", %{tmp_dir: dir} do
    {:ok, answers} = Agent.start_link(fn -> [:once, {:lease, 30_000}] end)
    test_pid = self()

    ask = fn req ->
      send(test_pid, {:asked, req.tool, req.high_risk?, req.leaseable_capabilities})
      Agent.get_and_update(answers, fn [h | t] -> {h, t} end)
    end

    {_ctx, tools, policy} = mount_stack(dir, ask: ask)

    # 1. One-shot approval
    assert {:ok, _} = Tools.execute(tools, "write", %{"file_path" => "a.txt", "content" => "A"})
    assert_received {:asked, "write", false, [:fs_write]}
    assert Policy.leases(policy) == []

    # 2. Second write prompts again -> user grants 30s lease
    assert {:ok, _} = Tools.execute(tools, "write", %{"file_path" => "b.txt", "content" => "B"})
    assert_received {:asked, "write", false, [:fs_write]}
    assert [%PurpleChonkyWhale.Security.Grant{}] = Policy.leases(policy)

    # 3. Third write uses the active lease without prompting
    assert {:ok, _} = Tools.execute(tools, "write", %{"file_path" => "c.txt", "content" => "C"})
    refute_received {:asked, _, _, _}

    # 4. Revoking leases causes next write to prompt again
    :ok = Policy.revoke_all(policy)
    assert Policy.leases(policy) == []

    Agent.update(answers, fn _ -> [:deny] end)

    assert {:error, %{type: :denied, message: "denied by user"}} =
             Tools.execute(tools, "write", %{"file_path" => "d.txt", "content" => "D"})

    assert_received {:asked, "write", false, [:fs_write]}
  end

  test "expired leases do not authorize calls", %{tmp_dir: dir} do
    {_ctx, tools, policy} = mount_stack(dir, [])

    {:ok, _} = Policy.grant_lease(policy, [:fs_write], ttl_ms: 20)
    assert {:ok, _} = Tools.execute(tools, "write", %{"file_path" => "a.txt", "content" => "A"})

    Process.sleep(40)

    assert {:error, %{type: :denied}} =
             Tools.execute(tools, "write", %{"file_path" => "b.txt", "content" => "B"})
  end

  test "ShellLint hard-deny never calls ask and cannot be bypassed by an :exec lease", %{
    tmp_dir: dir
  } do
    test_pid = self()

    ask = fn req ->
      send(test_pid, {:asked, req.tool})
      :once
    end

    {_ctx, tools, policy} = mount_stack(dir, ask: ask)
    {:ok, _} = Policy.grant_lease(policy, [:exec], ttl_ms: 60_000)

    assert {:error, %{type: :denied, message: msg}} =
             Tools.execute(tools, "execute", %{
               "runtime" => "powershell",
               "code" => "$home = 'C:/Temp/x'\nRemove-Item -Recurse -Force $home"
             })

    assert msg =~ "blocked by shell lint"
    refute_received {:asked, _}
  end

  test "high-risk execute, :mcp, and :unknown bypass standing leases and cannot create leases",
       %{tmp_dir: dir} do
    test_pid = self()

    ask = fn req ->
      send(test_pid, {:asked, req.tool, req.high_risk?, req.leaseable_capabilities})
      # Attempt to return {:lease, ...} even for high-risk / unknown / mcp
      {:lease, 60_000}
    end

    {_ctx, tools, policy} = mount_stack(dir, ask: ask)
    {:ok, _} = Policy.grant_lease(policy, [:exec], ttl_ms: 60_000)

    # Even with an :exec lease, `git reset --hard` still asks and refuses lease creation
    assert {:error, %{type: :denied, message: msg}} =
             Tools.execute(tools, "execute", %{"code" => "git reset --hard"})

    assert msg =~ "standing leases are not permitted"
    assert_received {:asked, "execute", true, []}

    assert {:error, %{type: :denied}} = Tools.execute(tools, "mcp_srv_do", %{})
    assert_received {:asked, "mcp_srv_do", true, []}

    assert {:error, %{type: :denied}} = Tools.execute(tools, "undeclared", %{})
    assert_received {:asked, "undeclared", true, []}

    # Only the pre-seeded :exec lease exists; none were added for high-risk/mcp/unknown
    assert length(Policy.leases(policy)) == 1
  end

  test "concurrent tool batch serializes prompts and later queued calls reuse granted lease", %{
    tmp_dir: dir
  } do
    test_pid = self()
    ask_count = :atomics.new(1, [])

    ask = fn req ->
      n = :atomics.add_get(ask_count, 1, 1)
      send(test_pid, {:asked, n, req.tool})
      Process.sleep(30)
      {:lease, 60_000}
    end

    {_ctx, tools, _policy} = mount_stack(dir, ask: ask)

    results =
      ["1.txt", "2.txt", "3.txt"]
      |> Task.async_stream(
        fn name ->
          Tools.execute(tools, "write", %{"file_path" => name, "content" => name})
        end,
        max_concurrency: 3
      )
      |> Enum.map(fn {:ok, res} -> res end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    # Only the first call prompted; calls 2 and 3 saw the newly granted lease on dequeue.
    assert :atomics.get(ask_count, 1) == 1
    assert_received {:asked, 1, "write"}
    refute_received {:asked, 2, _}
  end

  test "crashed ask callback fails closed to :denied", %{tmp_dir: dir} do
    {_ctx, tools, _policy} = mount_stack(dir, ask: fn _req -> raise "prompt exploded" end)

    assert {:error, %{type: :denied}} =
             Tools.execute(tools, "write", %{"file_path" => "x.txt", "content" => "x"})
  end

  test "network-flagged execute approved :once sets network?: true on the one-shot Grant", %{
    tmp_dir: dir
  } do
    test_pid = self()

    ask = fn req ->
      send(test_pid, {:asked_net, req.network_requested?})
      :once
    end

    {ctx, _tools, policy} = mount_stack(dir, ask: ask)

    call = %{
      name: "execute",
      arguments: %{"code" => "curl https://example.com"},
      capabilities: [:exec]
    }

    assert {:allow, grant} = Policy.authorize(policy, call)
    assert_received {:asked_net, true}
    assert grant.network? == true

    _ = ctx
  end

  defp await_binding(ctx, key, attempts \\ 50)
  defp await_binding(_ctx, key, 0), do: raise("#{key} not bound")

  defp await_binding(ctx, key, attempts) do
    case Context.get(ctx, key) do
      {:ok, val} ->
        val

      :error ->
        Process.sleep(10)
        await_binding(ctx, key, attempts - 1)
    end
  end
end
