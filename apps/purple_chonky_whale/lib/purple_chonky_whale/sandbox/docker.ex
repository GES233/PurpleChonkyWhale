defmodule PurpleChonkyWhale.Sandbox.Docker do
  @moduledoc """
  Docker container isolation backend for `PurpleChonkyWhale.Sandbox`.

  Wraps materialized `Executor.Runner` plans and `{:stdio, opts}` MCP
  transports into `docker run --rm -i` invocations with:

    * `--network=none` unless `Profile.network_allowed?/1` is `true`
    * `--cap-drop=ALL` and `--security-opt=no-new-privileges`
    * `--read-only` root filesystem plus `--tmpfs /tmp:rw,noexec,nosuid`
    * workspace `cwd` mounted at `/workspace` (`:ro` in `:read_only` mode,
      `:rw` otherwise)
    * per-run scratch `run_dir` mounted at `/pcw-run:rw` with `TEMP`/`TMP`/`TMPDIR`
      pinned to `/pcw-run/tmp` and script paths rewritten inside `plan.args`

  Options (`:backend_opts`):

    * `:image` (required) — container image tag (e.g. `"elixir:1.20-alpine"`)
    * `:docker_exe` — path or executable name (default `"docker"`)
    * `:find_executable` — injectable `(String.t() -> String.t() | nil)` lookup
      for tests (default `&System.find_executable/1`)
    * `:extra_args` — extra `docker run` CLI flags
  """

  @behaviour PurpleChonkyWhale.Sandbox.Backend

  alias PurpleChonkyWhale.Sandbox.Profile

  @container_workspace "/workspace"
  @container_run_dir "/pcw-run"

  @impl true
  def available?(opts) do
    image = Keyword.get(opts, :image)
    docker_exe = Keyword.get(opts, :docker_exe, "docker")
    finder = Keyword.get(opts, :find_executable, &System.find_executable/1)

    cond do
      not is_binary(image) or String.trim(image) == "" ->
        {:error, "docker :image is not configured"}

      is_nil(finder.(docker_exe)) ->
        {:error, "executable #{inspect(docker_exe)} not found on PATH"}

      true ->
        :ok
    end
  end

  @impl true
  def wrap_plan(plan, ctx, %Profile{} = profile, opts) do
    with :ok <- available?(opts) do
      image = Keyword.fetch!(opts, :image)
      docker_exe = resolve_docker_exe(opts)
      cwd = ctx[:cwd] || profile.cwd || File.cwd!()
      run_dir = ctx[:run_dir]
      extra_args = Keyword.get(opts, :extra_args, [])

      workdir =
        if is_binary(run_dir) and plan.cwd == run_dir do
          @container_run_dir
        else
          @container_workspace
        end

      mounts =
        workspace_mount(cwd, profile.mode) ++
          run_dir_mount(run_dir) ++
          extra_mounts(profile, cwd)

      net_flags = if Profile.network_allowed?(profile), do: [], else: ["--network=none"]

      tmp_env =
        if is_binary(run_dir) do
          tmp = "#{@container_run_dir}/tmp"
          ["-e", "TEMP=#{tmp}", "-e", "TMP=#{tmp}", "-e", "TMPDIR=#{tmp}"]
        else
          []
        end

      rewritten_args = rewrite_args(plan.args, run_dir)
      container_exe = container_executable(plan.exe)

      docker_args =
        [
          "run",
          "--rm",
          "-i",
          "--init",
          "--cap-drop=ALL",
          "--security-opt=no-new-privileges",
          "--read-only",
          "--tmpfs",
          "/tmp:rw,noexec,nosuid",
          "-w",
          workdir
        ] ++
          net_flags ++
          mounts ++
          tmp_env ++
          extra_args ++
          [image, container_exe | rewritten_args]

      {:ok, %{exe: docker_exe, args: docker_args, cwd: nil, script: nil}}
    end
  end

  @impl true
  def wrap_stdio(stdio_opts, %Profile{} = profile, opts) do
    with :ok <- available?(opts),
         cmd when is_binary(cmd) and cmd != "" <- Keyword.get(stdio_opts, :command) do
      image = Keyword.fetch!(opts, :image)
      docker_exe = resolve_docker_exe(opts)
      cwd = Keyword.get(stdio_opts, :cwd) || profile.cwd
      cmd_args = Keyword.get(stdio_opts, :args) || []
      extra_args = Keyword.get(opts, :extra_args, [])

      mounts =
        case cwd do
          dir when is_binary(dir) -> workspace_mount(dir, profile.mode)
          _ -> []
        end

      workdir_flags = if is_binary(cwd), do: ["-w", @container_workspace], else: []
      net_flags = if Profile.network_allowed?(profile), do: [], else: ["--network=none"]

      env_flags =
        stdio_opts
        |> Keyword.get(:env)
        |> case do
          %{} = map -> Enum.flat_map(map, fn {k, v} -> ["-e", "#{k}=#{v}"] end)
          _ -> []
        end

      docker_args =
        [
          "run",
          "--rm",
          "-i",
          "--init",
          "--cap-drop=ALL",
          "--security-opt=no-new-privileges",
          "--read-only",
          "--tmpfs",
          "/tmp:rw,noexec,nosuid"
        ] ++
          workdir_flags ++
          net_flags ++
          mounts ++
          env_flags ++
          extra_args ++
          [image, container_executable(cmd) | cmd_args]

      {:ok,
       stdio_opts
       |> Keyword.put(:command, docker_exe)
       |> Keyword.put(:args, docker_args)
       |> Keyword.put(:env, %{})
       |> Keyword.delete(:cwd)}
    else
      nil -> {:error, "stdio transport missing required :command"}
      "" -> {:error, "stdio transport missing required :command"}
      {:error, _} = err -> err
    end
  end

  defp resolve_docker_exe(opts) do
    docker_exe = Keyword.get(opts, :docker_exe, "docker")
    finder = Keyword.get(opts, :find_executable, &System.find_executable/1)
    finder.(docker_exe) || docker_exe
  end

  defp workspace_mount(cwd, :read_only), do: ["-v", "#{cwd}:#{@container_workspace}:ro"]
  defp workspace_mount(cwd, _mode), do: ["-v", "#{cwd}:#{@container_workspace}:rw"]

  defp run_dir_mount(nil), do: []
  defp run_dir_mount(run_dir), do: ["-v", "#{run_dir}:#{@container_run_dir}:rw"]

  defp extra_mounts(profile, cwd) do
    cwd_norm = normalize_slashes(cwd)

    writable =
      profile
      |> Profile.effective_writable_roots()
      |> Enum.reject(&(normalize_slashes(&1) == cwd_norm))
      |> Enum.flat_map(&["-v", "#{&1}:#{&1}:rw"])

    readable =
      profile
      |> Profile.effective_readable_roots()
      |> Enum.reject(&(normalize_slashes(&1) == cwd_norm))
      |> Enum.flat_map(&["-v", "#{&1}:#{&1}:ro"])

    writable ++ readable
  end

  defp rewrite_args(args, nil), do: args

  defp rewrite_args(args, run_dir) when is_binary(run_dir) do
    norm_run = normalize_slashes(run_dir)

    Enum.map(args, fn arg ->
      arg
      |> to_string()
      |> normalize_slashes()
      |> String.replace(norm_run, @container_run_dir)
    end)
  end

  defp container_executable(exe) do
    exe
    |> Path.basename()
    |> String.replace_suffix(".exe", "")
  end

  defp normalize_slashes(path), do: String.replace(path, "\\", "/")
end
