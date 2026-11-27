defmodule PurpleChonkyWhale.Tools.MemoryDelete do
  @moduledoc """
  The `memory_delete` tool: remove long-term memory lines containing a match
  substring. See `PurpleChonkyWhale.Memory.delete/2`.
  """

  @behaviour PurpleChonkyWhale.Tool

  alias PurpleChonkyWhale.Memory
  alias PurpleChonkyWhale.Tools.MemorySave

  @impl true
  def capabilities, do: [:memory]

  @impl true
  def schema do
    %{
      name: "memory_delete",
      description:
        "Delete long-term memory lines: every line containing `match` is removed. Fails when nothing matches.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "match" => %{
            "type" => "string",
            "description" => "Substring of the line(s) to delete"
          }
        },
        "required" => ["match"]
      }
    }
  end

  @impl true
  def execute(%{"match" => match}, env) when is_binary(match) do
    if String.trim(match) == "" do
      {:error, "match must not be empty"}
    else
      with {:ok, memory} <- MemorySave.fetch_memory(env),
           {:ok, %{deleted: count}} <- Memory.delete(memory, match) do
        {:ok, "deleted #{count} memory #{n(count)}"}
      else
        {:error, %{message: message}} -> {:error, message}
      end
    end
  end

  def execute(_args, _env), do: {:error, "missing required argument: match"}

  defp n(1), do: "line"
  defp n(_), do: "lines"
end
