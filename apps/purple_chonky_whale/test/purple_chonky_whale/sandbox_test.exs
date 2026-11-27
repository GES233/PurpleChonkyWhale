defmodule PurpleChonkyWhale.SandboxTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Dexterous.Context
  alias PurpleChonkyWhale.{MCP, Sandbox, Tools}
  alias PurpleChonkyWhale.Executor.Runner
  alias PurpleChonkyWhale.Sandbox.{Docker, Host, Profile}
  alias PurpleChonkyWhale.Security.Grant

  @moduletag :tmp_dir

  defmodule RecordingBackend do
    @moduledoc false
    @behaviour PurpleChonkyWhale.Sandbox.Backend

    @impl true
    def available?(opts) do
      case Keyword.get(opts, :error) do
        nil -> :ok
        reason -> {:error, reason}
      end
    end

    @impl true
    def wrap_plan(plan, ctx, profile, opts) do
      if pid = Keyword.get(opts, :test_pid) do
        send(pid, {:wrapped_plan, plan, ctx, profile})
      end

      case Keyword.get(opts, :wrap_error) do
        nil -> {:ok, plan}
        reason -> {:error, reason}
      end
    end

    @impl true
    def wrap_stdio(stdio_opts, profile, opts) do
      if pid = Keyword.get(opts, :test_pid) do
        send(pid, {:wrapped_stdio, stdio_opts, profile})
      end

      case Keyword.get(opts, :wrap_error) do
        nil ->
          {:ok,
           Keyword.put(stdio_opts, :args, ["--sandboxed" | Keyword.get(stdio_opts, :args, [])])}

        reason ->
          {:error, reason}
      end
    end
  end

  defmodule FakeMcpBackend do
    @moduledoc false

    def child_spec(opts) do
      %{id: opts[:name], start: {__MODULE__, :start_client, [opts]}}
    end

    def start_client(opts) do
      if pid = Application.get_env(:purple_chonky_whale, __MODULE__) do
        send(pid, {:mcp_client_start, opts[:transport]})
      end

      Agent.start_link(fn -> :ok end, name: opts[:name])
    end

    def await_ready(_client, _opts), do: :ok

    def list_tools(_client, _opts) do
      {:ok, %Anubis.MCP.Response{result: %{"tools" => [%{"name" => "ping"}]}, id: "1"}}
    end

    def call_tool(_client, _name, _args, _opts) do
      {:ok, %Anubis.MCP.Response{result: %{"content" => [%{"type" => "text", "text" => "pong"}]}}}
    end
  end

  setup do
    previous = Application.get_env(:purple_chonky_whale, FakeMcpBackend)

    on_exit(fn ->
      if previous do
        Application.put_env(:purple_chonky_whale, FakeMcpBackend, previous)
      else
        Application.delete_env(:purple_chonky_whale, FakeMcpBackend)
      end
    end)

    :ok
  end

  describe "Profile" do
    test "merge_env_and_grant narrows roots and resolves :on_grant network ceiling", %{
      tmp_dir: dir
    } do
      a = Path.join(dir, "a")
      b = Path.join(dir, "b")

      profile =
        Profile.new(
          mode: :workspace_write,
          cwd: dir,
          writable_roots: [a, b],
          network?: :on_grant
        )

      # Without grant, :on_grant keeps network disabled
      merged_no_grant = Profile.merge_env_and_grant(profile, %{cwd: dir}, nil)
      refute Profile.network_allowed?(merged_no_grant)

      # With network? grant, :on_grant allows network and narrows writable_roots
      grant = Grant.new(capabilities: [:exec], network?: true, writable_roots: [b])
      merged = Profile.merge_env_and_grant(profile, %{cwd: dir, writable_roots: [a, b]}, grant)
      assert Profile.network_allowed?(merged)
      assert merged.writable_roots == [b]

      # When profile.network? is false, even a grant with network?: true cannot enable network
      strict = %{profile | network?: false}

      assert Profile.merge_env_and_grant(strict, %{}, grant) |> Profile.network_allowed?() ==
               false
    end
  end

  describe "Host & Docker backends" do
    test "Host wraps plans and stdio opts cleanly", %{tmp_dir: dir} do
      profile = Profile.new(cwd: dir)
      plan = %{exe: "echo", args: ["hi"], cwd: dir, script: nil}

      assert {:ok, ^plan} = Host.wrap_plan(plan, %{cwd: dir}, profile, [])

      assert {:error, _} =
               Host.wrap_plan(plan, %{cwd: Path.join(dir, "missing")}, profile, [])

      assert {:ok, wrapped_stdio} = Host.wrap_stdio([command: "uv", args: ["run"]], profile, [])
      assert wrapped_stdio[:cwd] == dir
      assert wrapped_stdio[:env] == %{}
    end

    test "Docker builds isolated read-only/network-none container args and rewrites script path",
         %{
           tmp_dir: dir
         } do
      run_dir = Path.join(dir, "pcw-run-1")
      script_path = Path.join(run_dir, "script.sh")
      opts = [image: "elixir:1.20-alpine", find_executable: fn "docker" -> "/usr/bin/docker" end]

      sandbox =
        Sandbox.from_config(
          backend: Docker,
          mode: :read_only,
          cwd: dir,
          network?: :on_grant,
          backend_opts: opts
        )

      plan = %{exe: "/bin/sh", args: ["-eu", script_path], cwd: dir, script: nil}

      assert {:ok, wrapped} =
               Sandbox.wrap_plan(sandbox, plan, %{cwd: dir, run_dir: run_dir}, %{})

      assert wrapped.exe == "/usr/bin/docker"
      assert wrapped.cwd == nil
      assert "--network=none" in wrapped.args
      assert "--cap-drop=ALL" in wrapped.args
      assert "--read-only" in wrapped.args
      assert "#{dir}:/workspace:ro" in wrapped.args
      assert "#{run_dir}:/pcw-run:rw" in wrapped.args
      assert "/pcw-run/script.sh" in wrapped.args
      assert "TEMP=/pcw-run/tmp" in wrapped.args
    end

    test "Docker fails closed when unavailable unless fail_open?: true", %{tmp_dir: dir} do
      opts = [image: "elixir:1.20-alpine", find_executable: fn _ -> nil end]
      plan = %{exe: "echo", args: ["ok"], cwd: dir, script: nil}

      closed =
        Sandbox.from_config(backend: Docker, cwd: dir, fail_open?: false, backend_opts: opts)

      assert {:error, msg} = Sandbox.wrap_plan(closed, plan, %{cwd: dir}, %{})
      assert msg =~ "unavailable"

      open = Sandbox.from_config(backend: Docker, cwd: dir, fail_open?: true, backend_opts: opts)
      assert {:ok, ^plan} = Sandbox.wrap_plan(open, plan, %{cwd: dir}, %{})
    end
  end

  describe "Executor.Runner & MCP integration" do
    test "Sandbox mounts as a Dexterous component and binds :sandbox" do
      scope = :"sandbox_comp_test_#{System.unique_integer([:positive])}"
      ctx = Context.new(scope)
      {:ok, _} = Context.use(ctx, Sandbox, mode: :workspace_write)

      sandbox =
        Enum.reduce_while(1..50, nil, fn _, _ ->
          case Context.get(ctx, :sandbox) do
            {:ok, val} -> {:halt, val}
            :error -> {:cont, Process.sleep(10)}
          end
        end)

      assert %Sandbox{backend: Host, profile: %Profile{mode: :workspace_write}} = sandbox
    end

    test "Runner enforces require_sandbox? and invokes Sandbox.wrap_plan with Grant", %{
      tmp_dir: dir
    } do
      plan = %{exe: "nonexistent", args: [], cwd: dir, script: nil}

      assert {:error, msg} =
               Runner.run(plan, %{
                 cwd: dir,
                 env: %{require_sandbox?: true},
                 timeout_ms: 1_000,
                 max_output_bytes: 1_000
               })

      assert msg =~ "sandbox required"

      sandbox =
        Sandbox.from_config(
          backend: RecordingBackend,
          cwd: dir,
          network?: :on_grant,
          backend_opts: [test_pid: self(), wrap_error: "blocked by recording backend"]
        )

      grant = Grant.new(capabilities: [:exec], network?: true)

      assert {:error, "blocked by recording backend"} =
               Runner.run(plan, %{
                 cwd: dir,
                 env: %{sandbox: sandbox, grant: grant},
                 timeout_ms: 1_000,
                 max_output_bytes: 1_000
               })

      assert_received {:wrapped_plan, _plan, %{run_dir: run_dir}, profile}
      assert Profile.network_allowed?(profile)
      # Temp directory was cleaned up even when wrap_plan returned an error
      refute File.exists?(run_dir)
    end

    test "MCP wraps stdio servers via Sandbox and drops them when sandbox fails closed", %{
      tmp_dir: dir
    } do
      Application.put_env(:purple_chonky_whale, FakeMcpBackend, self())

      sandbox =
        Sandbox.from_config(
          backend: RecordingBackend,
          cwd: dir,
          backend_opts: [test_pid: self()]
        )

      {:ok, mcp} =
        MCP.start_link(
          [%{name: :srv, transport: {:stdio, command: "fake_mcp", args: ["serve"]}}],
          backend: FakeMcpBackend,
          sandbox: sandbox
        )

      assert_received {:wrapped_stdio, _raw_opts, %Profile{cwd: ^dir}}
      assert_received {:mcp_client_start, {:stdio, wrapped_opts}}
      assert wrapped_opts[:args] == ["--sandboxed", "serve"]
      assert Map.has_key?(mcp.catalog, "mcp_srv_ping")
      stop_mcp(mcp)

      # Fail-closed when stdio server lacks required sandbox
      {{:ok, mcp_dropped}, log} =
        with_log(fn ->
          MCP.start_link(
            [%{name: :blocked, transport: {:stdio, command: "fake_mcp", args: []}}],
            backend: FakeMcpBackend,
            require_sandbox?: true
          )
        end)

      assert log =~ "requires a :sandbox"
      assert mcp_dropped.catalog == %{}
      stop_mcp(mcp_dropped)
    end

    test "Tools propagates :sandbox and :require_sandbox? into MCP and tool env", %{tmp_dir: dir} do
      scope = :"tools_sandbox_prop_#{System.unique_integer([:positive])}"
      ctx = Context.new(scope)

      {:ok, _} =
        Context.use(ctx, Tools,
          tools: [],
          require_sandbox?: true,
          sandbox: [backend: Host, cwd: dir],
          env: %{cwd: dir}
        )

      registry =
        Enum.reduce_while(1..50, nil, fn _, _ ->
          case Context.get(ctx, :tools) do
            {:ok, r} -> {:halt, r}
            :error -> {:cont, Process.sleep(10)}
          end
        end)

      assert %Sandbox{backend: Host} = registry.sandbox
      assert registry.require_sandbox? == true
    end
  end

  defp stop_mcp(%MCP{} = mcp) do
    if pid = Process.whereis(mcp.registry), do: GenServer.stop(pid, :normal, :infinity)
    if Process.alive?(mcp.sup), do: DynamicSupervisor.stop(mcp.sup)
  catch
    :exit, _ -> :ok
  end
end
