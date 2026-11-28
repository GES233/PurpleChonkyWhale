# AGENTS.md — working in `noctilucent`

The personal agent application on top of `purple_chonky_whale` (read
[`../purple_chonky_whale/AGENTS.md`](../purple_chonky_whale/AGENTS.md) first —
the kernel's invariants apply here). Opinions live in this app; the kernel
stays generic.

## What's here

- `Noctilucent.Presets` — the persona presets: `coding` / `personal` / `tutor`
  compositions of model, session dir, tool set, skill directory chain and
  system prompt (`entries/2` + `system_prompt/2`). Mounts `:sandbox`
  (`PurpleChonkyWhale.Sandbox`, `:workspace_write` for coding/personal and
  `:read_only` for tutor, `network?: :on_grant`, `fail_open?: false`), mounts
  `:memory` with persona-writable (`<home>/<persona>/memory`) → global
  read-only (`~/.agents/memory`) layers, sets `require_grant?: true`,
  `require_sandbox?: true`, `sandbox`, and `protected_dirs`/`allowed_runtimes`
  on `:tools`, mounts `:policy` (`Noctilucent.Policy`), and derives the
  `:tools` env's `vision?` from the model's LLMDB input modalities (unknown
  models fail open). `:mcp_servers`, `:policy_opts`, and `:sandbox_opts` pass
  through to their entries. Persona isolation falls out of the composition:
  separate session dirs, tool sets, policy leases, sandbox configs and scopes.
- `Noctilucent.Policy` — the `:policy` component (`provide: [:policy]`) and a
  thin adapter over `apps/clearance`. It starts `Clearance.Policy` with this
  app's opinions only: the shared `Clearance.Lint` analyzers for `execute`,
  `runtime: "elixir"` forced to ask (it evaluates in this BEAM), protected
  dirs derived from the persona `home`, and the CLI's `:ask` option mapped to
  Clearance's `:asker`. The ladder, leases, prompt serialization and the
  shell/AST rules live in `apps/clearance`; mount `Clearance.Component`
  directly when you want a different asker.
- `Noctilucent.CLI` — the terminal REPL (`mix noctilucent`, see
  `lib/mix/tasks/noctilucent.ex`). Multi-turn over one session log, slash
  commands `/quit` `/cancel` `/steer` `/reset` `/sessions` `/resume` `/log`
  `/grants` `/revoke`, inline interactive tool approval prompts (`[y]` once,
  `[l]` 15m capability lease, `[n]` deny), and
  inline image attachments via `@path/to/img.png` (truncated trailing
  punctuation is stripped from tokens; corrupt/truncated images are skipped
  with a notice via the read tool's `valid_image_data?/2`). A fresh session is seeded with the
  persona's system prompt plus the recalled memory as a second
  `system/message` (recalled memory is model-visible, therefore logged);
  resumed sessions keep their log untouched. Rendering is driven by seam
  events (`llm/chunk`, `tools/post-execute`, `tools/todo`, `memory/remember`),
  not by the loop.
- `examples/image_demo.exs` — one-shot image-reading demo against a live
  provider.

## Conventions

- Entry point: `mix noctilucent [options]` from the umbrella root (the root
  `.env` is picked up for API keys). `--base-url` covers relays, e.g. the
  Kimi coding endpoint:
  `mix noctilucent -m anthropic:kimi-for-coding --base-url https://api.kimi.com/coding`
- The coding persona wires `DexterousHMR` for its `recompile` tool; other
  personas don't need it.
- State lives under `~/.pcw` by default: `sessions/<persona>/` (plus `blobs/`
  per session dir), `<persona>/skills/` and `<persona>/memory/MEMORY.md`;
  the global read-only memory layer is `~/.agents/memory/MEMORY.md`.
- `examples/` is excluded from `mix format` (each app's `.formatter.exs`
  covers only `{lib,test}/**`).
