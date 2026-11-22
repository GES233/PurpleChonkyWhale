defmodule DarkChonkyWhale.Tools.TodoWrite do
  @statuses ~w(pending in_progress completed)

  @moduledoc """
  The `todo_write` tool: record and update the task checklist for multi-step
  work so the model keeps an explicit plan in the session log and the host
  can display progress.

  Each call replaces the previous checklist with the complete `todos` list.
  Valid statuses are `#{inspect(@statuses)}`.

  When `env[:scope]` is present, the updated list is also broadcast on the
  scope's event bus as `:"tools/todo"` with `%{todos: [%{content:, status:}]}`.
  """

  @behaviour DarkChonkyWhale.Tool

  alias Dexterous.Context

  @todo_event :"tools/todo"

  @impl true
  def schema do
    %{
      name: "todo_write",
      description:
        "Record and update a task list to plan multi-step work and show progress; " <>
          "skip it for trivial single-step tasks. Pass the COMPLETE task list each " <>
          "time, marking items `in_progress` while working on them and `completed` " <>
          "as soon as they are done.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "todos" => %{
            "type" => "array",
            "description" => "The complete task list, replacing any previous list.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "content" => %{
                  "type" => "string",
                  "description" => "Short imperative description of the step."
                },
                "status" => %{
                  "type" => "string",
                  "enum" => @statuses,
                  "description" => "pending | in_progress | completed"
                }
              },
              "required" => ["content", "status"]
            }
          }
        },
        "required" => ["todos"]
      }
    }
  end

  @impl true
  def execute(%{"todos" => todos}, env) when is_list(todos) do
    with {:ok, normalized} <- validate_todos(todos) do
      maybe_emit(env, normalized)
      {:ok, render(normalized)}
    end
  end

  def execute(_args, _env), do: {:error, "todos must be a list of task objects"}

  defp validate_todos(todos) do
    todos
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {item, idx}, {:ok, acc} ->
      case validate_item(item, idx) do
        {:ok, todo} -> {:cont, {:ok, [todo | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      error -> error
    end
  end

  defp validate_item(%{"content" => content, "status" => status}, idx)
       when is_binary(content) and is_binary(status) do
    trimmed = String.trim(content)

    cond do
      trimmed == "" ->
        {:error, "todo ##{idx} content must not be empty"}

      status not in @statuses ->
        {:error,
         "todo ##{idx} has invalid status #{inspect(status)}; expected one of #{Enum.join(@statuses, ", ")}"}

      true ->
        {:ok, %{content: trimmed, status: status}}
    end
  end

  defp validate_item(_other, idx) do
    {:error, "todo ##{idx} must be an object with string \"content\" and \"status\""}
  end

  defp maybe_emit(env, todos) do
    case env[:scope] do
      nil ->
        :ok

      scope ->
        ctx = Context.new(scope)

        Context.emit(ctx, @todo_event, %{
          todos: todos,
          session_id: env[:session_id],
          run_id: env[:run_id],
          tool_call_id: env[:tool_call_id]
        })
    end
  end

  defp render([]), do: "Updated todo list: (empty)"

  defp render(todos) do
    counts = Enum.frequencies_by(todos, & &1.status)
    pending = Map.get(counts, "pending", 0)
    in_progress = Map.get(counts, "in_progress", 0)
    completed = Map.get(counts, "completed", 0)

    header =
      "Updated todo list: #{pending} pending, #{in_progress} in progress, #{completed} completed."

    lines =
      Enum.map(todos, fn %{content: content, status: status} ->
        "#{marker(status)} #{content}"
      end)

    Enum.join([header | lines], "\n")
  end

  defp marker("completed"), do: "[x]"
  defp marker("in_progress"), do: "[>]"
  defp marker(_pending), do: "[ ]"
end
