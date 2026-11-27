defmodule PurpleChonkyWhale.ToolsTest do
  use ExUnit.Case, async: false

  alias PurpleChonkyWhale.{Tool, Tools}
  alias PurpleChonkyWhale.Security.Grant
  alias PurpleChonkyWhale.Tools.{Edit, Executor, Glob, Grep, MemoryDelete, MemorySave, MemoryUpdate, Read, Recompile, Skill, TodoWrite, Write}
  alias Dexterous.Context

  defmodule Echo do
    @moduledoc false
    @behaviour PurpleChonkyWhale.Tool

    @impl true
    def schema do
      %{
        name: "echo",
        description: "Echoes the arguments and the environment",
        parameters: %{"type" => "object", "properties" => %{}}
      }
    end

    @impl true
    def execute(args, env) do
      send(self(), {:echo_executed, args})
      {:ok, %{"args" => args, "cwd" => env[:cwd]}}
    end
  end

  defmodule Crash do
    @moduledoc false
    @behaviour PurpleChonkyWhale.Tool

    @impl true
    def schema do
      %{name: "crash", description: "Always fails", parameters: %{"type" => "object"}}
    end

    @impl true
    def execute(_args, _env), do: raise("boom")
  end

  setup do
    scope = :"tools_test_#{System.unique_integer([:positive])}"
    ctx = Context.new(scope)

    {:ok, _fiber} =
      Context.use(ctx, Tools, tools: [Echo, Crash], env: %{cwd: "/tmp/work"})

    registry =
      eventually(fn ->
        case Context.get(ctx, :tools) do
          {:ok, registry} -> registry
          :error -> nil
        end
      end)

    {:ok, ctx: ctx, scope: scope, registry: registry}
  end

  test "provides the registry with the tool schemas", %{registry: registry} do
    assert ["crash", "echo"] = registry |> Tools.schemas() |> Enum.map(& &1.name)
    assert {:ok, Echo} = Tools.lookup(registry, "echo")
    assert :error = Tools.lookup(registry, "nope")
  end

  test "schemas are name-sorted even when the registry outgrows a flatmap" do
    # Past 32 entries an Erlang map stops being a flatmap, so `Map.values/1`
    # returns hash order and the model-facing tool list (the request prefix a
    # provider caches) would shuffle between calls. A composition that merges
    # MCP tools crosses that line easily, so the order must not depend on it.
    tools =
      for i <- 1..40, into: %{} do
        name = "toy_" <> String.pad_leading(Integer.to_string(i), 2, "0")
        module = Module.concat(__MODULE__, :"Toy#{i}")

        {:module, ^module, _, _} =
          Module.create(
            module,
            quote do
              def schema do
                %{
                  name: unquote(name),
                  description: "toy tool",
                  parameters: %{"type" => "object"}
                }
              end
            end,
            Macro.Env.location(__ENV__)
          )

        {name, module}
      end

    registry = %Tools{tools: tools, env: %{}, scope: :unused}

    names = registry |> Tools.schemas() |> Enum.map(& &1.name)

    assert length(names) == 40
    assert names == Enum.sort(names)
    assert names == Enum.sort(Map.keys(tools))
  end

  test "execute runs the tool with the env and emits post-execute", %{
    ctx: ctx,
    registry: registry
  } do
    test_pid = self()

    {:ok, _} =
      Context.on(ctx, :"tools/post-execute", fn event -> send(test_pid, {:post, event}) end)

    assert {:ok, %{"args" => %{"x" => 1}, "cwd" => "/tmp/work"}} =
             Tools.execute(registry, "echo", %{"x" => 1})

    assert_received {:echo_executed, %{"x" => 1}}
    assert_received {:post, %{name: "echo", result: {:ok, _}, duration_ms: ms}}
    assert is_integer(ms)
  end

  test "a pre-execute listener may rewrite the arguments", %{ctx: ctx, registry: registry} do
    {:ok, _} =
      Context.on(ctx, :"tools/pre-execute", fn call, next ->
        next.(%{call | arguments: Map.put(call.arguments, "injected", true)})
      end)

    assert {:ok, %{"args" => %{"x" => 1, "injected" => true}}} =
             Tools.execute(registry, "echo", %{"x" => 1})
  end

  test "a pre-execute listener may deny the call; the tool never runs", %{
    ctx: ctx,
    registry: registry
  } do
    {:ok, _} =
      Context.on(ctx, :"tools/pre-execute", fn call, _next ->
        %{call | decision: {:deny, "not allowed"}}
      end)

    assert {:error, %{type: :denied, message: "not allowed"}} =
             Tools.execute(registry, "echo", %{})

    refute_received {:echo_executed, _}
  end

  test "unknown tools and crashes are typed errors, not exceptions", %{registry: registry} do
    assert {:error, %{type: :unknown_tool}} = Tools.execute(registry, "nope", %{})
    assert {:error, %{type: :crashed, message: "boom"}} = Tools.execute(registry, "crash", %{})
  end

  test "Tool.capabilities/1 declares built-ins and defaults undeclared tools to [:unknown]" do
    assert Tool.capabilities(Read) == [:fs_read]
    assert Tool.capabilities(Glob) == [:fs_read]
    assert Tool.capabilities(Grep) == [:fs_read]
    assert Tool.capabilities(Skill) == [:fs_read]
    assert Tool.capabilities(Write) == [:fs_write]
    assert Tool.capabilities(Edit) == [:fs_write]
    assert Tool.capabilities(Executor) == [:exec]
    assert Tool.capabilities(Recompile) == [:hmr]
    assert Tool.capabilities(TodoWrite) == [:ui]
    assert Tool.capabilities(MemorySave) == [:memory]
    assert Tool.capabilities(MemoryUpdate) == [:memory]
    assert Tool.capabilities(MemoryDelete) == [:memory]
    assert Tool.capabilities(Echo) == [:unknown]
  end

  test "fail-closed monotonic gate catches listener crashes, garbage decisions, and un-denies", %{
    ctx: ctx,
    registry: registry
  } do
    # Listener 1 denies and passes downstream (misbehaving middleware)
    {:ok, d1} =
      Context.on(ctx, :"tools/pre-execute", fn call, next ->
        out = next.(%{call | decision: {:deny, "policy denied"}})
        # Try to un-deny on the way back out
        %{out | decision: :run}
      end)

    # Listener 2 tries to flip decision back to :run
    {:ok, d2} =
      Context.on(ctx, :"tools/pre-execute", fn call, next ->
        next.(%{call | decision: :run})
      end)

    assert {:error, %{type: :denied, message: "policy denied"}} =
             Tools.execute(registry, "echo", %{})

    refute_received {:echo_executed, _}
    d1.()
    d2.()

    # Crashing pre-execute listener fails closed to :denied
    {:ok, d3} =
      Context.on(ctx, :"tools/pre-execute", fn _call, _next -> raise "hook boom" end)

    assert {:error, %{type: :denied, message: msg}} = Tools.execute(registry, "echo", %{})
    assert msg =~ "pre-execute hook failed"
    refute_received {:echo_executed, _}
    d3.()

    # Invalid decision fails closed to :denied
    {:ok, d4} =
      Context.on(ctx, :"tools/pre-execute", fn call, next ->
        next.(%{call | decision: :allow_without_grant})
      end)

    assert {:error, %{type: :denied}} = Tools.execute(registry, "echo", %{})
    refute_received {:echo_executed, _}
    d4.()
  end

  test "require_grant?: true demands a matching Grant, narrows grants monotonically, and blocks escalation" do
    scope = :"tools_grant_gate_#{System.unique_integer([:positive])}"
    ctx = Context.new(scope)

    {:ok, _} =
      Context.use(ctx, Tools,
        tools: [Read, Write, Echo],
        require_grant?: true,
        env: %{cwd: System.tmp_dir!()}
      )

    registry =
      eventually(fn ->
        case Context.get(ctx, :tools) do
          {:ok, r} -> r
          :error -> nil
        end
      end)

    # No listener -> fails closed even if tool exists
    assert {:error, %{type: :denied}} = Tools.execute(registry, "echo", %{})

    # A listener returning :run cannot bypass require_grant?: true
    {:ok, d_run} =
      Context.on(ctx, :"tools/pre-execute", fn call, next ->
        next.(%{call | decision: :run})
      end)

    assert {:error, %{type: :denied}} = Tools.execute(registry, "echo", %{})
    d_run.()

    # Listener 1 grants [:fs_read, :fs_write]; Listener 2 narrows to [:fs_read] only
    {:ok, d_g1} =
      Context.on(ctx, :"tools/pre-execute", fn call, next ->
        grant = Grant.new(capabilities: [:fs_read, :fs_write])
        next.(%{call | decision: {:allow, grant}})
      end)

    {:ok, d_g2} =
      Context.on(ctx, :"tools/pre-execute", fn call, next ->
        grant = Grant.new(capabilities: [:fs_read])
        next.(%{call | decision: {:allow, grant}})
      end)

    assert {:error, %{type: :denied, message: msg}} =
             Tools.execute(registry, "write", %{"file_path" => "x.txt", "content" => "x"})

    assert msg =~ "missing required capabilities [:fs_write]"

    # Attempting to rewrite call.name from "read" to "write" is also blocked at gate exit
    {:ok, d_esc} =
      Context.on(ctx, :"tools/pre-execute", fn call, next ->
        next.(%{call | name: "write", arguments: %{"file_path" => "x.txt", "content" => "x"}})
      end)

    assert {:error, %{type: :denied}} =
             Tools.execute(registry, "read", %{"file_path" => "x.txt"})

    d_esc.()
    d_g2.()
    d_g1.()

    # Expired grant is rejected
    {:ok, d_exp} =
      Context.on(ctx, :"tools/pre-execute", fn call, next ->
        expired = Grant.new(capabilities: [:unknown], expires_at: System.monotonic_time(:millisecond) - 10)
        next.(%{call | decision: {:allow, expired}})
      end)

    assert {:error, %{type: :denied, message: exp_msg}} = Tools.execute(registry, "echo", %{})
    assert exp_msg =~ "expired"
    d_exp.()
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: nil

  defp eventually(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      other ->
        other
    end
  end
end
