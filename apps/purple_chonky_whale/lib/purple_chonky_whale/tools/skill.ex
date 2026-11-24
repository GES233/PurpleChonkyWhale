defmodule PurpleChonkyWhale.Tools.Skill do
  @workspace_rel_dirs [".agents/skills", ".claude/skills", "skills"]
  @home_rel_dirs [".agents/skills", ".dsh/skills", ".config/mdtask/skills"]
  @max_description_chars 280

  @moduledoc """
  The `skill` tool: discover and load reusable `SKILL.md` instruction
  packages on demand.

  Only compact summaries (`name` + `description` from each `SKILL.md` YAML
  frontmatter) go into the system prompt via `prompt_section/1`; calling the
  `skill` tool loads the full `SKILL.md` body and reports its base directory
  so relative assets or scripts inside the skill can be read.

  Environment:

    * `:skill_dirs` — explicit list of directories to scan for `SKILL.md`
      files. When omitted, workspace directories (`#{inspect(@workspace_rel_dirs)}`)
      and user-home directories (`#{inspect(@home_rel_dirs)}`) are searched in
      order; earlier entries take precedence on name collisions.
  """

  @behaviour PurpleChonkyWhale.Tool

  alias PurpleChonkyWhale.Tools.Walk

  @type entry :: %{
          name: String.t(),
          description: String.t(),
          path: Path.t(),
          dir: Path.t()
        }

  @impl true
  def schema do
    %{
      name: "skill",
      description:
        "Load the full instructions for a skill from the session skill catalog. " <>
          "Call this before acting on a task that names or clearly matches an available skill.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "Exact skill name from <available_skills>."
          }
        },
        "required" => ["name"]
      }
    }
  end

  @impl true
  def execute(%{"name" => name}, env) when is_binary(name) do
    trimmed = String.trim(name)
    entries = catalog(env)

    case Enum.find(entries, &(&1.name == trimmed)) do
      %{path: path, dir: dir, name: skill_name} ->
        case File.read(path) do
          {:ok, content} ->
            {:ok,
             "<skill_content name=\"#{skill_name}\" dir=\"#{Walk.slash(dir)}\">\n" <>
               content <> "\n</skill_content>"}

          {:error, reason} ->
            {:error, "cannot read skill #{skill_name}: #{:file.format_error(reason)}"}
        end

      nil ->
        available = Enum.map_join(entries, ", ", & &1.name)

        hint =
          if available == "",
            do: "no skills are installed",
            else: "available skills: #{available}"

        {:error, "unknown skill #{inspect(trimmed)} (#{hint})"}
    end
  end

  def execute(_args, _env), do: {:error, "name is a required string"}

  @doc """
  Discover available skills from `env[:skill_dirs]` (or the default workspace
  and user-home skill directories), returning sorted `%{name, description, path, dir}`
  entries.
  """
  @spec catalog(PurpleChonkyWhale.Tool.env() | keyword()) :: [entry()]
  def catalog(env \\ %{}) do
    env
    |> skill_dirs()
    |> Enum.flat_map(&scan_skill_dir/1)
    |> Enum.reduce(%{}, fn entry, acc -> Map.put_new(acc, entry.name, entry) end)
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Render the `<available_skills>` system-prompt block for `env`, or `""` when
  no skills are found.
  """
  @spec prompt_section(PurpleChonkyWhale.Tool.env() | keyword()) :: String.t()
  def prompt_section(env \\ %{}) do
    case catalog(env) do
      [] ->
        ""

      entries ->
        lines =
          Enum.map_join(entries, "\n", fn %{name: name, description: desc} ->
            "- `#{name}`: #{truncate(desc, @max_description_chars)}"
          end)

        """


        A skill is a reusable set of task-specific instructions. When a task names or clearly matches a skill below, call the `skill` tool with its exact `name` to load its full instructions before acting:

        <available_skills>
        #{lines}
        </available_skills>
        """
        |> String.trim_trailing()
    end
  end

  @doc "Directories searched for `SKILL.md` files, in precedence order."
  @spec skill_dirs(PurpleChonkyWhale.Tool.env() | keyword()) :: [Path.t()]
  def skill_dirs(env \\ %{}) do
    case env[:skill_dirs] do
      dirs when is_list(dirs) ->
        dirs |> Enum.map(&Path.expand/1) |> Enum.filter(&File.dir?/1)

      _ ->
        cwd = env[:cwd] || File.cwd!()
        workspace_dirs = Enum.map(@workspace_rel_dirs, &Path.expand(&1, cwd))

        home_dirs =
          case System.user_home() do
            nil -> []
            home -> Enum.map(@home_rel_dirs, &Path.expand(&1, home))
          end

        (workspace_dirs ++ home_dirs)
        |> Enum.uniq()
        |> Enum.filter(&File.dir?/1)
    end
  end

  defp scan_skill_dir(root) do
    root
    |> find_skill_files(0, 3)
    |> Enum.sort()
    |> Enum.flat_map(&parse_skill_file/1)
  end

  defp find_skill_files(_dir, depth, max_depth) when depth > max_depth, do: []

  defp find_skill_files(dir, depth, max_depth) do
    skill_md = Path.join(dir, "SKILL.md")

    own = if File.regular?(skill_md), do: [skill_md], else: []

    children =
      case File.ls(dir) do
        {:ok, entries} ->
          entries
          |> Enum.sort()
          |> Enum.flat_map(fn entry ->
            path = Path.join(dir, entry)

            if directory?(path) and not String.starts_with?(entry, ".") do
              find_skill_files(path, depth + 1, max_depth)
            else
              []
            end
          end)

        {:error, _} ->
          []
      end

    own ++ children
  end

  defp directory?(path) do
    match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))
  end

  defp parse_skill_file(path) do
    case File.read(path) do
      {:ok, content} ->
        dir = Path.dirname(path)
        fallback_name = Path.basename(dir)
        meta = parse_frontmatter(content)
        name = Map.get(meta, "name", fallback_name) |> String.trim()
        description = Map.get(meta, "description", "Skill in #{fallback_name}") |> String.trim()

        if name == "" do
          []
        else
          [%{name: name, description: description, path: path, dir: dir}]
        end

      {:error, _} ->
        []
    end
  end

  defp parse_frontmatter(content) do
    case Regex.run(~r/\A---\r?\n(.*?)\r?\n---(?:\r?\n|\z)/s, content, capture: :all_but_first) do
      [yaml] ->
        yaml
        |> String.split(~r/\r?\n/)
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, ":", parts: 2) do
            [key, value] ->
              k = String.trim(key)
              v = value |> String.trim() |> unquote_yaml()
              if k != "" and v != "", do: Map.put(acc, k, v), else: acc

            _ ->
              acc
          end
        end)

      _ ->
        %{}
    end
  end

  defp unquote_yaml(<<"\"", rest::binary>>) do
    String.trim_trailing(rest, "\"")
  end

  defp unquote_yaml(<<"'", rest::binary>>) do
    String.trim_trailing(rest, "'")
  end

  defp unquote_yaml(value), do: value

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end
end
