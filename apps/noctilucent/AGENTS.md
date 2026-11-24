# AGENTS.md — working in `noctilucent`

The personal agent application on top of `purple_chonky_whale` (read
[`../purple_chonky_whale/AGENTS.md`](../purple_chonky_whale/AGENTS.md) first —
the kernel's invariants apply here). Opinions live in this app; the kernel
stays generic.

## What's here

- `Noctilucent.Presets` — the persona presets: `coding` / `personal` / `tutor`
  compositions of model, session dir, tool set, skill directory chain and
  system prompt (`entries/2` + `system_prompt/2`). Derives the `:tools` env's
  `vision?` from the model's LLMDB input modalities (unknown models fail
  open). Persona isolation falls out of the composition: separate session
  dirs, tool sets and scopes.
- `Noctilucent.CLI` — the terminal REPL (`mix noctilucent`, see
  `lib/mix/tasks/noctilucent.ex`). Multi-turn over one session log, slash
  commands `/quit` `/cancel` `/steer` `/reset` `/sessions` `/resume` `/log`,
  inline image attachments via `@path/to/img.png` (truncated trailing
  punctuation is stripped from tokens). Rendering is driven by seam events
  (`llm/chunk`, `tools/post-execute`, `tools/todo`), not by the loop.
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
  per session dir) and `<persona>/skills/`.
- `examples/` is excluded from `mix format` (each app's `.formatter.exs`
  covers only `{lib,test}/**`).
