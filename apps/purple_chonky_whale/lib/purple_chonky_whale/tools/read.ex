defmodule PurpleChonkyWhale.Tools.Read do
  @moduledoc """
  The `read` tool: read a file's contents with line numbers, one page at a
  time — or, for image files, return the image itself as a content part.

  The display is LF-normalized (CRLF files show without the `\\r`), so what
  the model sees is exactly the view the `edit` tool matches against. Bytes
  that are not valid UTF-8 (e.g. GBK-encoded files) show as the replacement
  character.

  Image files (png / jpeg / gif / webp) come back as a `{:parts, ...}` output
  carrying the raw image; the session log stores the bytes as a blob. Images
  over 5 MB are refused with a hint to downscale. When the environment
  carries `vision?: false` (the configured model has no image input), the
  tool answers with a text description of the file instead of the image.

  Before the bytes leave the tool they pass a structural check (see
  `valid_image_data?/2`): a file that fails it is answered with the same
  text description plus a corrupt/truncated note. Undecodable bytes must
  never enter the session log — the image rides along on every later
  request, and one bad image makes the provider reject the whole payload.
  """

  @behaviour PurpleChonkyWhale.Tool

  alias PurpleChonkyWhale.{Tool, ToolResult}

  @max_image_bytes 5 * 1024 * 1024

  @png_signature <<137, 80, 78, 71, 13, 10, 26, 10>>
  # The IEND chunk has a fixed payload (none), so its CRC is a constant.
  @png_iend <<0, 0, 0, 0, "IEND", 0xAE, 0x42, 0x60, 0x82>>

  @image_media_types %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp"
  }

  @impl true
  def schema do
    %{
      name: "read",
      description:
        "Read a file's contents with line numbers. Image files (png, jpeg, gif, webp) are returned as viewable images.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string", "description" => "Path to the file"},
          "offset" => %{
            "type" => "integer",
            "description" => "Start line (1-based). Default 1."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Max lines to read. Default 2000."
          }
        },
        "required" => ["file_path"]
      }
    }
  end

  @impl true
  def execute(args, env) do
    path = Tool.resolve_path(env, args["file_path"])

    case image_media_type(path) do
      {:ok, media_type} -> read_image(path, media_type, env)
      :error -> read_text(path, args)
    end
  end

  @doc """
  `{:ok, media_type}` when `path`'s extension names a supported image format
  (case-insensitive), `:error` otherwise. Shared with callers that attach
  images to user messages (e.g. the Noctilucent CLI).
  """
  @spec image_media_type(String.t()) :: {:ok, String.t()} | :error
  def image_media_type(path) do
    Map.fetch(@image_media_types, path |> Path.extname() |> String.downcase())
  end

  @doc "The maximum image payload the tool will return, in bytes."
  @spec max_image_bytes() :: non_neg_integer()
  def max_image_bytes, do: @max_image_bytes

  @doc """
  Whether `data` is a structurally complete image of `media_type`: PNG needs
  its signature plus a trailing IEND chunk, JPEG its SOI/EOI markers, GIF a
  `GIF87a`/`GIF89a` header plus the trailer byte, WebP a RIFF/WEBP header.
  This is not a full decode — it catches the corrupt or truncated files a
  provider would reject. Shared with callers that attach images to user
  messages (e.g. the Noctilucent CLI).
  """
  @spec valid_image_data?(binary(), String.t()) :: boolean()
  def valid_image_data?(data, media_type)

  def valid_image_data?(data, "image/png") do
    String.starts_with?(data, @png_signature) and String.ends_with?(data, @png_iend)
  end

  def valid_image_data?(data, "image/jpeg") do
    String.starts_with?(data, <<0xFF, 0xD8>>) and String.ends_with?(data, <<0xFF, 0xD9>>)
  end

  def valid_image_data?(data, "image/gif") do
    (String.starts_with?(data, "GIF87a") or String.starts_with?(data, "GIF89a")) and
      String.ends_with?(data, <<0x3B>>)
  end

  def valid_image_data?(data, "image/webp") do
    byte_size(data) >= 12 and binary_part(data, 0, 4) == "RIFF" and
      binary_part(data, 8, 4) == "WEBP"
  end

  defp read_text(path, args) do
    offset = max(1, Map.get(args, "offset", 1))
    limit = max(1, Map.get(args, "limit", 2000))

    case File.read(path) do
      {:ok, text} ->
        {:ok, text |> String.replace_invalid() |> normalize_eol() |> page(offset, limit)}

      {:error, :enoent} ->
        {:error, "file not found: #{path}"}

      {:error, :eisdir} ->
        {:error, "not a file: #{path}"}

      {:error, reason} ->
        {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp read_image(path, media_type, env) do
    if env[:vision?] == false do
      {:ok, describe_image(path, media_type)}
    else
      with {:ok, size} <- image_size(path),
           :ok <- check_image_size(path, size),
           {:ok, data} <- File.read(path) do
        if valid_image_data?(data, media_type) do
          {:ok,
           {:parts,
            [
              ToolResult.image_part(data, media_type),
              ToolResult.text_part(describe_image(path, media_type, size))
            ]}}
        else
          {:ok, describe_invalid_image(path, media_type, size)}
        end
      else
        {:error, :enoent} ->
          {:error, "file not found: #{path}"}

        {:error, :eisdir} ->
          {:error, "not a file: #{path}"}

        {:error, reason} when is_atom(reason) ->
          {:error, "cannot read #{path}: #{:file.format_error(reason)}"}

        {:error, message} when is_binary(message) ->
          {:error, message}
      end
    end
  end

  defp image_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_image_size(path, size) when size > @max_image_bytes do
    {:error,
     "image is #{Float.round(size / 1_048_576, 1)} MB, over the #{div(@max_image_bytes, 1_048_576)} MB limit (#{path}); downscale or crop it first"}
  end

  defp check_image_size(_path, _size), do: :ok

  defp describe_invalid_image(path, media_type, size) do
    describe_image(path, media_type, size) <>
      " (corrupt or truncated: not a complete #{media_type} image, so only this description is shown)"
  end

  defp describe_image(path, media_type, size \\ nil) do
    size_note =
      case size || image_size(path) do
        {:ok, bytes} -> ", #{bytes} bytes"
        bytes when is_integer(bytes) -> ", #{bytes} bytes"
        _ -> ""
      end

    "[image #{media_type}#{size_note}] #{path}"
  end

  defp normalize_eol(text), do: String.replace(text, "\r\n", "\n")

  defp page("", _offset, _limit), do: "(empty file)"

  defp page(text, offset, limit) do
    lines = String.split(text, "\n")
    total = length(lines)
    chunk = lines |> Enum.drop(offset - 1) |> Enum.take(limit)

    case chunk do
      [] ->
        "(offset #{offset} is past the end; #{total} lines total)"

      _ ->
        numbered =
          chunk
          |> Enum.with_index(offset)
          |> Enum.map_join("\n", fn {line, n} -> "#{n}\t#{line}" end)

        if offset - 1 + length(chunk) < total do
          numbered <>
            "\n... (#{total} lines total, showing #{offset}-#{offset + length(chunk) - 1})"
        else
          numbered
        end
    end
  end
end
