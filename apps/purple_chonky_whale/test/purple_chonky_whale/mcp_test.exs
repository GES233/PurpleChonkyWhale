defmodule PurpleChonkyWhale.MCPTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PurpleChonkyWhale.{MCP, Tools}
  alias Dexterous.Context

  # A fake for MCP's `:backend` (the `Anubis.Client` contract): the client
  # process is a plain Agent holding its server name, so the backend can
  # route per-server behaviour from the test's Application env.
  defmodule FakeBackend do
    @moduledoc false

    def child_spec(opts) do
      %{id: opts[:name], start: {__MODULE__, :start_client, [opts]}}
    end

    def start_client(opts) do
      case config_for(opts[:name]) do
        %{start_error: reason} ->
          {:error, reason}

        config ->
          if pid = config[:test_pid], do: send(pid, {:client_start, opts})
          Agent.start_link(fn -> server_name(opts[:name]) end, name: opts[:name])
      end
    end

    def await_ready(client, _opts) do
      case config_for(client) do
        %{ready_error: error} -> {:error, error}
        _ -> :ok
      end
    end

    def list_tools(client, _opts) do
      tools = config_for(client) |> Map.get(:tools, [])
      {:ok, %Anubis.MCP.Response{result: %{"tools" => tools}, id: "1"}}
    end

    def call_tool(client, name, args, _opts) do
      config = config_for(client)
      if pid = config[:test_pid], do: send(pid, {:mcp_call, name, args})
      config[:call].(name, args)
    end

    defp config_for({:via, Registry, {_registry, name}}), do: config_for(name)

    defp config_for(pid) when is_pid(pid), do: pid |> Agent.get(& &1) |> config_for()

    defp config_for(name) when is_atom(name) do
      :purple_chonky_whale
      |> Application.get_env(__MODULE__, %{})
      |> Map.get(name, %{})
    end

    defp server_name({:via, Registry, {_registry, name}}), do: name
  end

  defmodule Clash do
    @moduledoc false
    @behaviour PurpleChonkyWhale.Tool

    @impl true
    def schema do
      %{
        name: "mcp_srv_thing",
        description: "A static tool named like an MCP tool",
        parameters: %{"type" => "object"}
      }
    end

    @impl true
    def execute(_args, _env), do: {:ok, "static wins"}
  end

  setup do
    previous = Application.get_env(:purple_chonky_whale, FakeBackend)

    on_exit(fn ->
      if previous do
        Application.put_env(:purple_chonky_whale, FakeBackend, previous)
      else
        Application.delete_env(:purple_chonky_whale, FakeBackend)
      end
    end)

    :ok
  end

  test "sanitizes server and tool names into mcp_<server>_<tool>" do
    set_fake(%{
      :"my-server" => %{
        tools: [tool("foo.bar/baz qux")]
      }
    })

    mcp = start_mcp([server(:"my-server")])

    assert %{"mcp_my_server_foo_bar_baz_qux" => entry} = mcp.catalog
    assert entry.server == :"my-server"
    assert entry.tool == "foo.bar/baz qux"
    assert entry.timeout == 15_000
  end

  test "sanitizes CJK tool names, collapsing underscore runs" do
    set_fake(%{srv: %{tools: [tool("search_kimi_api_开放平台")]}})

    mcp = start_mcp([server(:srv)])

    assert %{"mcp_srv_search_kimi_api" => entry} = mcp.catalog
    assert entry.tool == "search_kimi_api_开放平台"
  end

  test "catalog schemas carry the [server] description prefix and the inputSchema" do
    schema = %{"type" => "object", "properties" => %{"x" => %{"type" => "integer"}}}
    set_fake(%{srv: %{tools: [tool("thing", "does a thing", schema)]}})

    mcp = start_mcp([server(:srv)])

    assert %{"mcp_srv_thing" => %{schema: schema_out}} = mcp.catalog
    assert schema_out.name == "mcp_srv_thing"
    assert schema_out.description == "[srv] does a thing"
    assert schema_out.parameters == schema
  end

  test "colliding sanitized names get a hash suffix and a warning" do
    set_fake(%{srv: %{tools: [tool("foo.bar"), tool("foo/bar")]}})

    {mcp, log} = with_log(fn -> start_mcp([server(:srv)]) end)

    assert log =~ "mcp_srv_foo_bar is taken"

    keys = mcp.catalog |> Map.keys() |> Enum.sort()
    assert ["mcp_srv_foo_bar", hashed] = keys
    assert hashed =~ ~r/^mcp_srv_foo_bar_[0-9a-f]{8}$/
  end

  test "a server that fails to start is dropped without affecting the others" do
    set_fake(%{
      good: %{tools: [tool("thing")]},
      bad: %{start_error: :enoent}
    })

    {mcp, log} = with_log(fn -> start_mcp([server(:bad), server(:good)]) end)

    assert log =~ "MCP server :bad is unavailable"
    assert Map.keys(mcp.catalog) == ["mcp_good_thing"]
    assert [] = Registry.lookup(mcp.registry, :bad)
  end

  test "a server that fails the handshake is dropped and its client stopped" do
    set_fake(%{
      bad: %{ready_error: %Anubis.MCP.Error{message: "handshake failed"}},
      good: %{tools: [tool("thing")]}
    })

    {mcp, log} = with_log(fn -> start_mcp([server(:bad), server(:good)]) end)

    assert log =~ "MCP server :bad is unavailable (handshake failed)"
    assert Map.keys(mcp.catalog) == ["mcp_good_thing"]
    assert [] = Registry.lookup(mcp.registry, :bad)
  end

  test "a streamable_http server gets a composition-scoped Finch pool injected" do
    set_fake(%{srv: %{tools: [tool("thing")], test_pid: self()}})

    mcp = start_mcp([http_server(:srv)])

    assert is_atom(mcp.finch)
    assert Process.whereis(mcp.finch)

    assert_received {:client_start, opts}
    assert {:streamable_http, transport_opts} = opts[:transport]
    assert transport_opts[:finch_name] == mcp.finch
  end

  test "a streamable_http transport naming its own :finch_name is used as given" do
    set_fake(%{srv: %{tools: [tool("thing")], test_pid: self()}})

    mcp = start_mcp([http_server(:srv, finch_name: ReqLLM.Finch)])

    assert mcp.finch == nil
    assert_received {:client_start, opts}
    assert {:streamable_http, transport_opts} = opts[:transport]
    assert transport_opts[:finch_name] == ReqLLM.Finch
  end

  test "stdio-only compositions start no Finch pool" do
    set_fake(%{srv: %{tools: [tool("thing")], test_pid: self()}})

    mcp = start_mcp([server(:srv)])

    assert mcp.finch == nil
    assert_received {:client_start, opts}
    assert {:stdio, _opts} = opts[:transport]
  end

  test "generated modules implement the Tool contract against the registry" do
    set_fake(%{
      srv: %{
        tools: [tool("thing", "does a thing")],
        test_pid: self(),
        call: fn "thing", %{"x" => 1} -> {:ok, text_response("hello")} end
      }
    })

    mcp = start_mcp([server(:srv)])
    modules = MCP.tool_modules(mcp, backend: FakeBackend)
    assert module = modules["mcp_srv_thing"]

    assert module.schema() == mcp.catalog["mcp_srv_thing"].schema

    assert {:ok, "hello"} = module.execute(%{"x" => 1}, %{})
    assert_received {:mcp_call, "thing", %{"x" => 1}}
  end

  test "call maps multi-part text content to one joined string" do
    set_fake(%{
      srv: %{
        tools: [tool("thing")],
        call: fn _, _ ->
          {:ok,
           %Anubis.MCP.Response{
             result: %{
               "content" => [
                 %{"type" => "text", "text" => "first"},
                 %{"type" => "text", "text" => "second"}
               ]
             }
           }}
        end
      }
    })

    mcp = start_mcp([server(:srv)])

    assert {:ok, "first\nsecond"} =
             MCP.call(mcp.registry, :srv, "thing", %{}, backend: FakeBackend)
  end

  test "call maps image content to {:parts, parts} with decoded binaries" do
    data = Base.encode64(<<1, 2, 3>>)

    set_fake(%{
      srv: %{
        tools: [tool("snap")],
        call: fn _, _ ->
          {:ok,
           %Anubis.MCP.Response{
             result: %{
               "content" => [
                 %{"type" => "text", "text" => "a screenshot"},
                 %{"type" => "image", "data" => data, "mimeType" => "image/png"}
               ]
             }
           }}
        end
      }
    })

    mcp = start_mcp([server(:srv)])

    assert {:ok, {:parts, parts}} =
             MCP.call(mcp.registry, :srv, "snap", %{}, backend: FakeBackend)

    assert [
             %{"type" => "text", "text" => "a screenshot"},
             %{"type" => "image", "data" => <<1, 2, 3>>, "mediaType" => "image/png"}
           ] = parts
  end

  test "call maps isError responses and protocol errors to {:error, _}, never raising" do
    set_fake(%{
      srv: %{
        tools: [tool("domain_error"), tool("protocol_error"), tool("kaput")],
        call: fn
          "domain_error", _ ->
            {:ok,
             %Anubis.MCP.Response{
               result: %{
                 "content" => [%{"type" => "text", "text" => "it broke"}],
                 "isError" => true
               },
               is_error: true
             }}

          "protocol_error", _ ->
            {:error, %Anubis.MCP.Error{message: "method not found"}}

          "kaput", _ ->
            raise "kaput"
        end
      }
    })

    mcp = start_mcp([server(:srv)])

    assert {:error, %{type: :mcp, message: "it broke"}} =
             MCP.call(mcp.registry, :srv, "domain_error", %{}, backend: FakeBackend)

    assert {:error, %{type: :mcp, message: "MCP call failed: method not found"}} =
             MCP.call(mcp.registry, :srv, "protocol_error", %{}, backend: FakeBackend)

    assert {:error, %{type: :mcp, message: "MCP call exited: kaput"}} =
             MCP.call(mcp.registry, :srv, "kaput", %{}, backend: FakeBackend)
  end

  test "call against a disconnected server is a typed error, not an exit" do
    mcp = start_mcp([])

    assert {:error, %{type: :mcp, message: message}} =
             MCP.call(mcp.registry, :ghost, "thing", %{}, backend: FakeBackend)

    assert message =~ "not connected"
  end

  test "Tools registers mcp_* tools and runs them through the pipeline" do
    test_pid = self()

    set_fake(%{
      srv: %{
        tools: [tool("thing", "does a thing")],
        test_pid: test_pid,
        call: fn "thing", %{"x" => 1} -> {:ok, text_response("ok!")} end
      }
    })

    scope = :"mcp_tools_test_#{System.unique_integer([:positive])}"
    ctx = Context.new(scope)

    {:ok, _fiber} =
      Context.use(ctx, Tools,
        tools: [],
        env: %{cwd: "/tmp/work"},
        mcp_servers: [server(:srv)],
        mcp_backend: FakeBackend
      )

    registry =
      eventually(fn ->
        case Context.get(ctx, :tools) do
          {:ok, registry} -> registry
          :error -> nil
        end
      end)

    assert %Tools{mcp: %MCP{} = mcp} = registry
    assert {:ok, module} = Tools.lookup(registry, "mcp_srv_thing")
    assert module.schema().description == "[srv] does a thing"

    {:ok, _} =
      Context.on(ctx, :"tools/pre-execute", fn call, next ->
        send(test_pid, {:pre, call.name})
        next.(call)
      end)

    {:ok, _} =
      Context.on(ctx, :"tools/post-execute", fn event -> send(test_pid, {:post, event}) end)

    assert {:ok, "ok!"} = Tools.execute(registry, "mcp_srv_thing", %{"x" => 1})

    assert_received {:pre, "mcp_srv_thing"}
    assert_received {:mcp_call, "thing", %{"x" => 1}}
    assert_received {:post, %{name: "mcp_srv_thing", result: {:ok, "ok!"}}}

    stop_mcp(mcp)
  end

  test "a static tool wins a name collision with an MCP tool (with a warning)" do
    set_fake(%{
      srv: %{
        tools: [tool("thing")],
        call: fn _, _ -> {:ok, text_response("mcp")} end
      }
    })

    scope = :"mcp_tools_clash_test_#{System.unique_integer([:positive])}"
    ctx = Context.new(scope)

    {registry, log} =
      with_log(fn ->
        {:ok, _fiber} =
          Context.use(ctx, Tools,
            tools: [Clash],
            mcp_servers: [server(:srv)],
            mcp_backend: FakeBackend
          )

        eventually(fn ->
          case Context.get(ctx, :tools) do
            {:ok, registry} -> registry
            :error -> nil
          end
        end)
      end)

    assert log =~ "colliding with static tools"
    assert {:ok, Clash} = Tools.lookup(registry, "mcp_srv_thing")
    assert {:ok, "static wins"} = Tools.execute(registry, "mcp_srv_thing", %{})

    stop_mcp(registry.mcp)
  end

  ## Helpers

  defp set_fake(config), do: Application.put_env(:purple_chonky_whale, FakeBackend, config)

  defp server(name), do: %{name: name, transport: {:stdio, command: "fake", args: []}}

  defp http_server(name, extra \\ []) do
    %{
      name: name,
      transport: {:streamable_http, [base_url: "http://127.0.0.1:9", mcp_path: "/mcp"] ++ extra}
    }
  end

  defp tool(name, description \\ "a tool", input_schema \\ %{"type" => "object"}) do
    %{"name" => name, "description" => description, "inputSchema" => input_schema}
  end

  defp text_response(text) do
    %Anubis.MCP.Response{result: %{"content" => [%{"type" => "text", "text" => text}]}}
  end

  defp start_mcp(servers) do
    {:ok, mcp} = MCP.start_link(servers, backend: FakeBackend)

    on_exit(fn -> stop_mcp(mcp) end)

    mcp
  end

  defp stop_mcp(%MCP{} = mcp) do
    if pid = Process.whereis(mcp.registry), do: GenServer.stop(pid, :normal, :infinity)
    if Process.alive?(mcp.sup), do: DynamicSupervisor.stop(mcp.sup)
  catch
    :exit, _ -> :ok
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
