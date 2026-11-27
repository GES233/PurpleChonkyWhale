defmodule PurpleChonkyWhale.Tools.MemorySave do
  @moduledoc """
  The `memory_save` tool: append a durable note to the composition's memory.

  The tool reaches the `:memory` coeffect through the scope carried in the
  tools env (`PurpleChonkyWhale.Tools` puts `:scope` into every call's env),
  and delegates to `PurpleChonkyWhale.Memory.remember/2` — which writes to the
  innermost writable layer. Without a `:memory` seam mounted, the tool
  answers with an explanatory error.
  """

  @behaviour PurpleChonkyWhale.Tool

  alias PurpleChonkyWhale.Memory
  alias Dexterous.Context

  @impl true
  def capabilities, do: [:memory]

  @impl true
  def schema do
    %{
      name: "memory_save",
      description:
        "Save a durable note to long-term memory (one line). Use for facts, preferences or decisions that should survive this session.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "content" => %{"type" => "string", "description" => "The note to remember, one line"}
        },
        "required" => ["content"]
      }
    }
  end

  @impl true
  def execute(%{"content" => content}, env) do
    with :present <- non_empty(content),
         {:ok, memory} <- fetch_memory(env),
         {:ok, path} <- Memory.remember(memory, content) do
      {:ok, "remembered in #{path}"}
    else
      :empty -> {:error, "content must not be empty"}
      {:error, _} = error -> error
    end
  end

  def execute(_args, _env), do: {:error, "missing required argument: content"}

  @doc false
  def fetch_memory(env) do
    with %{scope: scope} when not is_nil(scope) <- env,
         {:ok, memory} <- Context.get(Context.new(scope), :memory) do
      {:ok, memory}
    else
      _ -> {:error, %{message: "no memory layer configured for this composition"}}
    end
  end

  defp non_empty(content) when is_binary(content) do
    if String.trim(content) == "", do: :empty, else: :present
  end

  defp non_empty(_content), do: :empty
end
