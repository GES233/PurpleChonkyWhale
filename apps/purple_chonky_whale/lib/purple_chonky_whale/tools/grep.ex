defmodule PurpleChonkyWhale.Tools.Grep do
  @moduledoc """
  The `grep` tool: search file contents by regular expression.

  The walk is `PurpleChonkyWhale.Tools.Walk`'s, so build output and vendored
  code are pruned and results are deterministic. `path` may be a directory
  (searched recursively) or a single file.

  Hits are rendered as `path:line_number:text`, with paths relative to the
  working directory (`env[:cwd]`), `/`-separated — the form `read`, `edit`
  and `write` accept back.

  Only text files are searched: a file is skipped if it looks binary (a NUL
  byte in its first block) or is larger than `:max_file_bytes` (default 2 MB).
  Skips are reported, never swallowed: the output ends with a
  `(skipped N files: ...)` note naming each skipped path and the reason, so a
  "no matches" answer cannot be mistaken for "this content does not exist".
  When the scan stopped at `:limit`, the note says the list is partial — a
  skip report must not claim more coverage than the scan actually had.
  Long lines are truncated to `:max_line_chars` (default 500) so one minified
  file cannot blow up the output, and the output is capped at `:limit`
  (default 100) matching lines.

  `:options` are passed to `Regex.compile/2`, e.g. `"i"` for a
  case-insensitive search.
  """

  @behaviour PurpleChonkyWhale.Tool

  alias PurpleChonkyWhale.Tool
  alias PurpleChonkyWhale.Tools.Walk

  @default_limit 100
  @default_max_file_bytes 2_000_000
  @default_max_line_chars 500
  @sniff_bytes 8192
  @max_skipped_paths 5

  @impl true
  def capabilities, do: [:fs_read]

  @impl true
  def schema do
    %{
      name: "grep",
      description:
        "Search file contents with a regular expression, recursively (build " <>
          "output and vendored code are pruned). Returns matching lines as " <>
          "`path:line_number:text`, in path order. `options` are regex options, " <>
          "e.g. \"i\" for a case-insensitive search. Files that were skipped " <>
          "(binary, or over `max_file_bytes`) are reported in a trailing " <>
          "`(skipped N files: ...)` note — a \"no matches\" answer never means " <>
          "those files were searched.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{"type" => "string", "description" => "Regular expression"},
          "path" => %{
            "type" => "string",
            "description" => "File or directory to search. Default: the working directory."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Max matching lines to return. Default #{@default_limit}."
          },
          "max_file_bytes" => %{
            "type" => "integer",
            "description" =>
              "Skip files larger than this many bytes. Default " <>
                "#{@default_max_file_bytes} (#{div(@default_max_file_bytes, 1_000_000)} MB). " <>
                "Raise it only for a specific file the skip note named."
          },
          "options" => %{"type" => "string", "description" => "Regex options, e.g. \"i\"."}
        },
        "required" => ["pattern"]
      }
    }
  end

  @impl true
  def execute(%{"pattern" => pattern} = args, env) when is_binary(pattern) do
    with {:ok, regex} <- compile(pattern, Map.get(args, "options")),
         {:ok, base} <- resolve_base(args, env),
         {:ok, files} <- target_files(base, env) do
      limit = positive(args["limit"], @default_limit)
      max_bytes = non_negative(args["max_file_bytes"], @default_max_file_bytes)
      max_chars = non_negative(args["max_line_chars"], @default_max_line_chars)

      # One hit past the limit distinguishes "exactly at the cap" from
      # "more matches than were shown".
      {hits, skipped, capped?} = collect(files, cwd(env), regex, max_bytes, max_chars, limit)

      {:ok, render(base, hits, skipped, capped?, limit)}
    end
  end

  def execute(_args, _env), do: {:error, "pattern is a required string"}

  defp resolve_base(args, env) do
    case Map.get(args, "path") do
      nil -> {:ok, cwd(env)}
      path -> Tool.authorize_path(env, path, :read)
    end
  end

  defp cwd(env), do: env[:cwd] || File.cwd!()

  # Model-supplied numbers: accept integers, fall back on anything else
  # (a string from a sloppy tool call must not crash the pipeline).
  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp non_negative(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value, default), do: default

  # Returns `{hits, skipped, capped?}`. `skipped` holds `{relative_path,
  # reason}` pairs for the files that were never searched, and `capped?` records
  # that the walk stopped at `limit` — in that case the skip list only covers
  # the files reached before the stop, which the renderer says out loud.
  defp collect(files, cwd, regex, max_bytes, max_chars, limit) do
    {hits, skipped, capped?} =
      Enum.reduce_while(files, {[], [], false}, fn path, {hits, skipped, _capped?} ->
        case file_hits(path, cwd, regex, max_bytes, max_chars) do
          {:hits, new_hits} ->
            hits = hits ++ new_hits

            if length(hits) > limit do
              {:halt, {hits, skipped, true}}
            else
              {:cont, {hits, skipped, false}}
            end

          {:skip, relative, reason} ->
            {:cont, {hits, [{relative, skip_reason(reason, max_bytes)} | skipped], false}}
        end
      end)

    {hits, Enum.reverse(skipped), capped?}
  end

  defp compile(pattern, options) when is_binary(options) or is_nil(options) do
    case Regex.compile(pattern, options || "") do
      {:ok, regex} ->
        {:ok, regex}

      {:error, {message, at}} ->
        {:error, "invalid pattern: #{message} (at byte #{at})"}
    end
  end

  defp compile(_pattern, options) do
    {:error, "options must be a string, got: #{inspect(options)}"}
  end

  defp target_files(base, env) do
    case File.stat(base) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, Walk.files(base, env)}
      {:ok, %File.Stat{type: :regular}} -> {:ok, [base]}
      {:ok, _} -> {:error, "not a file or directory: #{base}"}
      {:error, :enoent} -> {:error, "path not found: #{base}"}
      {:error, reason} -> {:error, "cannot search #{base}: #{:file.format_error(reason)}"}
    end
  end

  defp file_hits(path, cwd, regex, max_bytes, max_chars) do
    case read_text(path, max_bytes) do
      {:ok, text} ->
        hits =
          text
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _n} -> Regex.match?(regex, line) end)
          |> Enum.map(fn {line, n} ->
            "#{Walk.relative(path, cwd)}:#{n}:#{truncate(line, max_chars)}"
          end)

        {:hits, hits}

      {:skip, reason} ->
        {:skip, Walk.relative(path, cwd), reason}
    end
  end

  # The size check and the binary sniff run before the full read: the search
  # must not pull a huge blob into memory.
  defp read_text(path, max_bytes) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size <= max_bytes ->
        sniff_and_read(path)

      {:ok, %File.Stat{size: size}} ->
        {:skip, {:too_large, size}}

      {:error, reason} ->
        {:skip, {:unreadable, reason}}
    end
  end

  defp sniff_and_read(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        head =
          case IO.binread(io, @sniff_bytes) do
            data when is_binary(data) -> data
            _ -> ""
          end

        File.close(io)

        with false <- String.contains?(head, <<0>>),
             {:ok, text} <- File.read(path) do
          {:ok, text}
        else
          true -> {:skip, :binary}
          {:error, reason} -> {:skip, {:unreadable, reason}}
        end

      {:error, reason} ->
        {:skip, {:unreadable, reason}}
    end
  end

  defp truncate(line, max) when max <= 0, do: line

  defp truncate(line, max) do
    if String.length(line) > max do
      String.slice(line, 0, max) <> "..."
    else
      line
    end
  end

  defp render(base, [], skipped, capped?, _limit) do
    append_skipped("(no matches in #{base})", skipped, capped?)
  end

  defp render(_base, hits, skipped, capped?, limit) do
    text = hits |> Enum.take(limit) |> Enum.join("\n")

    text =
      if length(hits) > limit do
        text <> "\n... (capped at #{limit} matching lines)"
      else
        text
      end

    append_skipped(text, skipped, capped?)
  end

  # A silent skip is the dangerous case: the model reads "no matches" and
  # concludes the content is absent. Name what was skipped and why.
  defp append_skipped(text, [], _capped?), do: text

  defp append_skipped(text, skipped, capped?) do
    shown = Enum.take(skipped, @max_skipped_paths)

    entries =
      Enum.map_join(shown, "; ", fn {path, reason} -> "#{path} #{reason}" end)

    more =
      case length(skipped) - length(shown) do
        n when n > 0 -> "; and #{n} more"
        _ -> ""
      end

    partial =
      if capped?,
        do: " — scan stopped at the match cap, so this list is partial",
        else: ""

    text <>
      "\n(skipped #{length(skipped)} #{plural(length(skipped), "file")}: " <>
      "#{entries}#{more}#{partial})"
  end

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  defp skip_reason({:too_large, size}, max_bytes),
    do: "is #{human_bytes(size)}, over the #{human_bytes(max_bytes)} limit"

  defp skip_reason(:binary, _max_bytes), do: "looks binary"

  defp skip_reason({:unreadable, reason}, _max_bytes),
    do: "could not be read (#{:file.format_error(reason)})"

  defp human_bytes(bytes) when bytes >= 1_000_000,
    do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  defp human_bytes(bytes) when bytes >= 1_000, do: "#{Float.round(bytes / 1_000, 1)} kB"
  defp human_bytes(bytes), do: "#{bytes} B"
end
