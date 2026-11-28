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
- `Noctilucent.Policy` / `Noctilucent.Policy.ShellLint` / `Noctilucent.Policy.Ast.*` —
  application-level permission policy component (`provide: [:policy]`) hooked
  onto `tools/pre-execute`. `ShellLint` dispatches by runtime: Elixir
  (`"elixir"` / `"elixir_subprocess"`) uses native `Code.string_to_quoted/2`
  (`Ast.Elixir`); PowerShell uses .NET `Parser::ParseInput` (`Ast.PowerShell`)
  and Python uses stdlib `ast.parse` (`Ast.Python`) through lazy, read-only
  persistent stdio Port workers (`Ast.Worker`, supervised under
  `Noctilucent.Supervisor`, failing closed to regex + `:ask` if unavailable);
  `"shell"` uses static regex. All analyzers share `TargetRules` to block
  catastrophic commands (`$home = ...` including scoped/destructured forms,
  root/home/protected_dirs wipes, pipe-to-shell, `.NET`/Python/Elixir home or
  credential destruction) while avoiding false positives in comments/strings,
  and escalate high-risk or dynamic operations (`rm -rf`, `git reset --hard`,
  network/install, dynamic eval/invocation, `ErrorActionPreference` overrides,
  `runtime: "elixir"`) to one-shot confirmation. `Policy` auto-allows
  `[:fs_read, :ui, :memory]`, manages bounded TTL capability leases
  (`%Security.Grant{}`), and serializes concurrent interactive approval prompts.
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
