# A multi-turn headless agent: many turns against one session log, so the
# model keeps its context (and its tool history) between prompts.
#
#   mix run examples/multi_turn_agent.exs -- [--cwd PATH] [--session ID] [model]
#
# `--cwd` changes the agent's workspace without changing the directory that
# hosts this Mix project. Relative paths are resolved from the launch cwd.
# `--session` opens (or resumes) a named session log in ~/.dark_chonky_whale/sessions.
#
# Each line read from stdin is one turn. Blank lines are ignored. A line
# starting with "/" is a command:
#
#   /quit, /exit     end the session
#   /cancel          cancel the currently active AgentRun
#   /steer TEXT      inject a steering message into the active AgentRun
#   /reset           start a fresh session log (the old one stays on disk)
#   /sessions        list saved session ids on disk
#   /resume ID       switch to (or open) session ID
#   /log             print the model-visible message count
#
# Anything else is a user message; the agent works the turn with the file
# tools and `execute`, then waits for the next line. The whole conversation
# lives in one session log, so turn 2 sees everything turn 1 did.
#
# The terminal rendering is driven entirely by the seam events: `llm/chunk`
# streams the answer, `tools/post-execute` reports each tool call.

alias DarkChonkyWhale.{AgentRun, LLM, Session, Sessions, Tools}
alias DarkChonkyWhale.Executor.Runtimes.Shell
alias Dexterous.Context
alias DexterousLoader.Entry

usage = """
usage: mix run examples/multi_turn_agent.exs -- [options] [model]

Options:
  --cwd PATH, -c PATH        use PATH as the agent's working directory
  --session ID, -s ID        open or resume session ID
  --help, -h                 show this help

The model defaults to deepseek:deepseek-flash. Relative working directories
are resolved from the directory where mix run was started.
"""

{opts, args, invalid} =
  OptionParser.parse(System.argv(),
    strict: [cwd: :string, session: :string, help: :boolean],
    aliases: [c: :cwd, s: :session, h: :help]
  )

fail = fn message ->
  IO.puts(:stderr, "#{message}\n\n#{usage}")
  System.halt(2)
end

if opts[:help] do
  IO.puts(usage)
  System.halt(0)
end

if invalid != [], do: fail.("unknown or invalid options: #{inspect(invalid)}")
if length(args) > 1, do: fail.("expected at most one model argument")

model = List.first(args) || "deepseek:deepseek-flash"
launch_cwd = File.cwd!()
cwd = opts |> Keyword.get(:cwd, launch_cwd) |> Path.expand(launch_cwd)

unless File.dir?(cwd), do: fail.("working directory does not exist or is not a directory: #{cwd}")

# `recompile` hot-swaps this running Mix project. It is useful when the agent
# works on dark_chonky_whale itself, but is misleading for an external repo.
self_edit? = cwd == launch_cwd

tool_modules = [
  Tools.Read,
  Tools.Write,
  Tools.Edit,
  Tools.Glob,
  Tools.Grep,
  Tools.Executor,
  Tools.TodoWrite,
  Tools.Skill
]

{tool_modules, tool_env} =
  if self_edit? do
    {tool_modules ++ [Tools.Recompile], %{cwd: cwd, watch_dirs: [Path.join(cwd, "lib")]}}
  else
    {tool_modules, %{cwd: cwd}}
  end

dir =
  Path.join(
    System.user_home() || System.tmp_dir!(),
    ".dark_chonky_whale/sessions"
  )

ctx = Dexterous.root()

{:ok, _} =
  Context.on(ctx, :"llm/chunk", fn chunk ->
    case chunk.type do
      :content -> IO.write(chunk.text)
      :thinking -> IO.write(IO.ANSI.faint() <> chunk.text <> IO.ANSI.reset())
      _ -> :ok
    end
  end)

{:ok, _} =
  Context.on(ctx, :"tools/todo", fn %{todos: todos} ->
    IO.puts("\n[todos]")

    Enum.each(todos, fn %{content: content, status: status} ->
      marker =
        case status do
          "completed" -> IO.ANSI.green() <> "[x]" <> IO.ANSI.reset()
          "in_progress" -> IO.ANSI.yellow() <> "[>]" <> IO.ANSI.reset()
          _ -> IO.ANSI.faint() <> "[ ]" <> IO.ANSI.reset()
        end

      IO.puts("  #{marker} #{content}")
    end)
  end)

