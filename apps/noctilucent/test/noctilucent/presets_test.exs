defmodule Noctilucent.PresetsTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Noctilucent.{Policy, Presets}
  alias PurpleChonkyWhale.{LLM, Memory, Sandbox, Sessions, Tools}
  alias Dexterous.Context
  alias DexterousLoader.Entry

  defp entry(entries, id), do: Enum.find(entries, &(&1.id == id))

  test "every persona mounts the four seams plus sandbox and policy", %{tmp_dir: tmp_dir} do
    for persona <- Presets.personas() do
      entries = Presets.entries(persona, home: tmp_dir, cwd: tmp_dir)

      assert [
               %Entry{id: :llm, component: LLM},
               %Entry{id: :sessions, component: Sessions},
               %Entry{id: :sandbox, component: Sandbox},
               %Entry{id: :tools, component: Tools},
               %Entry{id: :memory, component: Memory},
               %Entry{id: :policy, component: Policy}
             ] = entries

      tools_config = entry(entries, :tools).config
      assert Keyword.fetch!(tools_config, :require_grant?) == true
      assert Keyword.fetch!(tools_config, :require_sandbox?) == true

      sandbox_config = entry(entries, :sandbox).config
      expected_mode = if persona == :tutor, do: :read_only, else: :workspace_write
      assert Keyword.fetch!(sandbox_config, :mode) == expected_mode
      assert Keyword.fetch!(sandbox_config, :network?) == :on_grant
      assert Keyword.fetch!(sandbox_config, :fail_open?) == false
    end
  end

  test "Presets composition enforces Policy gate end-to-end (reads allowed, writes fail closed without ask)",
       %{tmp_dir: tmp_dir} do
    cwd = Path.join(tmp_dir, "work")
    File.mkdir_p!(cwd)
    File.write!(Path.join(cwd, "note.txt"), "hello")

    scope = :"presets_policy_e2e_#{System.unique_integer([:positive])}"
    ctx = Context.new(scope)
    entries = Presets.entries(:coding, home: Path.join(tmp_dir, "home"), cwd: cwd)
    {:ok, _loader} = DexterousLoader.start_link(ctx, entries)

    _sandbox = await_binding(ctx, :sandbox)
    tools = await_binding(ctx, :tools)
    _policy = await_binding(ctx, :policy)

    assert {:ok, "1\thello"} = Tools.execute(tools, "read", %{"file_path" => "note.txt"})

    assert {:error, %{type: :denied}} =
             Tools.execute(tools, "write", %{"file_path" => "out.txt", "content" => "blocked"})
  end

  defp await_binding(ctx, key, attempts \\ 50)
  defp await_binding(_ctx, key, 0), do: raise("#{key} not bound in time")

  defp await_binding(ctx, key, attempts) do
    case Context.get(ctx, key) do
      {:ok, val} ->
        val

      :error ->
        Process.sleep(10)
        await_binding(ctx, key, attempts - 1)
    end
  end

  test "memory layers are persona-writable then global-read-only", %{tmp_dir: tmp_dir} do
    layers =
      Presets.entries(:personal, home: tmp_dir)
      |> entry(:memory)
      |> Map.fetch!(:config)
      |> Keyword.fetch!(:layers)

    assert [{:persona, persona_dir, [writable: true]} | global] = layers
    assert persona_dir == Path.join([tmp_dir, "personal", "memory"])

    case global do
      [{:global, _dir, [writable: false]}] -> :ok
      [] -> :ok
    end
  end

  test "every persona can save, update and delete memories", %{tmp_dir: tmp_dir} do
    for persona <- Presets.personas() do
      tools =
        Presets.entries(persona, home: tmp_dir)
        |> entry(:tools)
        |> Map.fetch!(:config)
        |> Keyword.fetch!(:tools)

      assert Tools.MemorySave in tools
      assert Tools.MemoryUpdate in tools
      assert Tools.MemoryDelete in tools
    end
  end

  test "each persona gets its own session directory", %{tmp_dir: tmp_dir} do
    dirs =
      Map.new(Presets.personas(), fn persona ->
        entry = entry(Presets.entries(persona, home: tmp_dir), :sessions)
        {persona, Keyword.fetch!(entry.config, :dir)}
      end)

    assert dirs.coding == Path.join([tmp_dir, "sessions", "coding"])
    assert dirs.personal == Path.join([tmp_dir, "sessions", "personal"])
    assert dirs.tutor == Path.join([tmp_dir, "sessions", "tutor"])
  end

  test "tool sets grant write access by persona", %{tmp_dir: tmp_dir} do
    tools = fn persona ->
      Presets.entries(persona, home: tmp_dir)
      |> entry(:tools)
      |> Map.fetch!(:config)
      |> Keyword.fetch!(:tools)
    end

    coding = tools.(:coding)
    assert Tools.Write in coding
    assert Tools.Executor in coding
    assert Tools.Recompile in coding

    personal = tools.(:personal)
    assert Tools.Write in personal
    assert Tools.TodoWrite in personal
    refute Tools.Executor in personal
    refute Tools.Recompile in personal

    tutor = tools.(:tutor)
    assert Tools.Read in tutor
    refute Tools.Write in tutor
    refute Tools.Edit in tutor
    refute Tools.Executor in tutor
  end

  test "the skill directory chain is workspace → persona → global", %{tmp_dir: tmp_dir} do
    cwd = Path.join(tmp_dir, "proj")

    env =
      Presets.entries(:coding, home: tmp_dir, cwd: cwd)
      |> entry(:tools)
      |> Map.fetch!(:config)
      |> Keyword.fetch!(:env)

    assert [workspace | _] = env.skill_dirs
    assert workspace == Path.join(cwd, ".agents/skills")
    assert Path.join([tmp_dir, "coding", "skills"]) in env.skill_dirs

    if home = System.user_home() do
      assert List.last(env.skill_dirs) == Path.join(home, ".agents/skills")
    end
  end

  test "the model defaults per persona and is overridable", %{tmp_dir: tmp_dir} do
    default = entry(Presets.entries(:coding, home: tmp_dir), :llm)
    assert Keyword.fetch!(default.config, :model) == "deepseek:deepseek-flash"

    custom =
      Presets.entries(:tutor, home: tmp_dir, model: "anthropic:claude-sonnet-4-5")
      |> entry(:llm)

    assert Keyword.fetch!(custom.config, :model) == "anthropic:claude-sonnet-4-5"
  end

  test "llm_opts pass through to the llm entry", %{tmp_dir: tmp_dir} do
    entry =
      Presets.entries(:coding,
        home: tmp_dir,
        llm_opts: [temperature: 0.2, base_url: "https://relay.example.com"]
      )
      |> entry(:llm)

    assert Keyword.get(entry.config, :temperature) == 0.2
    assert Keyword.get(entry.config, :base_url) == "https://relay.example.com"
  end

  test "unknown personas raise", %{tmp_dir: tmp_dir} do
    assert_raise FunctionClauseError, fn ->
      apply(Presets, :entries, [:unknown, [home: tmp_dir]])
    end
  end

  test "system prompts mention capabilities matching their tool sets", %{tmp_dir: tmp_dir} do
    assert Presets.system_prompt(:coding, cwd: tmp_dir) =~ "recompile"
    assert Presets.system_prompt(:personal, cwd: tmp_dir) =~ "todo_write"
    tutor = Presets.system_prompt(:tutor, cwd: tmp_dir)
    assert tutor =~ "read/glob/grep"
    assert tutor =~ "but cannot"
  end

  test "the tools env carries vision? from the model's input modalities", %{tmp_dir: tmp_dir} do
    vision? = fn model ->
      Presets.entries(:personal, home: tmp_dir, model: model)
      |> entry(:tools)
      |> Map.fetch!(:config)
      |> Keyword.fetch!(:env)
      |> Map.fetch!(:vision?)
    end

    text_only = LLMDB.Model.new!(%{id: "t", provider: :acme, modalities: %{input: [:text]}})

    sighted =
      LLMDB.Model.new!(%{id: "v", provider: :acme, modalities: %{input: [:text, :image]}})

    assert vision?.(text_only) == false
    assert vision?.(sighted) == true
    # Models unknown to the catalog fail open; the provider is the final arbiter.
    assert vision?.("acme:not-in-the-catalog") == true
  end

  test "the tools env carries protected_dirs and disables in-process elixir by default", %{
    tmp_dir: tmp_dir
  } do
    env =
      Presets.entries(:coding, home: tmp_dir, cwd: tmp_dir)
      |> entry(:tools)
      |> Map.fetch!(:config)
      |> Keyword.fetch!(:env)

    assert Path.expand(tmp_dir) in env.protected_dirs
    assert "shell" in env.allowed_runtimes
    assert "elixir_subprocess" in env.allowed_runtimes
    refute "elixir" in env.allowed_runtimes
  end
end
