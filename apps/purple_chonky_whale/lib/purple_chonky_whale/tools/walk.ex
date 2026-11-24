defmodule PurpleChonkyWhale.Tools.Walk do
  # Defined ahead of the moduledoc, which reads it.
  @default_ignore [
    ".git",
    ".svn",
    ".hg",
    ".elixir_ls",
    "_build",
    "cover",
    "deps",
    "doc",
    "node_modules",
    "tmp",
    ".venv",
    "venv",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    ".bloop",
    ".metals",
    ".bsp",
    ".gradle",
    ".idea",
    "target",
    "build",
    "dist",
    "out",
    ".next",
    ".nuxt",
    ".cache"
  ]

  @ignore_files [".gitignore", ".ignore"]

  @moduledoc """
  The file-tree plumbing the search tools (`glob`, `grep`) share: a
  deterministic, symlink-safe walk, and the glob matcher they filter with.

  A walk prunes directory *names* that only ever hold build output or
  vendored code:

      #{inspect(@default_ignore)}

  In addition, when pruning is enabled, `.gitignore` and `.ignore` rules in
  the searched root (and workspace `:cwd`) are honored. `env[:search_ignore_dirs]`
  replaces the default directory list for a call; an empty list (`[]`)
  disables all pruning (including ignore files) and walks everything reachable.
  Symlinked directories are never followed (`File.lstat/1` sees the link, not
  the target), so a self-referential link cannot send a walk into a loop.

  Paths reported by the search tools go through `relative/2`, which makes
  them relative to the working directory and uses `/` separators on every
  platform — so they can be handed straight back to `read`, `edit` or
  `write`, which resolve against the same `:cwd`.
  """

  @doc "The directory names pruned for a call, from `env[:search_ignore_dirs]`."
  @spec ignore_dirs(PurpleChonkyWhale.Tool.env()) :: [String.t()]
  # Access, not Map.get: a direct caller (the in-process Elixir runtime) may
  # hand over a keyword list, and both shapes read the same through it.
  def ignore_dirs(env), do: env[:search_ignore_dirs] || @default_ignore

  @doc """
  Every regular file under `base`, pruned, in path order so that repeated
  calls report identically. `base` is trusted to exist and be a directory.
  """
  @spec files(Path.t(), PurpleChonkyWhale.Tool.env()) :: [Path.t()]
  def files(base, env) do
    dirs = ignore_dirs(env)
    ignore = MapSet.new(dirs)
    rules = if dirs == [], do: [], else: load_ignore_rules(base, env)

    base
    |> walk(base, ignore, rules, [])
    |> Enum.sort()
  end

  @doc """
  Compile a glob into an anchored regex. Supported wildcards: `*` (any
  characters within a path segment), `?` (exactly one character) and `**`
  (any number of directory prefixes, including none) — so `"**/*.ex"`
  matches both `"lib/a.ex"` and `"lib/nested/b.ex"`. Matching runs on
  `/`-joined paths.
  """
  @spec compile_glob(String.t()) :: Regex.t()
  def compile_glob(glob), do: Regex.compile!("^" <> source(glob) <> "$")

  @doc """
  Does the file `path` (somewhere under `base`) match `glob`? A glob with no
  `/` is matched against the file's name at any depth; one with a `/` is
  matched against the path relative to `base`.
  """
  @spec glob_match?(Regex.t(), String.t(), Path.t(), Path.t()) :: boolean()
  def glob_match?(regex, glob, path, base) do
    if String.contains?(glob, "/") do
      Regex.match?(regex, relative(path, base))
    else
      Regex.match?(regex, Path.basename(path))
    end
  end

  @doc "`path` relative to `base`, with `/` separators on every platform."
  @spec relative(Path.t(), Path.t()) :: String.t()
  def relative(path, base), do: path |> Path.relative_to(base) |> slash()

  @doc "The path with `/` separators on every platform."
  @spec slash(Path.t()) :: String.t()
  def slash(path), do: path |> Path.split() |> Enum.join("/")

  ## Internal

  defp walk(dir, root, ignore, rules, acc) do
    local_rules =
      if dir == root or (rules == [] and MapSet.size(ignore) == 0) do
        rules
      else
        rules ++ read_dir_ignore_rules(dir, root)
      end

    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(entries, acc, fn entry, acc ->
          path = Path.join(dir, entry)
          rel = relative(path, root)
          is_dir = directory?(path)

          cond do
            MapSet.member?(ignore, entry) -> acc
            ignored_by_rules?(rel, entry, is_dir, local_rules) -> acc
            is_dir -> walk(path, root, ignore, local_rules, acc)
            File.regular?(path) -> [path | acc]
            true -> acc
          end
        end)

      # An unreadable subdirectory loses its files, not the whole search.
      {:error, _reason} ->
        acc
    end
  end

  defp load_ignore_rules(base, env) do
    cwd = env[:cwd]

    roots =
      if is_binary(cwd) and Path.expand(cwd) != Path.expand(base) do
        [cwd, base]
      else
        [base]
      end

    Enum.flat_map(roots, &read_dir_ignore_rules(&1, base))
  end

  defp read_dir_ignore_rules(dir, root) do
    prefix =
      case Path.relative_to(dir, root) do
        "." -> ""
        rel -> slash(rel) <> "/"
      end

    Enum.flat_map(@ignore_files, fn filename ->
      path = Path.join(dir, filename)

      case File.read(path) do
        {:ok, content} -> parse_ignore_content(content, prefix)
        {:error, _} -> []
      end
    end)
  end

  defp parse_ignore_content(content, prefix) do
    content
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(&compile_ignore_line(&1, prefix))
  end

  defp compile_ignore_line(line, prefix) do
    trimmed = String.trim(line)

    if trimmed == "" or String.starts_with?(trimmed, "#") do
      []
    else
      {negated?, raw} =
        if String.starts_with?(trimmed, "!") do
          {true, String.slice(trimmed, 1..-1//1)}
        else
          {false, trimmed}
        end

      dir_only? = String.ends_with?(raw, "/")
      cleaned = raw |> String.trim_leading("/") |> String.trim_trailing("/")
      anchored? = String.starts_with?(raw, "/") or String.contains?(cleaned, "/")

      if cleaned == "" do
        []
      else
        regex =
          if anchored? do
            compile_glob(prefix <> cleaned)
          else
            compile_glob(cleaned)
          end

        [
          %{
            negated?: negated?,
            dir_only?: dir_only?,
            anchored?: anchored?,
            regex: regex
          }
        ]
      end
    end
  rescue
    _ -> []
  end

  defp ignored_by_rules?(_rel, _entry, _is_dir, []), do: false

  defp ignored_by_rules?(rel, entry, is_dir, rules) do
    Enum.reduce(rules, false, fn rule, ignored? ->
      if rule_matches?(rule, rel, entry, is_dir) do
        not rule.negated?
      else
        ignored?
      end
    end)
  end

  defp rule_matches?(%{dir_only?: true}, _rel, _entry, false), do: false

  defp rule_matches?(%{anchored?: true, regex: regex}, rel, _entry, _is_dir) do
    Regex.match?(regex, rel)
  end

  defp rule_matches?(%{anchored?: false, regex: regex}, rel, entry, _is_dir) do
    Regex.match?(regex, entry) or Regex.match?(regex, rel)
  end

  defp directory?(path) do
    match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))
  end

  defp source(<<>>), do: ""
  defp source(<<"**/", rest::binary>>), do: "(?:[^/]+/)*" <> source(rest)
  defp source(<<"**", rest::binary>>), do: ".*" <> source(rest)
  defp source(<<"*", rest::binary>>), do: "[^/]*" <> source(rest)
  defp source(<<"?", rest::binary>>), do: "[^/]" <> source(rest)

  defp source(<<char::utf8, rest::binary>>) do
    Regex.escape(<<char::utf8>>) <> source(rest)
  end
end
