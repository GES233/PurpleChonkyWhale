defmodule PurpleChonkyWhale.Security.PathGuard do
  # Defined ahead of the moduledoc, which reads them.
  @max_symlink_hops 40

  @sensitive_home_dirs ~w(
    Desktop
    Documents
    Downloads
    Pictures
    Music
    Videos
    OneDrive
    .ssh
    .gnupg
    .aws
    .kube
    .dsh
    .pcw
  )

  @sensitive_home_files ~w(
    .gitconfig
    .netrc
    .bashrc
    .bash_profile
    .zshrc
    .zprofile
    .profile
  )

  @moduledoc """
  Kernel-level path boundary enforcement and self-destruct floor for file tools.

  Every built-in file tool (`read`, `write`, `edit`, `glob`, `grep`) and the
  `execute` tool's `cwd` argument authorize paths through this module before
  touching the filesystem.

  ## Two layers of protection

    1. **Workspace boundary (default-deny outside allowed roots):**
       Relative paths resolve against `env[:cwd]` (falling back to
       `File.cwd!/0`). The target's real physical path — resolving symlinks
       across the deepest existing ancestor (capped at #{@max_symlink_hops}
       hops against cycles) — must fall inside the allowed roots for the
       requested access:

         * `:read` — `[cwd | env[:readable_roots] || []]`
         * `:write` — `[cwd | env[:writable_roots] || []]`

       A symlink inside the workspace that points outside it is refused.
       Prefix checks are segment-aware (`/tmp/app` never matches `/tmp/app2`)
       and case-insensitive on Windows.

    2. **Self-destruct floor (always enforced on `:write`):**
       Writes are unconditionally refused against paths whose destruction
       would damage the host or the harness itself, even if a caller widens
       `:writable_roots` or sets `:cwd` dangerously:

         * any filesystem or drive root (`/`, `C:/`, `D:/`, …)
         * OS system directories (`C:/Windows`, `C:/Program Files*`,
           `C:/ProgramData`, `/etc`, `/usr`, `/bin`, `/sbin`, `/System`)
         * the user home directory itself (`System.user_home/0`), its core
           personal/credential subdirectories (`Desktop`, `Documents`,
           `Downloads`, `OneDrive`, `.ssh`, `.gnupg`, `.aws`, `.kube`, `.dsh`,
           `.pcw`, `AppData/Roaming`), and sensitive dotfiles (`.gitconfig`,
           `.bashrc`, `.zshrc`, …)
         * any directory listed in `env[:protected_dirs]` (e.g. a persona's
           state home)

       Note that `System.tmp_dir!/0` (under `AppData/Local/Temp` on Windows)
       is deliberately *not* blocked so tests and ephemeral workspaces under
       the temp directory continue to work.

  ## Environment knobs

    * `:cwd` — workspace root (default `File.cwd!/0`)
    * `:readable_roots` — additional directories permitted for `:read`
    * `:writable_roots` — additional directories permitted for `:write`
    * `:protected_dirs` — additional directories unconditionally blocked for
      `:write`
  """

  @type access :: :read | :write

  @doc """
  Authorize `raw_path` for `:read` or `:write` against `env`.

  Returns `{:ok, expanded_path}` when the resolved physical path is allowed,
  or `{:error, message}` when it is malformed, escapes the allowed roots, or
  hits the write self-destruct floor.
  """
  @spec authorize(map() | keyword(), term(), access()) :: {:ok, String.t()} | {:error, String.t()}
  def authorize(env, raw_path, access)
      when (is_map(env) or is_list(env)) and access in [:read, :write] do
    with {:ok, path} <- validate_raw_path(raw_path),
         cwd = cwd(env),
         abs_path = resolve_abs(cwd, path),
         {:ok, real_target} <- realpath(abs_path),
         :ok <- check_write_floor(real_target, access, env),
         roots = allowed_roots(env, cwd, access),
         :ok <- check_roots_safe(roots, access),
         :ok <- check_within_roots(real_target, roots, access) do
      {:ok, preserved_path(env, path)}
    end
  end

  @doc """
  Resolve symlinks across the deepest existing ancestor of `path` and return
  the normalized physical path.

  Non-existent trailing segments (such as a file or nested directory about to
  be created by `write`) are appended verbatim after the resolved ancestor.
  Returns `{:error, message}` if a symlink cycle exceeds #{@max_symlink_hops}
  hops.
  """
  @spec realpath(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def realpath(path) when is_binary(path) do
    expanded = path |> strip_win_extended_prefix() |> Path.expand()

    case resolve_components(expanded, 0) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Whether `target` is equal to or strictly inside `root` (segment-aware, and
  case-insensitive on Windows). Both paths should already be expanded /
  canonicalized.
  """
  @spec within_root?(String.t(), String.t()) :: boolean()
  def within_root?(target, root) when is_binary(target) and is_binary(root) do
    target_key = compare_key(target)
    root_key = compare_key(root)

    cond do
      target_key == root_key ->
        true

      String.ends_with?(root_key, "/") ->
        String.starts_with?(target_key, root_key)

      true ->
        String.starts_with?(target_key, root_key <> "/")
    end
  end

  @doc """
  Whether writing to `real_target` is unconditionally blocked by the kernel
  self-destruct floor.
  """
  @spec protected_write?(String.t(), map() | keyword()) :: boolean()
  def protected_write?(real_target, env \\ %{}) when is_binary(real_target) do
    check_write_floor(real_target, :write, env) != :ok
  end

  ## Raw input & resolution

  defp validate_raw_path(path) when is_binary(path) do
    cond do
      String.trim(path) == "" -> {:error, "path must not be empty"}
      String.contains?(path, <<0>>) -> {:error, "path must not contain NUL bytes"}
      true -> {:ok, path}
    end
  end

  defp validate_raw_path(_other), do: {:error, "path must be a string"}

  defp cwd(env), do: (env[:cwd] || File.cwd!()) |> strip_win_extended_prefix() |> Path.expand()

  defp resolve_abs(cwd, raw_path) do
    cleaned = strip_win_extended_prefix(raw_path)

    if Path.type(cleaned) == :absolute do
      Path.expand(cleaned)
    else
      Path.expand(cleaned, cwd)
    end
  end

  # Keep the caller's original drive-letter casing and separator style (matching
  # `Tool.resolve_path/2`) once the canonicalized realpath has been authorized.
  defp preserved_path(env, raw_path) do
    if Path.type(raw_path) == :absolute do
      raw_path
    else
      Path.join(env[:cwd] || File.cwd!(), raw_path)
    end
  end

  defp strip_win_extended_prefix("\\\\?\\" <> rest), do: rest
  defp strip_win_extended_prefix("//?/" <> rest), do: rest
  defp strip_win_extended_prefix(path), do: path

  ## Symlink-safe realpath resolution

  defp resolve_components(_path, hops) when hops > @max_symlink_hops do
    {:error, "symlink loop detected while resolving path"}
  end

  defp resolve_components(expanded, hops) do
    [root | segments] = Path.split(expanded)
    walk_segments(root, segments, hops)
  end

  defp walk_segments(acc, [], _hops), do: {:ok, normalize_slashes(acc)}

  defp walk_segments(acc, [segment | rest], hops) do
    candidate = Path.join(acc, segment)

    case :file.read_link_all(candidate) do
      {:ok, target_charlist} ->
        target = IO.chardata_to_string(target_charlist) |> strip_win_extended_prefix()

        next_base =
          if Path.type(target) == :absolute do
            Path.expand(target)
          else
            Path.expand(target, acc)
          end

        combined =
          case rest do
            [] -> next_base
            _ -> Path.join([next_base | rest])
          end

        resolve_components(Path.expand(combined), hops + 1)

      {:error, :einval} ->
        # Exists and is not a symlink — keep walking.
        walk_segments(candidate, rest, hops)

      {:error, :enoent} ->
        # Reached the non-existent tail: append remaining segments as-is.
        {:ok, normalize_slashes(Path.join([candidate | rest]))}

      {:error, _other} ->
        # Permission error or non-symlink platform error — stop following links
        # and keep the expanded remainder so callers surface the OS error cleanly.
        {:ok, normalize_slashes(Path.join([candidate | rest]))}
    end
  end

  ## Self-destruct floor (always enforced on :write)

  defp check_write_floor(_real_target, :read, _env), do: :ok

  defp check_write_floor(real_target, :write, env) do
    cond do
      filesystem_root?(real_target) ->
        {:error, "path denied: cannot write to filesystem root #{real_target}"}

      system_dir?(real_target) ->
        {:error, "path denied: #{real_target} is inside a protected system directory"}

      user_home_protected?(real_target) ->
        {:error, "path denied: #{real_target} is a protected user home path"}

      explicitly_protected?(real_target, env) ->
        {:error, "path denied: #{real_target} is inside a protected directory"}

      true ->
        :ok
    end
  end

  defp filesystem_root?(path) do
    key = compare_key(path)
    key == "/" or Regex.match?(~r/\A[a-z]:\/\z/, key)
  end

  defp system_dir?(real_target) do
    Enum.any?(system_roots(), &within_root?(real_target, &1))
  end

  defp system_roots do
    case :os.type() do
      {:win32, _} ->
        win_root = System.get_env("SystemRoot") || "C:/Windows"
        prog = System.get_env("ProgramFiles") || "C:/Program Files"
        prog86 = System.get_env("ProgramFiles(x86)") || "C:/Program Files (x86)"
        progdata = System.get_env("ProgramData") || "C:/ProgramData"

        [win_root, prog, prog86, progdata]
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&canonical_root/1)

      _posix ->
        ~w(/etc /usr /bin /sbin /System /Library)
        |> Enum.map(&canonical_root/1)
    end
  end

  defp user_home_protected?(real_target) do
    case user_home_canonical() do
      nil ->
        false

      home ->
        exact_home?(real_target, home) or
          in_sensitive_home_subdir?(real_target, home) or
          sensitive_home_file?(real_target, home) or
          in_windows_roaming_appdata?(real_target, home)
    end
  end

  defp user_home_canonical do
    case System.user_home() do
      nil -> nil
      home -> canonical_root(home)
    end
  end

  defp exact_home?(real_target, home), do: compare_key(real_target) == compare_key(home)

  defp in_sensitive_home_subdir?(real_target, home) do
    Enum.any?(@sensitive_home_dirs, fn sub ->
      within_root?(real_target, Path.join(home, sub))
    end)
  end

  defp sensitive_home_file?(real_target, home) do
    target_key = compare_key(real_target)

    Enum.any?(@sensitive_home_files, fn file ->
      target_key == compare_key(Path.join(home, file))
    end)
  end

  defp in_windows_roaming_appdata?(real_target, home) do
    case :os.type() do
      {:win32, _} ->
        roaming =
          case System.get_env("APPDATA") do
            nil -> Path.join([home, "AppData", "Roaming"])
            dir -> canonical_root(dir)
          end

        within_root?(real_target, roaming)

      _posix ->
        false
    end
  end

  defp explicitly_protected?(real_target, env) do
    env
    |> Access.get(:protected_dirs, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&canonical_root/1)
    |> Enum.any?(&within_root?(real_target, &1))
  end

  ## Workspace / allowed-roots boundary

  defp allowed_roots(env, cwd, :read) do
    extra = env |> Access.get(:readable_roots, []) |> List.wrap()
    canonicalize_roots([cwd | extra])
  end

  defp allowed_roots(env, cwd, :write) do
    extra = env |> Access.get(:writable_roots, []) |> List.wrap()
    canonicalize_roots([cwd | extra])
  end

  defp canonicalize_roots(roots) do
    roots
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&canonical_root/1)
    |> Enum.uniq_by(&compare_key/1)
  end

  defp canonical_root(path) do
    case realpath(path) do
      {:ok, resolved} -> resolved
      {:error, _} -> path |> strip_win_extended_prefix() |> Path.expand() |> normalize_slashes()
    end
  end

  defp check_roots_safe(_roots, :read), do: :ok

  defp check_roots_safe(roots, :write) do
    home = user_home_canonical()

    bad =
      Enum.find(roots, fn root ->
        filesystem_root?(root) or (not is_nil(home) and exact_home?(root, home))
      end)

    if bad do
      {:error, "path denied: refusing to use #{bad} as a writable root"}
    else
      :ok
    end
  end

  defp check_within_roots(real_target, roots, access) do
    if Enum.any?(roots, &within_root?(real_target, &1)) do
      :ok
    else
      {:error,
       "path denied: #{real_target} is outside allowed #{access} roots (#{Enum.join(roots, ", ")})"}
    end
  end

  ## Platform normalization

  defp normalize_slashes(path), do: String.replace(path, "\\", "/")

  defp compare_key(path) do
    normalized = path |> normalize_slashes() |> trim_trailing_slash()

    case :os.type() do
      {:win32, _} -> String.downcase(normalized)
      _posix -> normalized
    end
  end

  defp trim_trailing_slash("/"), do: "/"

  defp trim_trailing_slash(<<drive::binary-size(1), ":/">>) do
    <<drive::binary-size(1), ":/">>
  end

  defp trim_trailing_slash(path), do: String.trim_trailing(path, "/")
end
