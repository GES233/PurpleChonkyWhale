# AGENTS.md — working in `purple_chonky_whale`

"Elixir's DSH implementation" (`README.md`), named after the 「紫色大肥鱼」 meme:
a coding agent whose whole world is a durable session log, three pluggable
seams, and a small set of plain-module tools. Everything below was read out of
this tree; nothing is aspirational.

## Commands

```sh
mix compile            # deps are vendored under deps/; Dexterous apps come from a sparse checkout
mix test               # 130 tests / 1 doctest, ~5s; runtimes are skipped when absent
mix format             # .formatter.exs covers mix.exs, config/, lib/, test/ — NOT examples/
```

Run things without config: `mix run examples/session_demo.exs` needs no network.
`examples/smoke_llm.exs`, `examples/agent.exs`, `examples/multi_turn_agent.exs`
hit a live provider (API keys come from the gitignored `.env`, auto-loaded by
ReqLLM; `examples/agent.exs` defaults to `deepseek:deepseek-flash`).

## Architecture: three seams + one driver

A *composition* is a Dexterous `Context` scope + `DexterousLoader.Entry`
records. Coeffects are the seam handles; provisions are declared with
`use Dexterous.Component, provide: [...]`. Nothing global: a component's config
is given per entry, e.g. in `examples/agent.exs`.

| Seam | Provider (component) | Provision | Events |
| --- | --- | --- | --- |
| `:llm` | `PurpleChonkyWhale.LLM` (config `:model` required; other keys pass through to ReqLLM) | `%LLM.Client{}` | `llm/request` (waterfall), `llm/chunk`, `llm/usage` (emits) |
| `:sessions` | `PurpleChonkyWhale.Sessions` (config `:dir` required) | `%Sessions{}` | `session/event` (emit, per append) |
| `:tools` | `PurpleChonkyWhale.Tools` (config `:tools`, `:env`) | `%Tools{}` registry | `tools/pre-execute` (waterfall over `%{name:, arguments:, decision:}`), `tools/post-execute` (emit) |
| `:memory` | `PurpleChonkyWhale.Memory` (config `:layers`) | `%Memory{}` | `memory/recall`, `memory/remember` (emits) |

`PurpleChonkyWhale.AgentLoop.run/4` is the driver: it seals any tool calls left
unsettled by an interrupted turn, logs `turn/start`, then loops over
`step/start`, stream via `Client.stream/3`, `assistant/message`, execute each
tool call through `Tools.execute/3` (a batch runs concurrently, capped by
`:tool_concurrency`, default `System.schedulers_online()`), `tool/result` —
until a final answer, `:max_steps_exceeded` (default 100), or a hit on its
`:should_cancel?` predicate. Its `after` block stops in-flight stream/tool
tasks, seals dangling calls and appends `turn/end`, so a dying session cannot
mask the real error. The loop keeps **no history of its own** — the model's
view is exactly `Session.messages/1`.

`PurpleChonkyWhale.AgentRun.start/1` wraps one driver call in a supervised
`GenServer` (`restart: :temporary`): it binds `session_id`/`run_id` across LLM
and tool events, writes `run/start` before model work, settles **once** with a
single `run/{completed,failed,cancelled}` event, and exposes `await/2`,
`cancel/2` (cooperative stream + subprocess cancellation) and `steer/2`.
Applications start a default registry and supervisor; a composition may mount
`AgentRunSupervisor` as its `:runs` component instead.

The executor is a fourth, internal seam: `Tools.Executor` (model-facing
surface) → `Executor.Runtime` behaviour (`run/2`) → a *plan* → `Executor.Runner`
(the only place a subprocess is actually spawned and only place that touches a
temp file).

## Module map

- `PurpleChonkyWhale` — placeholder `hello/0` + doctest; `Application` starts the
  default `AgentRunRegistry` and `AgentRunSupervisor`.
- `AgentRun` / `AgentRunSupervisor` — supervised per-execution process and its
  supervisor/registry (`:runs` when mounted as a component). `start/1`,
  `await/2`, `cancel/2`, `steer/2`, `status/1`; every run settles at most once,
  and terminal state is durable even though the process is `:temporary`.
  `start/1` accepts `:parts` to attach content parts (e.g. images) to the
  prompt's `user/message` event.
