# Implementation Plan: Durable Multi-Agent Harness

Status: M1a implemented on `feat/session-foundation`; later milestones are proposed.

## 1. Direction

Build on the current Elixir code rather than reproduce all of DSH, Pi, or Lancer:

- **DSH supplies the persistence model**: a durable event log is the source of truth, with projections for consumers.
- **Pi supplies the agent-facing API**: simple loop hooks, structured messages, tool results, steering, and follow-up input.
- **Lancer supplies the orchestration vocabulary**: child threads, thread tools, evidence, result return, and supervision gates.
- **The current project supplies the foundation**: Dexterous compositions, ReqLLM, the tool registry, built-in tools, and the executor.

The internal protocol is our own versioned protocol. Full DSH V4 and Pi session compatibility are adapter concerns, not first-milestone requirements.

## 2. Goals

1. A model-visible conversation can always be reconstructed from its Session log.
2. Each Agent has an independent Session; each execution has a supervised `AgentRun`.
3. Parent/child orchestration survives process restarts and is observable from Lancer or a Web client.
4. Child creation, completion return, and cancellation have explicit recovery and idempotency semantics.
5. UI processes store presentation state only, not authoritative conversation or orchestration state.

## 3. Non-goals for the first implementation

- Complete DSH V4 admission, generation publication, Zstandard storage, or `surfaceOp` support.
- Binary or drop-in compatibility with Pi's TypeScript runtime or extension host.
- Porting Lancer's Electron application, Git evidence, checkpoints, or UI into Elixir.
- Compaction, scheduled supervision loops, subagent worktrees, and automatic recovery retries in the first slice.

## 4. Target architecture

```text
Lancer / Web clients
        │ commands, snapshots, incremental events
        ▼
Driver / Projection
        ▼
Orchestration (ordinary Elixir modules)
        ▼
AgentRunSupervisor ──► AgentRun (one process per execution)
        ▼
Session (one durable log per Agent)
        ▼
LLM.Client / Tools / Executor
```

Ownership rules:

- `Session` owns durable domain facts.
- `AgentRun` owns only transient execution state, never a second conversation history.
- `Orchestration` owns parent/child use cases and their durable transitions.
- OTP supervisors own process lifetime, not the logical Agent tree.
- Projections own read models; clients do not fold raw JSONL themselves.

## 5. Domain model

### 5.1 Identity

Keep these identities distinct:

- `session_id`: a continuable Agent conversation.
- `run_id`: one execution within a Session; a Session may have many runs.
- `child_thread_id`: a stable orchestration relationship between parent and child Sessions.
- `event_id`: stable identity of a log entry.
- `source_tool_call_id`: idempotency key for a child-creating tool call.

### 5.2 Session header

Start with a small versioned header:

```text
version, id, created_at, cwd,
parent_session?, origin?, agent_type?
```

The header is physical session metadata, not a logical event. It occupies the first record but has no `seq`; event sequence numbers and `subscribe after: seq` exclude it. Do not turn it into `seq: 0` merely to make sequence numbers equal physical line numbers.

Existing headerless logs are legacy v0. Read them through an explicit compatibility path; never mix legacy and current event shapes silently. Migration to a new file is a separate operation.

Do not add fields until a consumer requires them.

### 5.3 Event envelope

Use both log ordering and branch identity:

```elixir
%{
  seq: non_neg_integer(),
  id: String.t(),
  parent_id: String.t() | nil,
  at: integer(),
  type: atom() | String.t(),
  data: map()
}
```

- `seq` supports replay, projections, and `after: seq` delivery.
- `id/parent_id` supports branches without creating a second ordering mechanism.
- Unknown event types remain durable and are omitted from model context.

Session state must maintain `next_seq` directly and use an append-efficient representation. The current `length(events)` plus `events ++ [event]` append path is O(N) per event and must not carry into long multi-Agent sessions.

### 5.4 Messages

Move message payloads toward Pi's structured shape rather than expanding the current flat `content + tool_calls` format:

- user/system/assistant messages use typed `content` blocks;
- assistant blocks may include text, reasoning, and tool calls;
- tool results include `toolCallId`, `toolName`, `content`, `details`, and `isError`;
- provider metadata needed for faithful replay is preserved.

