defmodule PurpleChonkyWhale.Tools.WriteConcurrencyTest do
  use ExUnit.Case, async: true

  alias PurpleChonkyWhale.Tools
  alias PurpleChonkyWhale.Tools.{AtomicFile, Edit, Write}
  alias Dexterous.Context

  defmodule DeclaredTarget do
    @moduledoc false
    @behaviour PurpleChonkyWhale.Tool

    @impl true
    def schema,
      do: %{name: "declared_write", description: "Writes args[\"dest\"]", parameters: %{}}

    @impl true
    def capabilities, do: [:fs_write]

    # The target lives under a name the seam's default inference would never
    # guess (`file_path` / `path`), so this call is protected only if the seam
    # asks the tool.
    @impl true
    def write_target(%{"dest" => dest}, _env) when is_binary(dest), do: {:ok, dest}
    def write_target(_args, _env), do: :none

    # Records overlap: the probe row is taken on entry and released on exit, so
    # failing to take it means another call was already inside.
    @impl true
    def execute(%{"dest" => dest, "content" => content}, env) do
      overlap? = :ets.insert_new(env.probe, {:busy, self()}) == false
      Process.sleep(40)
      File.write!(dest, content)
      :ets.delete(env.probe, :busy)
      {:ok, if(overlap?, do: "overlapped", else: "alone")}
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "pcw-write-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, dir: dir}
  end

  defp compose(dir, tools, extra_env \\ %{}) do
    scope = :"pcw_write_test_#{System.unique_integer([:positive])}"
    ctx = Context.new(scope)

    {:ok, _fiber} = Context.use(ctx, Tools, tools: tools, env: Map.put(extra_env, :cwd, dir))

    await_registry(ctx, 400) || flunk(":tools was not bound in time")
  end

  defp await_registry(_ctx, 0), do: nil

  defp await_registry(ctx, attempts) do
    case Context.get(ctx, :tools) do
      {:ok, registry} ->
        registry

      :error ->
        Process.sleep(5)
        await_registry(ctx, attempts - 1)
    end
  end

  defp temp_files(dir) do
    dir |> Path.join(".*pcw-tmp*") |> Path.wildcard()
  end

  # The regression this fixes: a batch of tool calls runs concurrently, each
  # `edit` reads the whole file, changes its own match and writes the whole
  # file back — so overlapping edits erased each other while every call
  # reported `{:ok, "edited ..."}`. The seam serializes writes per target.
  test "concurrent edits through the seam never lose a change", %{dir: dir} do
    registry = compose(dir, [Edit, Write])
    path = Path.join(dir, "note.txt")
    File.write!(path, Enum.map_join(1..8, "\n", &"line#{&1}") <> "\n")

    results =
      1..8
      |> Enum.map(fn i ->
        Task.async(fn ->
          Tools.execute(registry, "edit", %{
            "file_path" => path,
            "old_string" => "line#{i}",
            "new_string" => "edited#{i}"
          })
        end)
      end)
      |> Enum.map(&Task.await(&1, 10_000))

    assert Enum.all?(results, &match?({:ok, _}, &1)),
           "expected every edit to succeed, got: #{inspect(results)}"

    content = File.read!(path)
    for i <- 1..8, do: assert(content =~ "edited#{i}", "lost edit ##{i}: #{inspect(content)}")
    assert temp_files(dir) == []
  end

  test "concurrent writes to different paths still all land", %{dir: dir} do
    registry = compose(dir, [Edit, Write])

    results =
      1..6
      |> Enum.map(fn i ->
        Task.async(fn ->
          Tools.execute(registry, "write", %{
            "file_path" => Path.join(dir, "out#{i}.txt"),
            "content" => "payload #{i}\n"
          })
        end)
      end)
      |> Enum.map(&Task.await(&1, 10_000))

    assert Enum.all?(results, &match?({:ok, _}, &1))

    for i <- 1..6 do
      assert File.read!(Path.join(dir, "out#{i}.txt")) == "payload #{i}\n"
    end

    assert temp_files(dir) == []
  end

  test "a declared write target is serialized even when the argument is not file_path",
       %{dir: dir} do
    probe = :ets.new(:pcw_write_probe, [:set, :public])

    registry = compose(dir, [DeclaredTarget], %{probe: probe})

    results =
      1..4
      |> Enum.map(fn i ->
        Task.async(fn ->
          Tools.execute(registry, "declared_write", %{
            "dest" => Path.join(dir, "shared.txt"),
            "content" => "payload #{i}\n"
          })
        end)
      end)
      |> Enum.map(&Task.await(&1, 10_000))

    assert Enum.all?(results, &match?({:ok, "alone"}, &1)),
           "calls overlapped, they were not serialized: #{inspect(results)}"
  end

  # Detection is best effort, so the test makes it deterministic: `edit_hook`
  # runs right before the re-read and plays an external writer that wins the
  # race. The edit must refuse — and must leave the external bytes alone rather
  # than install a version computed from the stale snapshot.
  test "an edit whose file changed underneath is refused, not silently applied",
       %{dir: dir} do
    path = Path.join(dir, "raced.txt")
    File.write!(path, "alpha\noriginal body\nomega\n")

    env = %{
      cwd: dir,
      edit_hook: fn ^path, _original ->
        File.write!(path, "alpha\nsomeone else was here\nomega\n")
      end
    }

    assert {:error, message} =
             Edit.execute(
               %{"file_path" => path, "old_string" => "original body", "new_string" => "mine"},
               env
             )

    assert message =~ "changed while the edit was prepared"
    assert File.read!(path) == "alpha\nsomeone else was here\nomega\n"
    assert temp_files(dir) == []
  end

  # Replacement is a rename, so a reader must never observe a half-written
  # file: every read is a complete old body or a complete new one.
  test "a replaced file is never observable half-written", %{dir: dir} do
    path = Path.join(dir, "atomic.txt")
    old_body = String.duplicate("old line\n", 2_000)
    new_body = String.duplicate("new line\n", 2_000)
    assert :ok = AtomicFile.write(path, old_body)

    reader =
      Task.async(fn ->
        Enum.reduce(1..300, MapSet.new(), fn _, seen ->
          case File.read(path) do
            {:ok, content} -> MapSet.put(seen, content)
            {:error, reason} -> MapSet.put(seen, {:unreadable, reason})
          end
        end)
      end)

    for i <- 1..50 do
      body = if rem(i, 2) == 0, do: new_body, else: old_body
      assert :ok = AtomicFile.write(path, body)
    end

    seen = Task.await(reader, 60_000)

    assert MapSet.subset?(seen, MapSet.new([old_body, new_body])),
           "a reader saw something that was neither version: " <>
             inspect(Enum.map(seen, &describe_read/1))

    assert temp_files(dir) == []
  end

  defp describe_read(content) when is_binary(content), do: {:binary, byte_size(content)}
  defp describe_read(other), do: other
end
