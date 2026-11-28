# clearance

Authorization for agent tool calls in this umbrella: it decides **whether** a
call may run. It is the sibling of two things it deliberately does not own:

| concern | owner |
| --- | --- |
| the value of a decision | `PurpleChonkyWhale.Security.Grant` (kernel) — the `{:allow, %Grant{}}` a `:"tools/pre-execute"` listener returns |
| the barrier after a decision | `PurpleChonkyWhale.Sandbox` (kernel) — how an OS process is confined |
| the decision itself | **clearance** |

Dependency direction is a straight line, no cycle:

```
purple_chonky_whale  ←  clearance  ←  { noctilucent, nacreous }
```

Two applications share this app and differ only in their asker: Noctilucent
prompts a human, Nacreous denies everything it cannot auto-allow or cover with
a lease.

## The ladder

`Clearance.Evaluate.run/3` is a pure function over a policy snapshot, so the
decision order is testable without a process:

1. a `:deny` lint verdict is final — no lease, no prompt, no override
2. a capability covered by `:auto_allow` passes
3. an unexpired lease covering the call passes
4. no asker configured → deny (non-interactive, fail-closed)
5. otherwise → ask

Steps 2 and 3 are skipped for **high-risk** calls: an `:unknown` or `:mcp`
capability, a lint `:ask` verdict, or a `:force_ask?` hit. A high-risk call can
never create a standing lease, so it cannot widen its own future permissions.

`Clearance.Policy` only owns state and ordering: the lease list, the single
in-flight prompt, and a FIFO of waiting callers. When a prompt resolves, queued
calls are re-evaluated first, so a lease granted by the earlier answer is
reused instead of asking again.

## Wiring

As a composition entry (it provides `:policy`):

```elixir
%Entry{
  id: :policy,
  component: Clearance.Component,
  config: [
    asker: Clearance.Asker.DenyAll,   # or a function (see below)
    lint: &Clearance.Lint.inspect/2,
    lint_tools: ["execute"]
  ]
}
```

Or into an existing composition:

```elixir
{:ok, policy} = Clearance.Policy.start_link(asker: &MyApp.ask/1)
{:ok, _disposer} = Context.on(ctx, :"tools/pre-execute", Clearance.listener(policy))
```

`Clearance.listener/1` fills `call.decision` and calls the next listener; it
narrows nothing itself. The kernel's pipeline stays monotonic: once a `:deny`
is set, nothing later can turn it back into an allow.

## Askers

An asker is `(request -> choice)` and runs in its own monitored process:

| answer | meaning |
| --- | --- |
| `:once` | allow this call only |
| `{:lease, ttl_ms}` | allow, and store a lease for the call's leaseable capabilities |
| `:deny` | refuse |
| `{:allow, %Grant{}}` | use a pre-built grant, honoured only if it covers the call |

Anything else, a raise, or an exit counts as `:deny`. The request map
(`Clearance.Request.build/3`) carries `:tool`, `:arguments`, `:capabilities`,
`:summary`, `:warnings`, `:high_risk?`, `:network_requested?`,
`:leaseable_capabilities`, `:default_lease_ms`, and correlation ids.

`Clearance.Asker.DenyAll` is the headless default: auto-allow and
`grant_lease/3` still work, nothing interactive is ever approved.

## Lint

`Clearance.Lint` dispatches on the `execute` call's `runtime`:

- `"elixir"` / `"elixir_subprocess"` — `Code.string_to_quoted/2` in this BEAM
- `"powershell"` — .NET `Parser::ParseInput`
- `"python"` — stdlib `ast.parse`

PowerShell and Python run through lazy, read-only persistent Port workers
(`Clearance.Lint.Ast.Worker`) supervised by `Clearance.Application`; no
executable is located until the first parse. When a parser is unavailable the
analyzer falls back to the regex rules and escalates to `:ask` rather than
silently returning `:ok`. `Clearance.Lint.TargetRules` is the shared path
classification (roots, OS dirs, home, credential stores, protected dirs).

## Options

`Clearance.Policy.start_link/1` (and `Clearance.Component` config):

| option | default | meaning |
| --- | --- | --- |
| `:asker` | `nil` | `(request -> choice)`; `nil` denies anything needing approval |
| `:auto_allow` | `[:fs_read, :ui, :memory]` | capabilities allowed without asking |
| `:lease_ttl_ms` | `15 * 60_000` | default TTL for an asker-granted lease |
| `:initial_leases` | `[]` | capability, `{caps, ttl_ms}`, or `%Grant{}` |
| `:lint` | `nil` | `(args, opts -> assessment)` |
| `:lint_tools` | `[]` | tool names the lint applies to |
| `:force_ask?` | `fn _, _, _ -> false end` | `(name, args, caps -> boolean)` |
| `:approval_caps` | `[:unknown, :mcp]` | capabilities that always require approval |
| `:protected_dirs` | `[]` | passed to the lint as `:protected_dirs` |

## Tests

```sh
mix test apps/clearance/test
```

The AST tests need a real `pwsh`/`python`; without one they degrade to regex.
That path is covered by the fallback assertions, so the suite stays green
either way.
