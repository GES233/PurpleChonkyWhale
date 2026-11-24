defmodule PurpleChonkyWhale.Tools.Glob do
  @moduledoc """
  The `glob` tool: find files by name pattern under a directory.

  The walk and the matcher are `PurpleChonkyWhale.Tools.Walk`'s, so build
  output and vendored code are pruned (see `Walk` for the default prune
  list) and results are deterministic.

  Matching runs against paths relative to the searched directory; the paths
  *reported* are relative to the working directory (`env[:cwd]`), with `/`
  separators — the form `read`, `edit` and `write` accept back.
  """

  @behaviour PurpleChonkyWhale.Tool

  alias PurpleChonkyWhale.Tool
  alias PurpleChonkyWhale.Tools.Walk

  @default_limit 200

  @impl true
  def schema do
    %{
      name: "glob",
      description:
        "Find files whose path matches a glob pattern. Supported wildcards: " <>
          "`*` (within a path segment), `?` (one character) and `**` (any " <>
          "number of directories). A pattern without a `/` matches the file " <>
          "name at any depth; results are ordered shallowest-first and " <>
          "relative to the working directory. Pass `max_depth: 1` to list " <>
          "only files directly in `path`.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{"type" => "string", "description" => "Glob pattern, e.g. \"**/*.ex\""},
          "path" => %{
            "type" => "string",
            "description" => "Directory to search. Default: the working directory."
          },
          "max_depth" => %{
            "type" => "integer",
            "description" =>
              "Optional maximum directory depth relative to `path` (1 = top-level files only)."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Max paths to return. Default #{@default_limit}."
          }
        },
        "required" => ["pattern"]
      }
    }
  end

  @impl true
  def execute(%{"pattern" => pattern} = args, env) when is_binary(pattern) do
    base =
      case Map.get(args, "path") do
        nil -> cwd(env)
        path -> Tool.resolve_path(env, path)
      end

    # Model-supplied numbers: accept integers, fall back on anything else.
    limit =
      case Map.get(args, "limit") do
        n when is_integer(n) and n > 0 -> n
        _other -> @default_limit
      end

    max_depth =
      case Map.get(args, "max_depth") do
        n when is_integer(n) and n > 0 -> n
        _other -> nil
      end

    with :ok <- validate_dir(base) do
      regex = Walk.compile_glob(pattern)

      matches =
        base
        |> Walk.files(env)
        |> Enum.filter(&within_depth?(&1, base, max_depth))
        |> Enum.filter(&Walk.glob_match?(regex, pattern, &1, base))
        |> Enum.sort_by(fn path -> {depth(path, base), Walk.relative(path, cwd(env))} end)
        |> Enum.map(&Walk.relative(&1, cwd(env)))

      {:ok, render(base, matches, limit)}
    end
  end

  def execute(_args, _env), do: {:error, "pattern is a required string"}

  defp cwd(env), do: env[:cwd] || File.cwd!()

  defp within_depth?(_path, _base, nil), do: true
  defp within_depth?(path, base, max_depth), do: depth(path, base) <= max_depth

  defp depth(path, base) do
    path
    |> Walk.relative(base)
    |> String.split("/")
    |> length()
  end

  defp validate_dir(base) do
    case File.stat(base) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _} -> {:error, "not a directory: #{base}"}
      {:error, :enoent} -> {:error, "directory not found: #{base}"}
      {:error, reason} -> {:error, "cannot search #{base}: #{:file.format_error(reason)}"}
    end
  end

  defp render(base, [], _limit), do: "(no files matched in #{base})"

  defp render(base, matches, limit) do
    text = matches |> Enum.take(limit) |> Enum.join("\n")

    if length(matches) > limit do
      text <> "\n... (#{length(matches)} matches in #{base}, showing #{limit})"
    else
      text
    end
  end
end
