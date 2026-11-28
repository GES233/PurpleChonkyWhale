defmodule PurpleChonkyWhale.Tools.Edit do
  @moduledoc """
  The `edit` tool: replace a unique string occurrence in a file.

  Line endings: matching runs on an LF-normalized view (models emit LF and
  cannot reliably reproduce `\\r`), and the file's original convention is
  restored on write — a CRLF file stays CRLF, byte for byte outside the
  replaced region. A BOM and the trailing-newline state are preserved. A
  file with *mixed* endings is normalized wholesale to its dominant
  convention, and the result message says so.

  When exact matching finds nothing, a fallback retry ignores trailing
  whitespace per line; the replacement splices only the matched lines,
  leaving the rest of the file byte-identical.

  ## What an edit guarantees

    * **Mutual exclusion** (strong): calls that go through the `:tools` seam
      are serialized per target path, so within one VM two edits of the same
      file never interleave their read-modify-write cycles.
    * **Atomic replacement** (strong): the new bytes are written to a temp file
      and renamed over the target, so a reader sees the complete old file or
      the complete new one, and a crash mid-write leaves the file untouched.
    * **External-change detection** (best effort): the bytes the edit was
      computed from are re-read just before writing; a mismatch is refused
      rather than silently overwritten. This is *detection*, not exclusion — a
      writer that changes the file inside the window between that re-read and
      the rename still wins. That is the file system's semantics, not a bug:
      two concurrent edits that both bypass the seam can still lose one.

  `env[:edit_hook]` — an optional `(path, original_bytes -> any())` called
  immediately before the re-read — exists so a test can play the part of an
  external writer and make that detection fire deterministically.
  """

  @behaviour PurpleChonkyWhale.Tool

  alias PurpleChonkyWhale.Tool
  alias PurpleChonkyWhale.Tools.AtomicFile

  @bom "\xEF\xBB\xBF"

  @impl true
  def capabilities, do: [:fs_write]

  @impl true
  def schema do
    %{
      name: "edit",
      description:
        "Edit a file by replacing an exact string match. old_string must " <>
          "appear exactly once; include enough surrounding context for uniqueness. " <>
          "Line endings are matched flexibly (LF or CRLF both work).",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string", "description" => "Path to the file to edit"},
          "old_string" => %{
            "type" => "string",
            "description" => "Exact text to find (must be unique)"
          },
          "new_string" => %{"type" => "string", "description" => "Replacement text"}
        },
        "required" => ["file_path", "old_string", "new_string"]
      }
    }
  end

  @impl true
  def execute(%{"file_path" => file_path, "old_string" => old, "new_string" => new}, env)
      when is_binary(file_path) and is_binary(old) and is_binary(new) do
    cond do
      old == "" ->
        {:error, "old_string must not be empty"}

      old == new ->
        {:error, "old_string and new_string are identical"}

      true ->
        with {:ok, path} <- Tool.authorize_path(env, file_path, :write),
             {:ok, raw} <- read(path),
             {:ok, edited, note} <- replace_preserving(raw, old, new),
             :ok <- check_unchanged(path, raw, env),
             :ok <- AtomicFile.write(path, edited) do
          {:ok, "edited #{path}" <> note}
        end
    end
  end

  def execute(_args, _env) do
    {:error, "file_path, old_string and new_string are required strings"}
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, "file not found: #{path}"}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  # The `:tools` seam serializes concurrent writes to one path, but that cannot
  # stop another process — an editor, a test, a sibling agent — from rewriting
  # the file between our read and our write. Re-read and compare against the
  # bytes the edit was computed from: a whole-file write must never silently
  # discard a change it never saw. This narrows the window, it does not close
  # it (see the moduledoc); the rename in `AtomicFile.write/2` is what makes the
  # write itself all-or-nothing.
  defp check_unchanged(path, original, env) do
    fire_edit_hook(env, path, original)

    case File.read(path) do
      {:ok, ^original} ->
        :ok

      {:ok, _changed} ->
        {:error, "#{path} changed while the edit was prepared; re-read it and retry"}

      {:error, reason} ->
        {:error, "cannot re-read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp fire_edit_hook(env, path, original) when is_map(env) or is_list(env) do
    case Access.get(env, :edit_hook) do
      fun when is_function(fun, 2) ->
        _ = fun.(path, original)
        :ok

      _ ->
        :ok
    end
  end

  defp fire_edit_hook(_env, _path, _original), do: :ok

  ## The line-ending-aware replace

  defp replace_preserving(raw, old, new) do
    {bom, body} = split_bom(raw)
    eol = classify_eol(body)

    normalized = normalize_eol(body)
    old = normalize_eol(old)
    new = normalize_eol(new)

    case replace_exact(normalized, old, new) do
      {:ok, result, how} ->
        {:ok, bom <> restore_eol(result, eol), note(eol, how)}

      {:error, {:not_unique, n}} ->
        {:error, "old_string appears #{n} times; include more surrounding context"}

      {:error, :not_found} ->
        case replace_fuzzy(normalized, old, new) do
          {:ok, result} ->
            {:ok, bom <> restore_eol(result, eol), note(eol, :fuzzy)}

          {:error, :not_found} ->
            {:error, "old_string not found (also tried ignoring trailing whitespace)"}

          {:error, {:not_unique, n}} ->
            {:error, "old_string appears #{n} times; include more surrounding context"}
        end
    end
  end

  defp note(:lf, :exact), do: ""
  defp note(:crlf, :exact), do: " (CRLF preserved)"
  defp note(:lf, :fuzzy), do: " (matched ignoring trailing whitespace)"
  defp note(:crlf, :fuzzy), do: " (CRLF preserved; matched ignoring trailing whitespace)"

  defp note({:mixed, dominant}, _how),
    do: " (mixed line endings normalized to #{dominant_name(dominant)})"

  defp dominant_name(:lf), do: "LF"
  defp dominant_name(:crlf), do: "CRLF"

  defp split_bom(@bom <> rest), do: {@bom, rest}
  defp split_bom(text), do: {"", text}

  defp classify_eol(text) do
    crlf = text |> :binary.matches("\r\n") |> length()
    lf = (text |> :binary.matches("\n") |> length()) - crlf

    cond do
      crlf > 0 and lf > 0 -> {:mixed, if(crlf >= lf, do: :crlf, else: :lf)}
      crlf > 0 -> :crlf
      true -> :lf
    end
  end

  defp normalize_eol(text), do: String.replace(text, "\r\n", "\n")

  defp restore_eol(text, :crlf), do: String.replace(text, "\n", "\r\n")
  defp restore_eol(text, {:mixed, :crlf}), do: String.replace(text, "\n", "\r\n")
  defp restore_eol(text, _lf), do: text

  defp replace_exact(content, old, new) do
    case content |> :binary.matches(old) |> length() do
      0 -> {:error, :not_found}
      1 -> {:ok, :binary.replace(content, old, new), :exact}
      n -> {:error, {:not_unique, n}}
    end
  end

  # Line-window matching with trailing whitespace ignored; the replacement
  # splices only the matched lines, so the rest of the file is untouched.
  defp replace_fuzzy(content, old, new) do
    lines = String.split(content, "\n")
    width = length(String.split(old, "\n"))
    wanted = old |> String.split("\n") |> Enum.map(&String.trim_trailing/1)

    matches =
      lines
      |> Enum.chunk_every(width, 1, :discard)
      |> Enum.with_index()
      |> Enum.filter(fn {window, _i} -> Enum.map(window, &String.trim_trailing/1) == wanted end)
      |> Enum.map(&elem(&1, 1))

    case matches do
      [] ->
        {:error, :not_found}

      [index] ->
        result =
          Enum.take(lines, index) ++
            String.split(new, "\n") ++ Enum.drop(lines, index + width)

        {:ok, Enum.join(result, "\n")}

      many ->
        {:error, {:not_unique, length(many)}}
    end
  end
end
