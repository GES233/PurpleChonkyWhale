# AGENTS.md — umbrella root

This is an umbrella project. The harness library and its design record live
in [`apps/purple_chonky_whale`](apps/purple_chonky_whale/AGENTS.md) — read
that file before working in `apps/purple_chonky_whale`.

Apps:

- `apps/purple_chonky_whale` — the agent harness library (kernel + seams +
  built-in tools). All architecture invariants are documented in its
  AGENTS.md.
- `apps/noctilucent` — the personal agent application, depends on
  `purple_chonky_whale` via `in_umbrella: true`. Owns the persona presets
  (`Noctilucent.Presets`: coding / personal / tutor compositions of model,
  session dir, tool set and skill chain).
- `apps/nacreous` — the work agent application, same dependency.

Umbrella-level rules:

- Run `mix test` / `mix format` from this root; formatting is governed by the
  root `.formatter.exs` (`subdirectories: ["apps/*"]`) plus each app's own
  `.formatter.exs`. `apps/*/examples/` is intentionally excluded from
  formatting.
- Shared compile-time config (e.g. the codepagex whitelist) lives in the root
  `config/config.exs`; app-specific config goes under each app.
- Dependencies are vendored at the root `deps/`; Dexterous apps come from a
  sparse git checkout. `anubis_mcp` (+ its hard dep `peri`) backs the MCP
  client used by `PurpleChonkyWhale.MCP`.