`Session.messages/1` remains the ReqLLM projection boundary so `LLM.Client` and tools do not depend on storage details.

**Tool batches are indivisible in the provider projection.** An assistant message carrying tool calls must be followed by every corresponding tool result before any user, steering, or orchestration-originated model-visible message. Prefer holding incoming model-visible input at the command/run boundary until the batch settles. As a final safeguard, the projection must not emit an interleaved sequence that providers reject. Durable event chronology is not rewritten; the projection constructs the valid model view from it.

Orchestration lifecycle/evidence events are not model-visible by default. A separate message event or an explicit projection rule must carry a result reference into the parent's model context.

### 5.5 Tool result protocol

The protocol has three representations. Do not conflate their error semantics:

| Layer | Representation | Purpose |
| --- | --- | --- |
| Tool callback | `{:ok, output}` or `{:error, reason}` | Keep the current Elixir tool contract and exception isolation |
| Canonical Session event | Structured `toolResult` message | Durable, provider-neutral replay and UI projection |
| Provider projection | ReqLLM tool-role message | Satisfy each provider's tool-call protocol |

A canonical result is stored in a `tool/result` event. Event payloads use string keys:

```json
{
  "seq": 7,
  "id": "evt_01...",
  "parent_id": "evt_01...",
  "at": 1790000000000,
  "type": "tool/result",
  "data": {
    "runId": "run_01...",
    "message": {
      "role": "toolResult",
      "toolCallId": "call_01...",
      "toolName": "execute",
      "content": [
        {"type": "text", "text": "1 test, 1 failure\nexit status 1"}
      ],
      "details": {},
      "isError": false,
      "timestamp": 1790000000000
    }
  }
}
```

Field ownership:

- `toolCallId` joins the result to exactly one tool call in the preceding assistant message. A result for an unknown, duplicate, or already-settled call is rejected.
- `toolName` is retained for display and provider adaptation; the call, not a fresh registry lookup, defines the intended tool.
- `content` is the model-visible result: an array of typed blocks, initially text and later image blocks where supported.
- `details` is machine/UI metadata such as an error record, delivery state, or orchestration action. It is JSON-safe and is not automatically dumped into the model context.
- `isError` describes tool settlement, not whether the model's requested operation had a business-level failure.
- `data.runId` binds settlement to the execution that accepted the call. A late result from an older run must not settle a call in a newer run.

#### Callback normalization

The initial adapter preserves the existing tool modules:

| Callback result | Canonical result |
| --- | --- |
| `{:ok, text}` when `text` is a binary | One text content block; `isError: false` |
| `{:ok, value}` for another JSON-encodable value | JSON text content block; `isError: false` |
| `{:error, reason}` | Human-readable text content, `isError: true`, and a normalized `details.error` |
| Exception/throw/exit caught by `Tools` | `isError: true` with `details.error.type: "crashed"` |
| Pre-execution denial | `isError: true` with `details.error.type: "denied"`; the tool body never runs |

Error records retain a machine-readable `type` and safe `message`; existing `unknown_tool`, `denied`, and `crashed` types remain valid. An ordinary module error may use `type: "tool"` until it has a more specific classification.

A subprocess that starts and exits with status 1 is still `{:ok, output}` and therefore `isError: false`. Its output includes `exit status 1` as today. Do not infer tool failure by parsing that text. Timeout, cancellation, denial, and infrastructure failure are tool errors because no normally settled result exists.

Later tool versions may return content/details directly, but that is an additive contract change, not part of M1a.

#### Settlement and ordering

- Every declared tool call receives exactly one terminal result, including denied, crashed, cancelled, and not-started calls.
- No next provider request is made until every call in the assistant batch has a persisted result.
- Canonical writers persist results in the assistant's original call order. If tools later run in parallel, live progress/completion events may use actual completion order. The provider projection also normalizes legacy or out-of-order logs into call order while leaving durable chronology unchanged.
- A result is appended only after its outcome is known. Cancellation before execution and cancellation after possible side effects are different records.

