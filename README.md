# 黑色大肥鱼

> The name riffs on a moe-anthropomorphism meme on the Chinese internet that
> nicknamed DeepSeek's whale logo 「蓝色大肥鱼」 — "the blue chonky whale".
> This is the dark variant.

Elixir's DSH implementation.

## Multi-turn harness

Start the interactive coding harness in this repository:

```sh
mix run examples/multi_turn_agent.exs
```

Point it at another workspace with `--cwd`; the harness keeps running from
this Mix project while all relative file tools and commands use the selected
workspace. Name the session log with `--session` to resume it later:

```sh
mix run examples/multi_turn_agent.exs -- --cwd D:/CodeRepo/SelfAssistant/hoi
mix run examples/multi_turn_agent.exs -- --cwd ../another-project --session refactor openai:gpt-5
```

Each line read from stdin is one turn. The conversation lives in one JSONL
log under `~/.dark_chonky_whale/sessions`, so later turns — including after
`/resume` or a restart with `--session` — see everything earlier turns did.
A line starting with `/` is a command:

| Command | Effect |
| --- | --- |
| `/quit`, `/exit` | End the session |
| `/cancel` | Cooperatively cancel the active turn |
| `/steer TEXT` | Append a steering message to the active turn |
| `/reset` | Switch to a fresh session log (the old one stays on disk) |
| `/sessions` | List saved session ids |
| `/resume ID` | Switch to, or reopen, session `ID` |
| `/log` | Print the model-visible message count |

A turn runs as a supervised `DarkChonkyWhale.AgentRun`, so the REPL stays
responsive while tools execute: `/cancel` stops the in-flight model stream and
tool subprocesses, and `/steer` reaches the run without waiting for it. The
harness seals any tool calls left unsettled by an interrupted run when it
reopens a log.

The model remains optional and defaults to `deepseek:deepseek-flash`. Run with
`-- --help` for the complete command-line usage.

## Programmatic use

`DarkChonkyWhale.AgentRun.start/1` runs one turn as a supervised process and
returns `{:ok, pid, run_id}`; `await/2` returns the terminal outcome,
`cancel/2` stops it cooperatively, and `steer/2` appends a user message to the
live session. `status/1`, `run_id/1` and `AgentRunSupervisor.lookup/2` cover
the rest. The driver underneath is `DarkChonkyWhale.AgentLoop.run/4`, which
takes the client, session, tools, and options such as `:max_steps`,
`:tool_concurrency` and `:should_cancel?`.

## Built-in tools

Each tool is a plain module implementing `DarkChonkyWhale.Tool`; list the ones
a composition wants in the `:tools` component's config.

| Tool | Module | What it does |
| --- | --- | --- |
| `read` | `DarkChonkyWhale.Tools.Read` | Read a file with line numbers, paged |
| `write` | `DarkChonkyWhale.Tools.Write` | Create or overwrite a file |
| `edit` | `DarkChonkyWhale.Tools.Edit` | Replace a unique string, line-ending aware |
| `glob` | `DarkChonkyWhale.Tools.Glob` | Find files by pattern (`*`, `?`, `**`) |
| `grep` | `DarkChonkyWhale.Tools.Grep` | Search file contents by regex |
| `execute` | `DarkChonkyWhale.Tools.Executor` | Run code in a runtime (shell command, PowerShell, Python, Elixir in-process or in a fresh VM) with a timeout and an output cap |
| `todo_write` | `DarkChonkyWhale.Tools.TodoWrite` | Record and update the multi-step task checklist |
| `skill` | `DarkChonkyWhale.Tools.Skill` | Discover and load `SKILL.md` instruction packages on demand |
| `recompile` | `DarkChonkyWhale.Tools.Recompile` | Recompile and hot-swap changed modules (dev only, via `dexterous_hmr`) |

`glob` and `grep` share `DarkChonkyWhale.Tools.Walk`: a deterministic,
symlink-safe walk that prunes build output and vendored directories
(`.git`, `_build`, `deps`, `node_modules`, …). Override the prune list per
composition with the tool env's `:search_ignore_dirs`.

`execute` runs code in one of five runtimes, chosen by its `runtime`
argument:

- `shell` (default) — a shell command through the platform shell
  (`bash -c`/`sh -c` on POSIX; the first `bash`/`sh` on `PATH` on Windows,
  with `cmd.exe /c` as the last resort), with stderr merged and, on POSIX,
  stdin closed, so a command that would prompt gets EOF instead of hanging.
- `powershell` — the code as a `.ps1` script through `pwsh`, or
  `powershell` where that is what the machine has.
- `python` — the code as a `.py` script through `python3`/`python`.
- `elixir` — the code evaluated in the agent's own BEAM, where it can see
  and touch the live system; nothing is isolated, and a timeout kills the
  evaluation but cannot undo its side effects.
- `elixir_subprocess` — the code as an `.exs` script through the `elixir`
  CLI, in a fresh VM.

A run that fails is a normal result (`exit status N` is appended); only a
run that outlives its timeout is an error, and it is killed. The tool env
can fix the `:shell`, `:powershell`, `:python` and `:elixir` programs
(`:elixir` covers both Elixir runtimes), plus `:shell_timeout_ms`,
`:shell_env` and `:max_output_bytes` defaults; each call can override the
timeout and the cap.