{:ok, _} =
  Context.on(ctx, :"tools/post-execute", fn %{name: name, result: result, duration_ms: ms} ->
    status =
      case result do
        {:ok, _} -> "ok"
        {:error, error} -> "error: #{inspect(error)}"
      end

    IO.puts("\n[tool #{name}] #{status} (#{ms}ms)")
  end)

{:ok, loader} =
  DexterousLoader.start_link(ctx, [
    %Entry{id: :llm, component: LLM, config: [model: model]},
    %Entry{id: :sessions, component: Sessions, config: [dir: dir]},
    %Entry{
      id: :tools,
      component: Tools,
      config: [
        tools: tool_modules,
        env: tool_env
      ]
    }
  ])

if self_edit? do
  # The HMR loop, with this composition's loader registered, so the recompile
  # tool's cycles respawn stale entries transactionally.
  {:ok, _} = DexterousHMR.start_link()
  :ok = DexterousHMR.register(loader)
end

await = fn key ->
  Enum.reduce_while(1..100, nil, fn _, _ ->
    case Context.get(ctx, key) do
      {:ok, value} -> {:halt, value}
      :error -> {:cont, Process.sleep(10)}
    end
  end) || raise "#{key} was not bound in time"
end

llm = await.(:llm)
sessions = await.(:sessions)
tools = await.(:tools)

validation_instruction =
  if self_edit? do
    "After editing source files under lib/, call recompile to hot-swap them."
  else
    "Use the target project's own commands to validate changes."
  end

shell_description = Shell.describe(tool_env)

workspace_instructions =
  ["AGENTS.md", "CLAUDE.md"]
  |> Enum.find_value(fn name ->
    path = Path.join(cwd, name)

    case File.read(path) do
      {:ok, content} when byte_size(content) > 0 ->
        "\n\nWorkspace instructions from #{name}:\n\n" <> String.slice(content, 0, 16_000)

      _ ->
        nil
    end
  end) || ""

skills_section = Tools.Skill.prompt_section(tool_env)

system = """
You are a coding agent working in #{cwd}. Use the read/write/edit/glob/grep
tools to inspect and modify files, todo_write to plan and track multi-step
work, and execute to run the tests, git or a build.
The default `execute` (`runtime: "shell"`) runs in: #{shell_description}.
#{validation_instruction}
This is a multi-turn conversation: earlier turns are in your context, so build
on what you already learned instead of re-investigating from scratch.
When a turn's task is done, answer briefly without calling tools.#{workspace_instructions}#{skills_section}
"""

# Open or resume a session log. A brand-new log is seeded with the system
# message; an existing log keeps its history intact and seals any interrupted
# tool calls from an earlier run.
open = fn id ->
  {:ok, session} = Sessions.open(sessions, id)
  {:ok, _} = Session.seal_unsettled(session)

  if Session.events(session) == [] do
    {:ok, _} = Session.append(session, :"system/message", %{"content" => system})
  end

  {id, session}
end

fresh_id = fn -> "multi-#{System.unique_integer([:positive])}" end
{session_id, session} = open.(opts[:session] || fresh_id.())

IO.puts(
  "model: #{model}\ncwd: #{cwd}\nsession: #{session_id}\nturn 1 — enter a task ('/quit' to leave, '/cancel' to stop run, '/steer TEXT' to steer, '/sessions' to list, '/resume ID' to switch)\n---"
)

# Spawn a dedicated stdin reader so `/cancel` and `/steer` can be processed
# while an AgentRun is actively executing.
repl_pid = self()

spawn_link(fn ->
  read_loop = fn read_loop ->
    case IO.gets("\n> ") do
      :eof ->
        send(repl_pid, :stdin_eof)

      {:error, _} ->
        send(repl_pid, :stdin_eof)

      line ->
        send(repl_pid, {:stdin_line, String.trim(line)})
        read_loop.(read_loop)
    end
  end

  read_loop.(read_loop)
end)