For interrupted calls, use explicit error metadata rather than pretending a normal result exists:

- `type: "cancelled"` with an execution state such as `not_started` when no tool body ran;
- `type: "outcome_unknown"` with `started` state when execution may have produced side effects;
- text for `outcome_unknown` tells the model to inspect state before retrying and not to repeat non-idempotent work blindly.

These synthetic results satisfy the provider protocol while preserving the run's cancellation/failure as a separate fact. They do not turn cancellation into a successful run.

#### Provider and legacy projection

The ReqLLM adapter converts `toolCallId`, `toolName`, and `content` into its tool-role message. It preserves `isError` where the ReqLLM/provider route supports it; otherwise the concise error text remains in content and the canonical event retains the full classification. `details` is omitted unless an explicit projection rule needs it.

Legacy flat `tool/result` payloads (`tool_call_id`, `name`, `output`) normalize through the same callback/content rules when read. Legacy disk records are not rewritten during replay. The old `%{ok: false, error: ...}` wrapper maps to `isError: true`; other legacy output maps remain successful JSON results rather than being mistaken for errors.

All existing output caps and UTF-8 scrubbing happen before persistence. Both successful and erroneous model-visible results remain logged.

## 6. Execution layer

### 6.1 AgentLoop

Keep the existing loop and add seams only where consumers are planned:

- `transform_context`: pruning and context injection;
- `convert_to_llm`: internal messages to ReqLLM messages;
- `prepare_request`: rebuild canonical context immediately before a request;
- `before_tool_call` / `after_tool_call`: adapt to the existing tool events;
- `finish_turn`: explicit continue/end policy.

Retain the current distinction between an outer user-task turn and inner provider steps. Document the mapping to Pi events at the driver boundary instead of renaming internal concepts for cosmetic parity.

### 6.2 Run-scoped context and events

Keep `Tool.execute(args, env)` stable, but derive the environment for every call by merging the registry's base environment with:

```text
session_id, run_id, tool_call_id
```

The same identities must accompany tool pre/post-execute events and LLM request/chunk/usage events. Callers may subscribe to a shared composition scope without mixing parallel parent/child output. Transient chunks need not be persisted merely to carry this identity.

`AgentRun` binds this context for the duration of a run. Do not create a separate Sessions supervisor or composition per child just to obtain event isolation.

### 6.3 AgentRun

Add a process for each active run:

- input: Session reference, model/client, tools, and run options;
- writes `run/start` before model work and a terminal run event on every settled outcome;
- supports cooperative cancellation and status queries;
- invokes the active ReqLLM stream's cancellation function when appropriate;
- monitors dependencies without owning durable state;
- never blindly repeats tool calls after an unknown outcome.

Use a `DynamicSupervisor` and registry for active runs. A Session without an active run remains usable and resumable.

Cancellation must cover resources below AgentRun. `Executor.Runner` must guarantee Port and OS-process-tree cleanup on cancellation and abnormal caller exit, not only on timeout. A final cleanup path must distinguish settled processes from still-live ones. Killing an AgentRun process is the last resort, not a substitute for resource-aware cancellation.

## 7. Orchestration layer

Implement Orchestration as ordinary modules calling Sessions and the run supervisor. Do not create a GenServer for every child record.

### 7.1 Log ownership

The parent Session is the orchestration ledger for its children:

- creation intent, child identity, `source_tool_call_id`, acceptance, completion evidence, and supervision decisions are appended to the parent log;
- the child Session owns its prompt, messages, tools, and run lifecycle;
- the child header records its parent and creation references;
- no third database is required for the initial design.

Writes to parent and child logs are not atomic across files. Preallocate `child_thread_id` and `child_session_id`, use explicit creation states, and recover incomplete states with those same IDs. Never recover by generating a replacement identity.

### 7.2 Initial tool contract

Keep Lancer's names and result `details.action` values where practical:

- `create_child_thread`
- `list_threads`
- `read_thread`
- `send_message_to_thread`

The tools obtain parent and call identity from their run-scoped environment and call the BEAM Orchestration API directly. Lancer's `OrchestrationOwner` must not execute the same operation a second time.

