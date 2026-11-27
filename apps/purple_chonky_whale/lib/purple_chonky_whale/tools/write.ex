defmodule PurpleChonkyWhale.Tools.Write do
  @moduledoc """
  The `write` tool: create a file or completely overwrite an existing one,
  creating parent directories as needed.
  """

  @behaviour PurpleChonkyWhale.Tool

  alias PurpleChonkyWhale.Tool

  @impl true
  def capabilities, do: [:fs_write]

  @impl true
  def schema do
    %{
      name: "write",
      description:
        "Create a new file or completely overwrite an existing one. " <>
          "Parent directories are created as needed.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string", "description" => "Path for the file"},
          "content" => %{"type" => "string", "description" => "Full file content to write"}
        },
        "required" => ["file_path", "content"]
      }
    }
  end

  @impl true
  def execute(args, env) do
    content = args["content"] || ""

    with {:ok, path} <- Tool.authorize_path(env, args["file_path"], :write),
         :ok <- mkdir_p(Path.dirname(path)),
         :ok <- write_file(path, content) do
      lines = content |> String.split("\n") |> length()
      {:ok, "wrote #{lines} lines to #{path}"}
    end
  end

  defp mkdir_p(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot create directory #{dir}: #{:file.format_error(reason)}"}
    end
  end

  defp write_file(path, content) do
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end
end
