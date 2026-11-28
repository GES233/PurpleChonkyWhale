defmodule Nacreous.PresetsTest do
  use ExUnit.Case, async: false

  alias Dexterous.Context
  alias Nacreous.Presets
  alias PurpleChonkyWhale.Tools

  @moduletag :tmp_dir

  test "the work preset mounts Clearance with a headless asker" do
    entries = Presets.entries(cwd: File.cwd!())

    assert Enum.map(entries, & &1.id) == [:llm, :sessions, :sandbox, :tools, :memory, :policy]

    policy = Enum.find(entries, &(&1.id == :policy))

    assert policy.component == Clearance.Component
    assert policy.config[:asker] == Clearance.Asker.DenyAll
    assert policy.config[:lint_tools] == ["execute"]
    assert is_function(policy.config[:lint], 2)
  end

  test "the shared lint and lease semantics apply without a terminal", %{tmp_dir: dir} do
    scope = :"nacreous_presets_#{System.unique_integer([:positive])}"
    ctx = Context.new(scope)

    entries = Presets.entries(home: Path.join(dir, "home"), cwd: dir)
    tools_entry = Enum.find(entries, &(&1.id == :tools))
    policy_entry = Enum.find(entries, &(&1.id == :policy))

    {:ok, _} = Context.use(ctx, Tools, tools_entry.config)
    {:ok, _} = Context.use(ctx, Clearance.Component, policy_entry.config)

    tools = await(ctx, :tools)
    policy = await(ctx, :policy)

    # 1. Auto-allow still works: fs_read never needs a prompt.
    File.write!(Path.join(dir, "notes.md"), "hi")
    assert {:ok, "1\thi"} = Tools.execute(tools, "read", %{"file_path" => "notes.md"})

    # 2. Headless fail-closed: a write has nobody to approve it.
    assert {:error, %{type: :denied, message: message}} =
             Tools.execute(tools, "write", %{"file_path" => "out.txt", "content" => "no"})

    assert message =~ "requires approval (non-interactive policy)"

    # 3. The analyzer is the same code Noctilucent runs: a catastrophic
    #    command is denied before execution, with no prompt involved.
    assert {:error, %{type: :denied, message: lint_message}} =
             Tools.execute(tools, "execute", %{
               "runtime" => "powershell",
               "code" => "$home = 'C:/Temp/x'\nRemove-Item -Recurse -Force $home"
             })

    assert lint_message =~ "blocked by shell lint"

    # 4. A programmatic lease substitutes for the missing prompt.
    {:ok, _lease} = Clearance.grant_lease(policy, [:fs_write], ttl_ms: 60_000)

    assert {:ok, _} =
             Tools.execute(tools, "write", %{"file_path" => "out.txt", "content" => "yes"})

    assert File.read!(Path.join(dir, "out.txt")) == "yes"
  end

  defp await(ctx, key, attempts \\ 50)
  defp await(_ctx, key, 0), do: raise("#{key} not bound")

  defp await(ctx, key, attempts) do
    case Context.get(ctx, key) do
      {:ok, value} ->
        value

      :error ->
        Process.sleep(10)
        await(ctx, key, attempts - 1)
    end
  end
end
