defmodule DarkChonkyWhale.Tools.TodoAndSkillTest do
  use ExUnit.Case, async: false

  alias DarkChonkyWhale.Tools
  alias DarkChonkyWhale.Tools.{Skill, TodoWrite}
  alias Dexterous.Context

  setup do
    scope = :"todo_skill_test_#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), "dcw-todo-skill-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, ctx: Context.new(scope), scope: scope, dir: dir}
  end

  describe "TodoWrite" do
    test "validates todos, formats checklist, and emits tools/todo on the scope", %{
      ctx: ctx,
      scope: scope
    } do
      test_pid = self()

      {:ok, _} =
        Context.on(ctx, :"tools/todo", fn %{todos: todos} ->
          send(test_pid, {:todo_event, todos})
        end)

      registry = %Tools{
        tools: %{"todo_write" => TodoWrite},
        env: %{},
        scope: scope
      }

      args = %{
        "todos" => [
          %{"content" => "Inspect codebase", "status" => "completed"},
          %{"content" => "Write tests", "status" => "in_progress"},
          %{"content" => "Commit changes", "status" => "pending"}
        ]
      }

      assert {:ok, output} = Tools.execute(registry, "todo_write", args)
      assert output =~ "1 pending, 1 in progress, 1 completed"
      assert output =~ "[x] Inspect codebase"
      assert output =~ "[>] Write tests"
      assert output =~ "[ ] Commit changes"

      assert_received {:todo_event,
                       [
                         %{content: "Inspect codebase", status: "completed"},
                         %{content: "Write tests", status: "in_progress"},
                         %{content: "Commit changes", status: "pending"}
                       ]}
    end

    test "rejects malformed todos or invalid status" do
      assert {:error, "todos must be a list" <> _} = TodoWrite.execute(%{}, %{})

      assert {:error, "todo #1 content must not be empty"} =
               TodoWrite.execute(
                 %{"todos" => [%{"content" => "   ", "status" => "pending"}]},
                 %{}
               )

      assert {:error, "todo #1 has invalid status" <> _} =
               TodoWrite.execute(%{"todos" => [%{"content" => "do x", "status" => "done"}]}, %{})
    end
  end

  describe "Skill" do
    test "discovers SKILL.md catalog, builds prompt_section, and loads full skill content", %{
      dir: dir
    } do
      primary = Path.join(dir, "workspace_skills")
      fallback = Path.join(dir, "global_skills")

      write_skill(primary, "grill-me", """
      ---
      name: grill-me
      description: "Interview the user about a design."
      ---
      # Grill Me Instructions
      Ask one question at a time.
      """)

      # Earlier skill_dirs win on name collision; unique skills from later dirs are included.
      write_skill(fallback, "grill-me", """
      ---
      name: grill-me
      description: "Shadowed description"
      ---
      Shadowed body
      """)

      write_skill(fallback, "orchid", """
      ---
      name: elixir-orchid-workflow
      description: Declarative pipeline architect
      ---
      # Orchid Guide
      Use recipes and steps.
      """)

      env = %{cwd: dir, skill_dirs: [primary, fallback]}

      catalog = Skill.catalog(env)
      assert Enum.map(catalog, & &1.name) == ["elixir-orchid-workflow", "grill-me"]

      prompt = Skill.prompt_section(env)
      assert prompt =~ "<available_skills>"
      assert prompt =~ "- `grill-me`: Interview the user about a design."
      assert prompt =~ "- `elixir-orchid-workflow`: Declarative pipeline architect"
      refute prompt =~ "Shadowed description"

      assert {:ok, loaded} = Skill.execute(%{"name" => "grill-me"}, env)
      assert loaded =~ "<skill_content name=\"grill-me\""
      assert loaded =~ "# Grill Me Instructions"
      refute loaded =~ "Shadowed body"

      assert {:error, msg} = Skill.execute(%{"name" => "nonexistent"}, env)
      assert msg =~ "unknown skill \"nonexistent\""
      assert msg =~ "elixir-orchid-workflow, grill-me"
    end
  end

  defp write_skill(base_dir, folder, content) do
    skill_dir = Path.join(base_dir, folder)
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), content)
  end
end