- `LLM` / `LLM.Client` — component and the client consumers get. `:backend`
  defaults to `ReqLLM` and is swapped for a fake in tests.
- `Sessions` / `Session` — store handle and the append-only JSONL log
  (`GenServer`). V1 files have a physical header followed by events with
  `seq`/`id`/`parent_id`/`at`; headerless v0 files retain their disk shape.
  The log persists before advancing memory, replays on open, and broadcasts
  every append. A `user/message` may carry `"userId"` to mark the speaker in
  multi-actor logs (the projection prefixes it); single-user logs omit it.
  Binary image parts never enter the JSONL: append externalizes them to
  content-addressed files under `<dir>/blobs/`, the event keeps a
  `%{"type" => "image", "blob", "mediaType", "bytes"}` reference, and
  projection rehydrates the bytes (a missing blob degrades to a text
  placeholder, never a projection failure). This applies to any event;
  `user/message` attachments ride the optional `"parts"` key and project to
  a multi-part user message.
- `Presets` — **moved to the `noctilucent` app** (`Noctilucent.Presets`):
  persona compositions are application policy, not kernel. The kernel keeps
  only the conventions the presets rely on: the `:tools` env keys `:cwd`,
  `:skill_dirs` and `:vision?` (whether the model accepts image input).
- `Memory` — the `:memory` seam: layered file-backed memory, one `MEMORY.md`
  per layer directory, ordered most-specific-first. `recall/1` concatenates
  layers (per-layer byte cap, truncation noted) for the caller to log as a
  `system/message`; `remember/2` appends one dated line to the innermost
  writable layer (layers default to read-only); `update_many/2` rewrites
  matching lines atomically (all matches validated before writing),
  `delete/2` removes matching lines. `Tools.Memory` (`memory_save`),
  `Tools.MemoryUpdate` (`memory_update` — a batch list, so one call covers
  update-many) and `Tools.MemoryDelete` (`memory_delete`) reach the handle
  through the scope carried in the tools env.
- `ToolResult` — converts callback results to the canonical `toolResult`
  message (`content`, `details`, `isError`) and projects them to ReqLLM.
  `{:ok, {:parts, parts}}` outputs (built with `text_part/1` / `image_part/2`)
  become multi-part `content`; image parts project to `ContentPart.image/2`.
- `Tools` — registry + guarded pipeline (`lookup/2`, `schemas/1`,
  `execute/3`); typed results `{:ok, _}` | `{:error, %{type:, message:}}` with
  `:type ∈ {:unknown_tool, :denied, :crashed}`.
