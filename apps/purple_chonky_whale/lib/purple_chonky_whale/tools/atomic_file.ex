defmodule PurpleChonkyWhale.Tools.AtomicFile do
  @moduledoc """
  Whole-file writes that replace the target atomically.

  A plain `File.write/2` truncates first, so a concurrent reader can observe a
  half-written file and a crash in the middle leaves the target empty or
  truncated. `write/2` instead writes the content to a temp file in the *same
  directory*, copies the target's permission bits when it already exists, and
  renames the temp file over the target — a rename is atomic, so a reader sees
  the complete old content or the complete new one, and a crash leaves the
  target untouched (at worst a stray temp file).

  The physical target of a symlink is what gets replaced, so writing through a
  link edits the file it points at, exactly as a plain write would. A failed
  write never leaves the temp file behind.
  """

  alias PurpleChonkyWhale.Security.PathGuard

  @doc """
  Replace `path` with `content`. Returns `:ok` or `{:error, message}`.

  The write is all-or-nothing for the reader: either the old bytes or the new
  ones are visible at `path`, never a mix and never an empty file.
  """
  @spec write(Path.t(), iodata()) :: :ok | {:error, String.t()}
  def write(path, content) when is_binary(path) do
    target = physical(path)
    tmp = temp_path(target)

    with :ok <- write_tmp(tmp, content) do
      case replace(tmp, target) do
        :ok ->
          :ok

        {:error, _} = error ->
          _ = File.rm(tmp)
          error
      end
    end
  end

  # Resolve symlinks so the rename lands on the file the path designates rather
  # than replacing the link itself. `realpath/1` also normalizes the deepest
  # existing ancestor, which is all a new file needs.
  defp physical(path) do
    case PathGuard.realpath(path) do
      {:ok, resolved} -> resolved
      {:error, _} -> path
    end
  end

  defp temp_path(target) do
    dir = Path.dirname(target)
    base = Path.basename(target)
    Path.join(dir, ".#{base}.pcw-tmp-#{System.unique_integer([:positive, :monotonic])}")
  end

  # `:sync` costs one fsync, and it is the point of this module: without it the
  # rename can be durable while the bytes it points at are still only in the
  # page cache.
  defp write_tmp(tmp, content) do
    case File.write(tmp, content, [:sync]) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, "cannot write #{tmp}: #{:file.format_error(reason)}"}
    end
  end

  # Editing an executable script must not silently drop its mode bits: the
  # rename installs a brand-new file, which would otherwise carry whatever the
  # umask-derived default is. Best effort — a platform that cannot chmod is not
  # a reason to refuse the write.
  defp copy_mode(target, tmp) do
    case File.stat(target) do
      {:ok, %File.Stat{mode: mode}} when is_integer(mode) ->
        _ = File.chmod(tmp, Bitwise.band(mode, 0o7777))
        :ok

      _ ->
        :ok
    end
  end

  defp replace(tmp, target) do
    with :ok <- copy_mode(target, tmp) do
      case File.rename(tmp, target) do
        :ok -> :ok
        {:error, reason} -> {:error, "cannot replace #{target}: #{:file.format_error(reason)}"}
      end
    end
  end
end
