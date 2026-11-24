defmodule PurpleChonkyWhale.MemoryTest do
  use ExUnit.Case, async: false

  alias PurpleChonkyWhale.{Memory, Tools}
  alias Dexterous.Context

  setup do
    scope = :"memory_test_#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), "pcw-memory-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, ctx: Context.new(scope), scope: scope, dir: dir}
  end

  defp start_memory(ctx, layers) do
    {:ok, _fiber} = Context.use(ctx, Memory, layers: layers)

    Enum.reduce_while(1..50, nil, fn _, _ ->
      case Context.get(ctx, :memory) do
        {:ok, memory} -> {:halt, memory}
        :error -> {:cont, Process.sleep(10)}
      end
    end) || raise ":memory was not bound in time"
  end

  describe "recall/1" do
    test "concatenates layers most-specific-first, skipping empty ones", %{ctx: ctx, dir: dir} do
      persona = Path.join(dir, "persona")
      global = Path.join(dir, "global")
      File.mkdir_p!(persona)
      File.mkdir_p!(global)
      File.write!(Path.join(persona, "MEMORY.md"), "- [2026-11-24] likes tea\n")
      File.write!(Path.join(global, "MEMORY.md"), "- [2026-01-01] be kind\n")

      memory =
        start_memory(ctx, [
          {:persona, persona, writable: true},
          {:empty, Path.join(dir, "nope"), writable: false},
          {:global, global, writable: false}
        ])

      text = Memory.recall(memory)
      assert text =~ "## Memory — persona"
      assert text =~ "likes tea"
      assert text =~ "## Memory — global"
      assert text =~ "be kind"
      refute text =~ "## Memory — empty"
      assert text =~ ~r/persona[\s\S]*global/
    end

    test "caps an overlong layer with a truncation note", %{ctx: ctx, dir: dir} do
      persona = Path.join(dir, "persona")
      File.mkdir_p!(persona)
      File.write!(Path.join(persona, "MEMORY.md"), String.duplicate("x", 5_000))

      memory = start_memory(ctx, [{:persona, persona, writable: true}])

      text = Memory.recall(memory)
      assert text =~ "memory truncated"
      assert byte_size(text) < 5_000
    end

    test "no layers with content recalls an empty string", %{ctx: ctx, dir: dir} do
      memory = start_memory(ctx, [{:persona, Path.join(dir, "empty"), writable: true}])
      assert Memory.recall(memory) == ""
    end
  end

  describe "remember/2" do
    test "writes one dated line to the innermost writable layer", %{ctx: ctx, dir: dir} do
      persona = Path.join(dir, "persona")
      global = Path.join(dir, "global")

      memory =
        start_memory(ctx, [
          {:persona, persona, writable: true},
          {:global, global, writable: false}
        ])

      assert {:ok, path} = Memory.remember(memory, "prefers dark mode")
      assert path == Path.join(Path.expand(persona), "MEMORY.md")
      assert File.read!(path) =~ ~r/^- \[\d{4}-\d{2}-\d{2}\] prefers dark mode$/m
      refute File.exists?(Path.join(global, "MEMORY.md"))

      # A second note appends, and recall sees it.
      assert {:ok, _} = Memory.remember(memory, "uses vim")
      assert Memory.recall(memory) =~ "uses vim"
    end

    test "a composition with no writable layer answers a typed error", %{ctx: ctx, dir: dir} do
      memory = start_memory(ctx, [{:global, dir, writable: false}])

      assert {:error, %{type: :no_writable_layer}} = Memory.remember(memory, "note")
    end
  end

  describe "the memory_save tool" do
    test "writes through the scope's :memory coeffect", %{ctx: ctx, scope: scope, dir: dir} do
      _memory = start_memory(ctx, [{:persona, Path.join(dir, "persona"), writable: true}])

      registry = %Tools{tools: %{"memory_save" => Tools.Memory}, env: %{}, scope: scope}

      assert {:ok, output} =
               Tools.execute(registry, "memory_save", %{"content" => "tea > coffee"})

      assert output =~ "remembered in"
      assert File.read!(Path.join(dir, "persona/MEMORY.md")) =~ "tea > coffee"
    end

    test "fails cleanly without a memory seam or with empty content", %{scope: scope} do
      registry = %Tools{tools: %{"memory_save" => Tools.Memory}, env: %{}, scope: scope}

      assert {:error, %{message: message}} =
               Tools.execute(registry, "memory_save", %{"content" => "note"})

      assert message =~ "no memory layer configured"

      assert {:error, "content must not be empty"} =
               Tools.Memory.execute(%{"content" => "  "}, %{})
    end
  end

  describe "update_many/2 and delete/2" do
    setup %{ctx: ctx, dir: dir} do
      persona = Path.join(dir, "persona")

      memory = start_memory(ctx, [{:persona, persona, writable: true}])
      {:ok, _} = Memory.remember(memory, "prefers tea over coffee")
      {:ok, _} = Memory.remember(memory, "uses vim")
      {:ok, _} = Memory.remember(memory, "dark mode on all machines")

      %{memory: memory, path: Path.join(Path.expand(persona), "MEMORY.md")}
    end

    test "update rewrites matching lines with a fresh date", %{memory: memory, path: path} do
      assert {:ok, %{updated: 1}} =
               Memory.update_many(memory, [
                 %{"match" => "tea over coffee", "replacement" => "prefers coffee over tea"}
               ])

      content = File.read!(path)
      assert content =~ ~r/^- \[\d{4}-\d{2}-\d{2}\] prefers coffee over tea$/m
      refute content =~ "prefers tea over coffee"
      assert content =~ "uses vim"
    end

    test "an unmatched update fails the whole call and writes nothing", %{
      memory: memory,
      path: path
    } do
      before = File.read!(path)

      assert {:error, %{type: :no_match, match: "nope"}} =
               Memory.update_many(memory, [
                 %{"match" => "vim", "replacement" => "uses emacs"},
                 %{"match" => "nope", "replacement" => "x"}
               ])

      assert File.read!(path) == before
    end

    test "delete removes every matching line and reports the count", %{
      memory: memory,
      path: path
    } do
      {:ok, _} = Memory.remember(memory, "dark mode also in the terminal")

      assert {:ok, %{deleted: 2}} = Memory.delete(memory, "dark mode")
      refute File.read!(path) =~ "dark mode"
      assert File.read!(path) =~ "uses vim"

      assert {:error, %{type: :no_match}} = Memory.delete(memory, "dark mode")
    end
  end

  describe "the memory_update and memory_delete tools" do
    setup %{ctx: ctx, scope: scope, dir: dir} do
      _memory = start_memory(ctx, [{:persona, Path.join(dir, "persona"), writable: true}])

      registry = %Tools{
        tools: %{
          "memory_save" => Tools.Memory,
          "memory_update" => Tools.MemoryUpdate,
          "memory_delete" => Tools.MemoryDelete
        },
        env: %{},
        scope: scope
      }

      {:ok, _} = Tools.execute(registry, "memory_save", %{"content" => "likes green tea"})

      %{registry: registry}
    end

    test "update and delete go through the pipeline", %{registry: registry} do
      assert {:ok, "updated 1 memory line"} =
               Tools.execute(registry, "memory_update", %{
                 "updates" => [%{"match" => "green tea", "replacement" => "likes black tea"}]
               })

      assert {:ok, "deleted 1 memory line"} =
               Tools.execute(registry, "memory_delete", %{"match" => "black tea"})
    end

    test "malformed calls and unmatched edits are clean errors", %{registry: registry} do
      assert {:error, message} = Tools.execute(registry, "memory_update", %{"updates" => []})
      assert message =~ "non-empty list"

      assert {:error, message} =
               Tools.execute(registry, "memory_update", %{
                 "updates" => [%{"match" => "green", "replacement" => "  "}]
               })

      assert message =~ "non-empty string"

      assert {:error, message} =
               Tools.execute(registry, "memory_update", %{
                 "updates" => [%{"match" => "nothing like this", "replacement" => "x"}]
               })

      assert message =~ "no memory line contains"

      assert {:error, "match must not be empty"} =
               Tools.execute(registry, "memory_delete", %{"match" => " "})
    end
  end
end
