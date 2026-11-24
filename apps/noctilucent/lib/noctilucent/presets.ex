defmodule Noctilucent.Presets do
  @moduledoc """
  Persona presets: ready-made compositions for the built-in agent personas
  `:coding`, `:personal` and `:tutor`.

  A persona is not a code fork — it is a choice of model, session directory,
  tool set and skill directory chain, expressed as `DexterousLoader.Entry`
  records. `entries/2` returns the three seam entries (`:llm`, `:sessions`,
  `:tools`) ready for `DexterousLoader.start_link/2`; `system_prompt/2` gives
  the persona's opening `:"system/message"` content, which the caller appends
  to a fresh session (model-visible means logged).

  Isolation between personas falls out of the composition: each preset points
  `:sessions` at its own directory and declares its own tool list, and each
  loader gets its own scope (and with it, its own event bus).

  Options for `entries/2` and `system_prompt/2`:

    * `:model` — ReqLLM model spec (default per persona)
    * `:home` — base directory for persona state (default `~/.pcw`); session
      logs live in `<home>/sessions/<persona>`, persona-level skills in
      `<home>/<persona>/skills`
    * `:cwd` — working directory for the tools and the workspace skill layer
      (default `File.cwd!()`)
    * `:llm_opts` — extra `:llm` entry config (e.g. `:temperature`,
      `:base_url`, `:api_key`), passed through

  The skill directory chain (earlier entries win name collisions) is:
  workspace (`<cwd>/.agents/skills`, `<cwd>/.claude/skills`, `<cwd>/skills`)
  → persona (`<home>/<persona>/skills`) → global (`~/.agents/skills`).
  """

  alias PurpleChonkyWhale.{LLM, Sessions, Tools}
  alias DexterousLoader.Entry

  @type persona :: :coding | :personal | :tutor

  @personas [:coding, :personal, :tutor]

  @default_model "deepseek:deepseek-flash"

  @doc "The built-in personas."
  @spec personas() :: [persona()]
  def personas, do: @personas

  @doc """
  The three seam entries (`:llm`, `:sessions`, `:tools`) composing `persona`.
  Raises `FunctionClauseError` for unknown personas.
  """
  @spec entries(persona(), keyword()) :: [Entry.t()]
  def entries(persona, opts \\ []) when persona in @personas do
    home = opts |> Keyword.get(:home, default_home()) |> Path.expand()
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    model = Keyword.get(opts, :model, @default_model)
    llm_opts = Keyword.get(opts, :llm_opts, [])

    [
      %Entry{id: :llm, component: LLM, config: [model: model] ++ llm_opts},
      %Entry{
        id: :sessions,
        component: Sessions,
        config: [dir: Path.join([home, "sessions", Atom.to_string(persona)])]
      },
      %Entry{
        id: :tools,
        component: Tools,
        config: [
          tools: tools_for(persona),
          env: %{cwd: cwd, skill_dirs: skill_dirs(home, persona, cwd), vision?: vision?(model)}
        ]
      }
    ]
  end

  @doc """
  The persona's opening system prompt. Append it to a fresh session as a
  `:"system/message"` event.
  """
  @spec system_prompt(persona(), keyword()) :: String.t()
  def system_prompt(persona, opts \\ []) when persona in @personas do
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    case persona do
      :coding ->
        """
        You are a coding agent. The working directory is #{cwd}.
        Use the read/write/edit/glob/grep tools to inspect and modify files, and
        execute to run tests, git or a build.
        After editing source files under lib/, call recompile to hot-swap them.
        When the task is done, answer briefly without calling tools.
        """

      :personal ->
        """
        You are a personal agent. The working directory is #{cwd}.
        Use the file tools to read and organize notes, and todo_write to track
        tasks. Be concise; ask before any destructive change.
        """

      :tutor ->
        """
        You are a tutor. You can inspect files with read/glob/grep but cannot
        modify anything. Teach through questions rather than giving answers
        away, and adapt to the learner's level.
        """
    end
  end

  @doc "The tool modules granted to `persona`."
  @spec tools_for(persona()) :: [module()]
  def tools_for(:coding) do
    [
      Tools.Read,
      Tools.Write,
      Tools.Edit,
      Tools.Glob,
      Tools.Grep,
      Tools.Executor,
      Tools.TodoWrite,
      Tools.Skill,
      Tools.Recompile
    ]
  end

  def tools_for(:personal) do
    [
      Tools.Read,
      Tools.Write,
      Tools.Edit,
      Tools.Glob,
      Tools.Grep,
      Tools.TodoWrite,
      Tools.Skill
    ]
  end

  def tools_for(:tutor) do
    [
      Tools.Read,
      Tools.Glob,
      Tools.Grep,
      Tools.Skill
    ]
  end

  defp default_home do
    case System.user_home() do
      nil -> Path.join(File.cwd!(), ".pcw")
      home -> Path.join(home, ".pcw")
    end
  end

  # Whether the model accepts image input, per the LLMDB catalog. Unknown
  # models (or catalog entries without modality data) fail open: the provider
  # is the final arbiter.
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

  defp skill_dirs(home, persona, cwd) do
    workspace = Enum.map([".agents/skills", ".claude/skills", "skills"], &Path.join(cwd, &1))
    persona_dir = Path.join([home, Atom.to_string(persona), "skills"])

    global =
      case System.user_home() do
        nil -> []
        user_home -> [Path.join(user_home, ".agents/skills")]
      end

    workspace ++ [persona_dir] ++ global
  end
end
