# 紫色大肥鱼 (umbrella)

An Elixir agent harness and the applications built on it.

- [`apps/purple_chonky_whale`](apps/purple_chonky_whale/README.md) — the
  harness library: durable session log, three pluggable seams (`:llm`,
  `:sessions`, `:tools`), the agent loop and run supervision. This is the
  integration surface for everything else.
- `apps/noctilucent` — the personal agent application (personas, personal
  interaction surface).
- `apps/nacreous` — the work agent application (multi-user, project
  progress).

Run everything from the umbrella root: `mix test`, `mix format`.