- `Tool` — the tool contract (`schema/0`, `execute/2`) plus `resolve_path/2`.
- `Tools.{Read, Write, Edit, Glob, Grep, Executor, TodoWrite, Skill, Recompile}` — the built-ins.
  `Read` returns image files (png/jpeg/gif/webp, ≤ 5 MB) as viewable image
  parts, or a text description when the env's `vision?` is false or the bytes
  fail the structural check of `valid_image_data?/2` (PNG signature+IEND,
  JPEG SOI/EOI, GIF header+trailer, WebP RIFF header — corrupt/truncated
  files must never enter the session log: one bad image makes the provider
  reject every later request); its `image_media_type/1` / `max_image_bytes/0`
  / `valid_image_data?/2` helpers are public so front ends (e.g. the
  Noctilucent CLI's `@path` attachments) share the same policy.
  `Tools.Walk` is the shared deterministic, symlink-safe, prune-aware walk and
  glob compiler used by `glob`/`grep`; `TodoWrite` also emits `:"tools/todo"`.
- `Executor.Runner` — port executor: merges stdout/stderr, treats a settled
  process as a result (`exit status N` appended), kills the whole tree on
  timeout, caps output head+tail, normalizes EOL, transcodes OEM-codepage bytes.
- `Executor.Runtimes.{Shell, PowerShell, Python, Elixir, ElixirSubprocess}` —
  each a `Executor.Runtime`; all but `Elixir` build plans (script content plus
  the `:script` placeholder) for `Runner`, while `Elixir` evaluates in-process
  with a stand-in group leader capturing IO.

## Invariants to respect

- **Tools never raise into the pipeline.** Return `{:ok, output}` /
  `{:error, reason}`; `Tools.execute/3` rescues/catches anything else as
  `:crashed`. Model-supplied args are string-keyed maps; env values are read
  with Access (`env[:cwd]`) because direct callers may pass a keyword list.
- **A failing process is not a tool error.** Only a timeout is `{:error, _}`
  in the executor; a failing test run comes back `{:ok, output}` with
  `exit status N`. Its canonical tool result therefore has `isError: false`.
- **Nothing invalid-UTF-8 may reach JSON.** `Session` scrubs payloads on
  append; `Runner.decode_as/2` transcodes/scrubs console bytes. Tool output is
  persisted as JSON, which would refuse invalid bytes outright.
- **Model-visible means logged.** The only projection is `Session.messages/1`;
  markers (`turn/start`, `step/start`, …) and unknown event types are durable
  but skipped. Event payloads use **string** keys in `data`.
- **Tool batches are provider-safe.** Each declared call has at most one result
  per batch; results project in assistant call order, deferred user/assistant
  input follows the complete batch, and projecting an unsettled batch raises
  instead of emitting an invalid provider request (`Session.seal_unsettled/2`
  seals interrupted batches with synthetic error results).
- **Plans are plain data; runtimes never touch the filesystem.** A plan is
  `%{exe, args, cwd, script}` where `script` is *content* and the `:script`
  atom marks where its path belongs; `Runner.run/2` writes it to a fresh temp
  dir and cleans up. Keep it that way — it is the documented opening for a
  remote/sandbox runner.
- **Moduledocs are the design record.** Modules carry long "why" comments
  (platform gotchas, WSL, codepages, HMR). Update them together with behaviour.
  Constants that moduledocs interpolate are declared *before* the moduledoc
  (`Executor`, `Runner`, `Walk`, `PowerShell`) — keep that order.
- **Config is per composition.** There is no global tool registry; a new tool
  must be added to the `tools:` list of each composition (see the `examples/`).

## Pitfalls

- `runtime: "elixir"` runs in *this* BEAM: no isolation, side effects are not
  undoable, a timeout only stops the damage. `elixir_subprocess` is the
  isolated one.
- Agent runs are `restart: :temporary` on purpose: an interrupted run's
  in-flight tool calls may have unknown side effects, so OTP must never
  restart it. Resume by starting a new run on the same session log.
- `recompile` needs `Mix.env() == :dev` under `mix run`; it starts
  `DexterousHMR` lazily and refuses cleanly elsewhere. Tests override it with
  `:dexterous_hmr`'s `:compile_fun` config and must restore "absent" with
  `Application.delete_env/2` (`put_env(key, nil)` breaks `Keyword.get`).
- `DexterousHMR` is a named singleton; `test/.../recompile_test.exs` stops it
  in `on_exit`. Keep that hygiene for any test touching it.
- `Context.use/3` is asynchronous: tests and examples poll `Context.get/2` (see
  the `eventually/await` helpers) instead of assuming the provision is bound.
  Tests that use a shared scope / named process are `async: false`.
- Platform guards are load-bearing: POSIX-shell tests are wrapped in
  `if sh = posix_shell()`, symlink tests in `with :ok <- File.ln_s(...)`, and
  codepage assertions branch on the machine's `chcp`. Do not "simplify" them.
- Windows specifics, all deliberate: a `bash.exe` under `%SystemRoot%` is the
  WSL launcher and is refused; `cmd.exe` loses grandchildren's output (and
  quoted commands go through a temp `.cmd` instead); PowerShell scripts get a
  UTF-8 BOM and `-File`; Python is pinned to `PYTHONIOENCODING=utf-8` unless the
  composition's `:shell_env` overrides it.
- Codepagex only compiles the pages whitelisted in `config/config.exs`; adding
  one means changing that list and recompiling `codepagex`.
- `.formatter.exs` inputs exclude `examples/`; formatting them is not covered
  by `mix format`.
- `Tools.Walk` prunes by directory *name* (`.git`, `_build`, `deps`, `.bloop`,
  `build`, `target`, …) plus `.gitignore`/`.ignore` rules and never follows
  symlinked dirs; override per call with `env[:search_ignore_dirs]` (`[]`
  disables all pruning and walks everything reachable).