### 7.3 Create child thread

The order is significant:

1. Validate the prompt and parent Session.
2. Check the parent log for an existing `source_tool_call_id`.
3. Preallocate child identities and append `orchestration/child-create-intent` to the parent log.
4. Create the child Session with parent references, then append `orchestration/child-created` to the parent log.
5. Append the initial child prompt.
6. Start the child `AgentRun` and persist its acceptance/status.
7. Return `child_thread_id` without waiting for task completion.

Recovery reconciles intent/creation states using the preallocated identities. A crash must not cause duplicate child creation, regardless of which subsequent step was interrupted.

### 7.4 Result return

On child run settlement:

1. Record the child's own terminal run event in the child log.
2. Build a deterministic evidence ID from `child_thread_id`, `run_id`, and outcome.
3. Append the parent completion/evidence event once; uniqueness checks and append must be serialized per parent Session.
4. Notify the parent according to its supervision gate and current run state.
5. Return a summary plus references, never the child's complete transcript by default.

Parent input policy:

- running parent: queue steering or follow-up at a valid tool-batch/step boundary;
- idle parent with `wake`: start a new run;
- idle parent with `continue`: record the result and make it visible to the next run;
- `stop`: do not wake the parent.

The evidence event and the model-visible notification are separate facts with separate projection rules.

### 7.5 Cancellation

Cancellation explicitly walks persisted descendants and cancels active descendant runs. It does not rely on OTP links to kill the logical tree. User cancellation and process crash recovery are different outcomes and must be logged differently.

### 7.6 Initial orchestration events

Use a small vocabulary, for example:

```text
orchestration/child-create-intent
orchestration/child-created
orchestration/child-started
orchestration/child-completed
orchestration/child-failed
orchestration/child-cancelled
orchestration/supervision-changed
```

Add progress and evidence variants only when their writers exist.

## 8. Projections and client protocol

Provide two initial read models:

- `SessionSnapshot`: messages, tool calls, active run, and latest status;
- `OrchestrationSnapshot`: child tree, lane/run status, and result references.

The command API covers Session creation/opening, prompt submission, cancellation, and thread operations. The event API supports:

```text
snapshot
event {session_id, seq, run_id?, type, data}
subscribe after: seq
```

The same contracts may serve an Elixir-backed Lancer `SessionDriver` adapter and a Web transport. Do not expose broad filesystem or process capabilities through either transport.

## 9. Current-code disposition

### Keep with limited changes

- `DarkChonkyWhale.LLM` and `LLM.Client`
- `DarkChonkyWhale.Tool` and `Tools`
- built-in tools and `Tools.Walk`
- `Executor.Runtime` and `Executor.Runner`
- per-composition Dexterous configuration

### Rework

- `Session`: versioned header, structured messages, event identity, run/orchestration facts, and projections.
- `Sessions`: new storage layout only when required by the new header; keep open/list/close semantics where possible.
- `AgentLoop`: structured results and explicit run lifecycle.

### Add

- `AgentRun` and its supervisor/registry
- `Orchestration` and the four orchestration tools
- Session/orchestration projections
- Driver and transport adapters

## 10. Delivery milestones

### M1a — Session foundation

- Introduce the versioned physical header and current event/message shapes.
- Keep header metadata outside logical event sequence numbers.
- Read existing headerless logs through the legacy v0 path.
- Replace O(N) sequence assignment and list append.
- Introduce structured tool results and the indivisible tool-batch projection rule.
- Keep the current ReqLLM projection API and existing single-turn examples working through adapters where needed.

Exit evidence: current and legacy replay tests pass; structured tool results round-trip; steering/evidence cannot interleave inside a tool batch; existing tool/executor tests pass.

### M1b — Single-AgentRun and safe cancellation

- Add `AgentRun`, its supervisor/registry, and persisted run lifecycle.
- Thread `session_id/run_id/tool_call_id` through tool environments and LLM/tool events.
- Implement ReqLLM stream cancellation and Runner cleanup on every exit path.

Exit evidence: parallel run events retain their identities; every run settles at most once; cancellation kills live OS process trees without misreporting ordinary nonzero exits; stream and Runner cancellation tests pass alongside the existing suite.

