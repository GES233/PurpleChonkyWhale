defmodule Nacreous.Presets do
  @default_model "deepseek:deepseek-flash"

  @moduledoc """
  The `:work` preset: one composition for a project-oriented, headless agent.

  Nacreous has no terminal approval UI. It mounts the shared
  `Clearance.Component` with `Clearance.Asker.DenyAll`, so a tool call either
  matches `:auto_allow`, is covered by a lease the application granted
  programmatically, or is denied. That is the whole point of the split: the
  policy ladder and the static analyzers are the same code Noctilucent uses —
  only the asker differs.

  Options for `entries/1`:

    * `:model` — ReqLLM model spec (default `#{@default_model}`)
    * `:home` — base directory for app state (default `~/.nacreous`); session
      logs live in `<home>/sessions`, memory in `<home>/memory`
    * `:cwd` — workspace for the tools (default `File.cwd!()`)
    * `:llm_opts` — extra `:llm` entry config, passed through
    * `:policy_opts` — extra `Clearance.Component` config (e.g. `:asker`,
      `:auto_allow`, `:lease_ttl_ms`, `:initial_leases`)
    * `:sandbox_opts` — extra `PurpleChonkyWhale.Sandbox` config
    * `:mcp_servers` — MCP server declarations, passed to the `:tools` entry
  """

  alias Clearance.{Asker, Component, Lint}
  alias DexterousLoader.Entry
  alias PurpleChonkyWhale.{LLM, Memory, Sandbox, Sessions, Tools}

  @doc "The seam entries composing the work preset."
  @spec entries(keyword()) :: [Entry.t()]
  def entries(opts \\ []) when is_list(opts) do
    home = opts |> Keyword.get(:home, default_home()) |> Path.expand()
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    model = Keyword.get(opts, :model, @default_model)
    llm_opts = Keyword.get(opts, :llm_opts, [])
    policy_opts = Keyword.get(opts, :policy_opts, [])
    sandbox_opts = Keyword.get(opts, :sandbox_opts, [])
    mcp_servers = Keyword.get(opts, :mcp_servers, [])
    protected = protected_dirs(home)

    sandbox_config =
      Keyword.merge(
        [
          backend: Sandbox.Host,
          mode: :workspace_write,
          cwd: cwd,
          network?: :on_grant,
          fail_open?: false
        ],
        sandbox_opts
      )

    [
      %Entry{id: :llm, component: LLM, config: [model: model] ++ llm_opts},
      %Entry{
        id: :sessions,
        component: Sessions,
        config: [dir: Path.join(home, "sessions")]
      },
      %Entry{id: :sandbox, component: Sandbox, config: sandbox_config},
      %Entry{
        id: :tools,
        component: Tools,
        config: [
          tools: tools(),
          require_grant?: true,
          require_sandbox?: true,
          sandbox: sandbox_config,
          env: %{
            cwd: cwd,
            skill_dirs: skill_dirs(home, cwd),
            vision?: vision?(model),
            protected_dirs: protected,
            allowed_runtimes: PurpleChonkyWhale.Tools.Executor.default_allowed_runtimes()
          },
          mcp_servers: mcp_servers
        ]
      },
      %Entry{
        id: :memory,
        component: Memory,
        config: [layers: [{:project, Path.join(home, "memory"), writable: true}]]
      },
      %Entry{
        id: :policy,
        component: Component,
        config:
          Keyword.merge(
            [
              asker: Asker.DenyAll,
              lint: &Lint.inspect/2,
              lint_tools: ["execute"],
              protected_dirs: protected
            ],
            policy_opts
          )
      }
    ]
  end

  @doc """
  The preset's opening system prompt. Append it to a fresh session as a
  `:"system/message"` event.
  """
  @spec system_prompt(keyword()) :: String.t()
  def system_prompt(opts \\ []) when is_list(opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    """
    You are a work agent on a shared project. The working directory is #{cwd}.
    Inspect the project with read/glob/grep, change it with write/edit, and run
    builds, tests or git through execute. Writes and commands require an
    explicit capability grant; nothing here prompts a human, so a denied call
    is final for this session. Use todo_write to track multi-step work, and
    memory_save/memory_update/memory_delete for facts that should outlive the
    session. When the task is done, answer briefly without calling tools.
    """
  end

  @doc "The tool modules this preset grants."
  @spec tools() :: [module()]
  def tools do
    [
      Tools.Read,
      Tools.Write,
      Tools.Edit,
      Tools.Glob,
      Tools.Grep,
      Tools.Executor,
      Tools.TodoWrite,
      Tools.Skill,
      Tools.MemorySave,
      Tools.MemoryUpdate,
      Tools.MemoryDelete
    ]
  end

  defp default_home do
    case System.user_home() do
      nil -> Path.join(File.cwd!(), ".nacreous")
      home -> Path.join(home, ".nacreous")
    end
  end

  defp protected_dirs(home), do: [home]

  defp skill_dirs(home, cwd) do
    workspace = Enum.map([".agents/skills", ".claude/skills", "skills"], &Path.join(cwd, &1))

    global =
      case System.user_home() do
        nil -> []
        user_home -> [Path.join(user_home, ".agents/skills")]
      end

    workspace ++ [Path.join(home, "skills")] ++ global
  end

  # Whether the model accepts image input, per the LLMDB catalog. Unknown
  # models fail open: the provider is the final arbiter.
  defp vision?(%LLMDB.Model{modalities: %{input: input}}) when is_list(input),
    do: :image in input

  defp vision?(%LLMDB.Model{}), do: true

  defp vision?(%{modalities: %{input: input}}) when is_list(input), do: :image in input

  defp vision?(model) when is_binary(model) or is_tuple(model) do
    case LLMDB.model(model) do
      {:ok, %LLMDB.Model{} = resolved} -> vision?(resolved)
      _ -> true
    end
  end

  defp vision?(_model), do: true
end
