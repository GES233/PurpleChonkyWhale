defmodule Clearance.Lint.Ast.Worker do
  @moduledoc """
  Lazy, persistent stdio Port worker for read-only external AST parsers
  (PowerShell `.NET Parser::ParseInput` and Python `ast.parse`).

  Cold-starting `pwsh` on every `execute` lint call costs hundreds of
  milliseconds; keeping a dedicated read-only parser Port alive drops warm
  parses to a few milliseconds while spawning **zero** OS processes until the
  first parse request arrives.

  Wire protocol (line-delimited over stdio):

    * Request:  `<base64(utf8_code)>\\n`
    * Response: `<single-line JSON>\\n`

  The helper script is strictly read-only: it parses code into AST metadata
  and never evaluates or executes user input. On any timeout, malformed JSON,
  or Port exit, the worker kills and discards the Port, returns `{:error, _}`
  (letting callers fail closed), and lazily respawns on the next request.
  """

  use GenServer

  @default_timeout_ms 5_000
  @default_startup_timeout_ms 10_000
  @line_buffer_bytes 1_048_576

  @type command_spec :: %{
          required(:exe) => String.t(),
          required(:args) => [String.t() | :script],
          optional(:script_name) => String.t(),
          optional(:script_content) => binary(),
          optional(:env) => [{charlist(), charlist() | false}]
        }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    id = Keyword.get(opts, :id, Keyword.get(opts, :name, __MODULE__))

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc "Start an AST parser worker. Options: `:name`, `:command_builder`, `:timeout_ms`, `:startup_timeout_ms`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    gen_opts =
      case Keyword.get(opts, :name) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Send `code` to `worker` for static AST extraction and decode its JSON reply."
  @spec parse(GenServer.server(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, String.t()}
  def parse(worker, code, timeout_ms \\ @default_startup_timeout_ms) when is_binary(code) do
    GenServer.call(worker, {:parse, code, timeout_ms}, timeout_ms + 2_000)
  catch
    :exit, {:timeout, _} -> {:error, "ast worker request timed out"}
    :exit, reason -> {:error, "ast worker unavailable: #{inspect(reason)}"}
  end

  ## GenServer

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       command_builder: Keyword.fetch!(opts, :command_builder),
       timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
       startup_timeout_ms: Keyword.get(opts, :startup_timeout_ms, @default_startup_timeout_ms),
       port: nil,
       os_pid: nil,
       script_dir: nil
     }}
  end

  @impl GenServer
  def handle_call({:parse, code, req_timeout}, _from, state) do
    cold_start? = is_nil(state.port)

    case ensure_port(state) do
      {:ok, state} ->
        effective_timeout =
          if cold_start? do
            max(req_timeout, state.startup_timeout_ms)
          else
            min(req_timeout, state.timeout_ms)
          end

        case exchange(state.port, code, effective_timeout) do
          {:ok, decoded} ->
            {:reply, {:ok, decoded}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, teardown(state)}
        end

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) do
    {:noreply, teardown(state)}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    {:noreply, teardown(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    teardown(state)
    :ok
  end

  ## Port lifecycle & line exchange

  defp ensure_port(%{port: port} = state) when is_port(port) do
    if Port.info(port) != nil do
      {:ok, state}
    else
      ensure_port(teardown(state))
    end
  end

  defp ensure_port(state) do
    with {:ok, spec} <- safe_build_command(state.command_builder),
         {:ok, exe, args, script_dir} <- materialize(spec),
         {:ok, port, os_pid} <- open_port(exe, args, Map.get(spec, :env, [])) do
      {:ok, %{state | port: port, os_pid: os_pid, script_dir: script_dir}}
    else
      {:error, reason, script_dir} ->
        cleanup_dir(script_dir)
        {:error, reason, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp safe_build_command(builder) do
    case builder.() do
      {:ok, spec} when is_map(spec) -> {:ok, spec}
      {:error, reason} -> {:error, to_string(reason)}
      other -> {:error, "invalid command spec: #{inspect(other)}"}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp materialize(spec) do
    case {Map.get(spec, :script_name), Map.get(spec, :script_content)} do
      {name, content} when is_binary(name) and is_binary(content) ->
        dir = Path.join(System.tmp_dir!(), "pcw-ast-#{System.unique_integer([:positive])}")
        path = Path.join(dir, name)

        with :ok <- File.mkdir_p(dir),
             :ok <- File.write(path, content) do
          args =
            Enum.map(spec.args, fn
              :script -> path
              arg -> arg
            end)

          {:ok, spec.exe, args, dir}
        else
          {:error, reason} ->
            {:error, "cannot write AST helper script: #{:file.format_error(reason)}", dir}
        end

      _ ->
        {:ok, spec.exe, spec.args, nil}
    end
  end

  defp open_port(exe, args, env_opts) do
    opts =
      [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        {:line, @line_buffer_bytes},
        args: Enum.map(args, &to_charlist/1)
      ] ++ if(env_opts == [], do: [], else: [env: env_opts])

    port = Port.open({:spawn_executable, exe}, opts)

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    {:ok, port, os_pid}
  rescue
    exception ->
      {:error, "cannot start AST parser #{exe}: #{Exception.message(exception)}"}
  end

  defp exchange(port, code, timeout_ms) do
    payload = Base.encode64(code) <> "\n"

    try do
      Port.command(port, payload)
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      read_line(port, [], deadline)
    rescue
      exception -> {:error, "AST worker send failed: #{Exception.message(exception)}"}
    end
  end

  defp read_line(port, chunks, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:noeol, chunk}}} ->
        read_line(port, [chunk | chunks], deadline)

      {^port, {:data, {:eol, chunk}}} ->
        line =
          [chunk | chunks]
          |> Enum.reverse()
          |> IO.iodata_to_binary()
          |> String.trim_leading("\uFEFF")
          |> String.trim()

        case Jason.decode(line) do
          {:ok, %{} = map} -> {:ok, map}
          {:ok, other} -> {:error, "unexpected AST response shape: #{inspect(other)}"}
          {:error, err} -> {:error, "invalid AST JSON response: #{Exception.message(err)}"}
        end

      {^port, {:exit_status, status}} ->
        {:error, "AST worker exited unexpectedly (status #{status})"}
    after
      remaining ->
        {:error, "AST worker timed out"}
    end
  end

  defp teardown(state) do
    if is_port(state.port) do
      close_port(state.port)
    end

    if is_integer(state.os_pid) do
      kill_os_pid(state.os_pid)
    end

    cleanup_dir(state.script_dir)
    %{state | port: nil, os_pid: nil, script_dir: nil}
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp kill_os_pid(pid) do
    case :os.type() do
      {:win32, _} ->
        System.cmd("taskkill", ["/F", "/T", "/PID", Integer.to_string(pid)],
          stderr_to_stdout: true
        )

      _posix ->
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp cleanup_dir(nil), do: :ok
  defp cleanup_dir(dir), do: File.rm_rf(dir)
end