### M2 — Child-thread orchestration

- Implement the four tools using run-scoped call context.
- Persist parent-led creation states and parent/child metadata.
- Make child creation idempotent by `source_tool_call_id`.
- Implement one-time result return and explicit recursive cancellation.

Exit evidence: parallel child runs keep isolated contexts and events; duplicate creation returns the existing child; completion is returned once; cancelling a parent cancels all descendants without conflating crash recovery.

### M3 — Recovery and projections

- Rebuild Session and orchestration snapshots from logs.
- Reconcile incomplete parent/child creation states with preallocated identities.
- Define interrupted-run behavior after BEAM restart.
- Support snapshot-plus-`after: seq` subscriptions.

Exit evidence: restart during each creation/settlement boundary does not duplicate children or evidence; clients can reconnect without a full-state divergence.

### M4 — Lancer/Web adapter

- Implement the transport and a Lancer-facing `SessionDriver` subset.
- Map internal events to Lancer-style events and orchestration projections.
- Keep Lancer's orchestration owner from taking a second authoritative write path.

Exit evidence: create/open/send/cancel/subscribe works through the adapter; child creation, result return, and cancellation are visible in the client with no direct session-file writes.

### M5 — Optional follow-up

Prioritize only after M1–M4 are stable: compaction, scheduled supervision, richer evidence, worktrees, and DSH/Pi import-export adapters.

## 11. Test strategy

Use deterministic LLM backends for orchestration tests; no live provider should be required.

Focus on behavioral contracts rather than implementation shape:

- model-visible history equals the Session projection;
- a tool-call batch never contains an interleaved user or orchestration message;
- child Sessions never leak messages into parent context;
- concurrent LLM/tool events retain Session, run, and call identity;
- a failing process produces a settled run outcome without being mislabeled as a tool error;
- side effects with unknown outcomes are never automatically retried;
- event subscriptions preserve per-Session order and resume after the requested `seq`;
- existing platform guards and executor invariants remain unchanged.

Run `mix test` after each milestone. Add focused integration tests for every recovery boundary introduced by that milestone. Test process-tree cancellation on the supported Windows and POSIX paths rather than treating timeout coverage as cancellation coverage.

## 12. Effort estimate

Assumptions: one developer comfortable with Elixir/OTP and able to read Lancer's TypeScript; focused tests are included; work is sequential. These are implementation estimates, not calendar commitments.

| Milestone | Estimated effort | Main uncertainty |
| --- | ---: | --- |
| M1a Session foundation | 3–5 developer days | Legacy compatibility and structured provider replay |
| M1b AgentRun and cancellation | 4–6 days | ReqLLM cancellation and Windows/POSIX process-tree cleanup |
| M2 Child orchestration | 5–8 days | Idempotent creation, result delivery, and boundary ordering |
| M3 Recovery and projections | 4–6 days | Crash-boundary coverage and resumable subscriptions |
| M4 Minimal Lancer/Web adapter | 6–10 days | Contract skew and disabling duplicate Lancer ownership |
| **M1–M4 total** | **22–35 developer days** | Approximately 4.5–7 focused weeks |

M4 covers a minimal end-to-end adapter and client proof, not a polished standalone Web UI. A new multi-lane Web frontend is a separate **10–20+ day** item depending on how much of Lancer's renderer can be reused. M5 is intentionally unestimated until the core protocol settles.

Reserve additional integration margin for real-provider streaming/cancellation behavior and Lancer's Alpha/Windows gaps. Do not use the lower bound as a release promise before M1b and M3 have concrete test evidence.

## 13. First concrete slice

The first implementation slice is strictly **M1a**, with no AgentRun or orchestration work:

1. Add the physical Session header and legacy v0 read path.
2. Add event identity and `next_seq`, and remove O(N) append operations.
3. Introduce structured tool results while retaining the ReqLLM projection API.
4. Enforce provider-safe tool-batch projection and add interleaving tests.

This proves the storage and message foundation before process supervision, cancellation, parent/child state, or network transports are introduced.