await_active_run = fn await_active_run, run_pid, run_id, pending_lines, eof? ->
  receive do
    {:run_finished, ^run_id, outcome} ->
      case outcome do
        {:ok, _text} -> IO.puts("\n== turn complete (#{run_id}) ==")
        {:error, {:cancelled, reason}} -> IO.puts("\n== turn cancelled (#{run_id}): #{inspect(reason)} ==")
        {:error, error} -> IO.puts("\n== turn failed (#{run_id}): #{inspect(error)} ==")
      end

      {Enum.reverse(pending_lines), eof?}

    {:stdin_line, "/cancel"} ->
      IO.puts("\n[cancelling #{run_id}...]")
      Task.start(fn -> AgentRun.cancel(run_pid, "cancelled by user") end)
      await_active_run.(await_active_run, run_pid, run_id, pending_lines, eof?)

    {:stdin_line, "/steer " <> steer_text} ->
      steer_text = String.trim(steer_text)

      if steer_text != "" do
        {:ok, _} = AgentRun.steer(run_pid, steer_text)
        IO.puts("\n[steered into #{run_id}]")
      end

      await_active_run.(await_active_run, run_pid, run_id, pending_lines, eof?)

    {:stdin_line, ""} ->
      await_active_run.(await_active_run, run_pid, run_id, pending_lines, eof?)

    {:stdin_line, other} ->
      await_active_run.(await_active_run, run_pid, run_id, [other | pending_lines], eof?)

    :stdin_eof ->
      await_active_run.(await_active_run, run_pid, run_id, pending_lines, true)
  end
end

next_line = fn
  [head | rest], eof? -> {:line, head, rest, eof?}
  [], true -> :eof
  [], false ->
    receive do
      {:stdin_line, line} -> {:line, line, [], false}
      :stdin_eof -> :eof
    end
end

loop = fn loop, {session_id, session}, queue, eof? ->
  case next_line.(queue, eof?) do
    :eof ->
      IO.puts("\n(input closed — bye)")
      :ok

    {:line, "", rest, eof?} ->
      loop.(loop, {session_id, session}, rest, eof?)

    {:line, cmd, _rest, _eof?} when cmd in ["/quit", "/exit"] ->
      IO.puts("bye (session: #{session_id})")
      :ok

    {:line, "/cancel", rest, eof?} ->
      IO.puts("[no active run to cancel]")
      loop.(loop, {session_id, session}, rest, eof?)

    {:line, "/reset", rest, eof?} ->
      {new_id, new_session} = open.(fresh_id.())
      IO.puts("[reset — switched to fresh session #{new_id}]")
      loop.(loop, {new_id, new_session}, rest, eof?)

    {:line, "/sessions", rest, eof?} ->
      ids = Sessions.list(sessions) |> Enum.sort()
      IO.puts("[saved sessions (#{length(ids)}): #{Enum.join(ids, ", ")}]")
      loop.(loop, {session_id, session}, rest, eof?)

    {:line, "/resume " <> target_id, rest, eof?} ->
      target_id = String.trim(target_id)

      if target_id == "" do
        IO.puts("[usage: /resume SESSION_ID]")
        loop.(loop, {session_id, session}, rest, eof?)
      else
        {resumed_id, resumed} = open.(target_id)
        count = length(Session.messages(resumed))
        IO.puts("[resumed session #{resumed_id} (#{count} model-visible messages)]")
        loop.(loop, {resumed_id, resumed}, rest, eof?)
      end

    {:line, "/log", rest, eof?} ->
      IO.puts("[session #{session_id}: #{length(Session.messages(session))} model-visible messages so far]")
      loop.(loop, {session_id, session}, rest, eof?)

    {:line, message, rest, eof?} ->
      {:ok, run_pid, run_id} =
        AgentRun.start(
          session: session,
          session_id: session_id,
          client: llm,
          tools: tools,
          prompt: message
        )

      Task.start(fn ->
        outcome = AgentRun.await(run_pid)
        send(repl_pid, {:run_finished, run_id, outcome})
      end)

      {queued_after, eof_after?} =
        await_active_run.(await_active_run, run_pid, run_id, Enum.reverse(rest), eof?)

      loop.(loop, {session_id, session}, queued_after, eof_after?)
  end
end

loop.(loop, {session_id, session}, [], false)
