defmodule PurpleChonkyWhale.Tools.MemoryUpdate do
  @moduledoc """
  The `memory_update` tool: rewrite existing memory lines. Takes a list of
  updates (a single edit is a one-element list, so one call covers both
  update and update-many); the call is atomic — an unmatched `match` fails
  the whole call and changes nothing. See `PurpleChonkyWhale.Memory.update_many/2`.
  """

  @behaviour PurpleChonkyWhale.Tool

  alias PurpleChonkyWhale.{Memory, Tools}

  @impl true
  def schema do
    %{
      name: "memory_update",
      description:
        "Rewrite long-term memory lines. Each update replaces every line containing `match` with one dated `replacement` line. Atomic: an unmatched `match` fails the whole call.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "updates" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "match" => %{
                  "type" => "string",
                  "description" => "Substring of the existing line(s) to replace"
                },
                "replacement" => %{"type" => "string", "description" => "The new line content"}
              },
              "required" => ["match", "replacement"]
            }
          }
        },
        "required" => ["updates"]
      }
    }
  end

  @impl true
  def execute(%{"updates" => updates}, env) when is_list(updates) and updates != [] do
    if Enum.all?(updates, &valid_update?/1) do
      with {:ok, memory} <- Tools.MemorySave.fetch_memory(env),
           {:ok, %{updated: count}} <- Memory.update_many(memory, updates) do
        {:ok, "updated #{count} memory #{n(count)}"}
      else
        {:error, %{message: message}} -> {:error, message}
      end
    else
      {:error, "each update needs non-empty string \"match\" and \"replacement\" keys"}
    end
  end

  def execute(_args, _env), do: {:error, "missing required argument: updates (a non-empty list)"}

  defp valid_update?(%{"match" => match, "replacement" => replacement})
       when is_binary(match) and is_binary(replacement),
       do: String.trim(match) != "" and String.trim(replacement) != ""

  defp valid_update?(_), do: false

  defp n(1), do: "line"
  defp n(_), do: "lines"
end
