# Phase 6 Spec — Message Persistence / Resume (#1) and Event Stream (#4)

Status: in progress
Derived from: pi.dev harness analysis (session durability + observable event stream)

## Motivation

Two gaps identified against Pi's harness fundamentals:

1. **No message persistence.** `GraphEngine#execute` builds `messages` in process
   memory only. When a HITL gate pauses a run there is nothing to resume from, so
   `Riggs::Web::App#apply_session_decision` (lib/riggs/web/app.rb:370) records an
   approval and sets status `approved_pending_resume` — then drops the run on the
   floor. README:200 already admits this.
2. **No event stream.** `POST /api/workflows/:name/run` blocks until the run ends.
   `riggs_audit` is already an ordered append-only event log but is only readable
   as a complete dump after the fact (`GET /api/sessions/:id/audit`).

## Non-goals

- Mid-tool-loop resume. A gate pauses *before* its step executes
  (graph_engine.rb:80–95 runs before `resolve_context` at :97), so resume replays
  from the start of the gated step. Partial-step state is never restored.
- CLI `--mode json` event output. Deferred; HTTP only in this phase.
- Compaction / token accounting (#2, #3). Separate phase.
- Any change to RBAC permission names.

## Shared foundation (owned by lead, landed before feature work)

Files: `db/init_riggs_schema.sql`, `lib/riggs/storage.rb`, `test/test_storage.rb`

### Schema additions

```sql
CREATE TABLE IF NOT EXISTS riggs_messages (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id   TEXT NOT NULL REFERENCES riggs_sessions(id),
  step_key     TEXT NOT NULL,
  seq          INTEGER NOT NULL,
  role         TEXT NOT NULL,       -- user | assistant | tool | system
  content      TEXT,
  tool_call_id TEXT,
  tool_name    TEXT,
  tool_calls   TEXT,                -- JSON array, assistant turns requesting tools
  provider     TEXT,
  created_at   DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_riggs_messages_session ON riggs_messages(session_id, seq);
```

`riggs_sessions` gains `resume_state TEXT` (JSON blob, nullable). Added
idempotently via `ALTER TABLE` guarded by a `PRAGMA table_info` check, because
`CREATE TABLE IF NOT EXISTS` will not alter existing databases in the field.

### Storage API (already implemented — agents consume, do not modify)

```ruby
append_message(session_id:, step_key:, role:, content:, seq: nil,
               tool_call_id: nil, tool_name: nil, tool_calls: nil, provider: nil) # => Integer id
list_messages(session_id, step_key: nil)   # => rows ordered by seq ASC
next_message_seq(session_id)               # => Integer (max(seq)+1, 1-based)
save_resume_state(session_id, state)       # state: Hash -> JSON
load_resume_state(session_id)              # => Hash with symbol keys, or nil
list_audit_after(session_id, after_id, limit: 500)  # id > after_id, ASC
```

`seq` is per-session and monotonic. When omitted, `append_message` allocates the
next value inside the same transaction as the insert.

## Feature #1 — Message persistence and resume

Owner: agent A.
Files: `lib/riggs/workflow/graph_engine.rb`, `lib/riggs/workflow/tool_loop.rb`,
`lib/riggs/cli/commands.rb`, `test/test_graph_engine.rb`, `test/test_resume.rb`.

### R1.1 Persist every turn

Each message added to the conversation is written via `append_message` with the
owning `step_key`, at the time it is added — not batched at step end.

- The resolved user input for a step → `role: "user"`.
- Each assistant reply → `role: "assistant"`, `provider:` set to the provider that
  actually answered (`outcome[:provider]`; relay-chain failover must record the
  provider that succeeded, not the first one tried). Tool requests serialize into
  `tool_calls` as JSON.
- Each tool result → `role: "tool"` with `tool_call_id` and `tool_name`.

`ToolLoop` receives a persistence callback rather than a `Storage` handle, matching
the existing injected-callable style of `audit:` (tool_loop.rb:10). Signature:

```ruby
persist: ->(role:, content:, step_key:, tool_call_id: nil, tool_name: nil,
            tool_calls: nil, provider: nil) { }
```

A nil `persist:` is valid and disables persistence (keeps existing unit tests and
any embedding host working).

### R1.2 Pause

`gate_handler` may now return `:paused` in addition to `:approved` / `:rejected`.
On `:paused` the engine must:

1. `save_resume_state(session_id, {current_step_id:, outputs:, llm_calls:, input:})`
2. `update_session(session_id, status: "paused")` — not ended
3. audit `gate_pause` with `{step:, resumable: true}`
4. set `@status = :paused` and return `self` without raising

Unknown gate return values keep current behavior (treated as approved) — no new
failure mode.

### R1.3 Resume

```ruby
Riggs::Workflow::GraphEngine.resume(session_id:, user_identity:, workflow:,
                                    db_path:, hub_config: {}, gate_handler: nil,
                                    skill_registry: nil, mcp_manager: nil, io: $stdout)
```

- Raises `WorkflowError` if the session is missing, has no `resume_state`, or its
  status is not `paused`.
- Rebuilds `@outputs` and `@llm_calls` from the stored state, then continues the
  step loop from `current_step_id`. The gate on that step is treated as already
  approved and must not re-prompt.
- Reuses the existing `session_id` — no new session row. New audit events and
  messages append to the same session, so `seq` continues from where it stopped.
- Audits `workflow_resume` with `{step:, llm_calls:}` on entry.
- `max_llm_calls` and `timeout_seconds` are enforced against the restored counter;
  `timeout_seconds` restarts from the resume instant (documented, not a bug).
- Clears `resume_state` once the run leaves `paused`.

### R1.4 CLI

`riggs workflow:resume <session_id> [--user=<key>]`

- Requires `run_workflow` (same permission as `workflow:run`).
- Resolves the workflow name from the session row, loads its YAML, calls `resume`.
- Prints the same step output format as `workflow:run`.
- Non-zero exit and a clear message when the session is not resumable.

### R1.5 Tests

- A gate handler returning `:paused` leaves session status `paused`, writes
  `resume_state`, and executes no further steps.
- `resume` on that session completes the workflow and ends at status `completed`.
- Messages for a completed 2-step run are ordered, `seq` is gapless from 1, and
  roles match the turn order.
- Tool-calling step persists an assistant row with non-null `tool_calls` and a
  matching `tool` row with the same `tool_call_id`.
- Resume on a non-paused session raises `WorkflowError`.
- Messages appended after resume continue the seq series without collision.

## Feature #4 — Event stream

Owner: agent B.
Files: `lib/riggs/events.rb` (new), `lib/riggs/web/app.rb`,
`lib/riggs/web/views/session_show.erb`, `test/test_events.rb`, `test/test_web_app.rb`.

### R4.1 Event formatter

`Riggs::Events.normalize(audit_row)` maps a `riggs_audit` row to:

```ruby
{ id: Integer, type: String, session_id: String, at: String, payload: Hash }
```

`payload` is parsed from its stored JSON; a malformed payload yields
`{ "raw" => <original string> }` rather than raising. `Riggs::Events.to_jsonl(row)`
returns the same object as a single-line JSON string with no trailing newline.

### R4.2 Poll endpoint

`GET /api/sessions/:id/events?after=<id>&limit=<n>`

- Requires `inspect_run`.
- 404 when the session does not exist.
- `after` defaults to 0, `limit` defaults to 500 and is clamped to 1..1000.
- Response: `{ events: [...], last_id: Integer, status: String, done: Boolean }`
- `last_id` is the highest returned event id, or the incoming `after` when the
  page is empty — so a client can poll forever without losing its place.
- `done` is true when session status is terminal: `completed`, `failed`, or
  `rejected`. `paused` is **not** terminal (the run can still be resumed).

### R4.3 SSE endpoint

`GET /api/sessions/:id/stream?after=<id>`

- Requires `inspect_run`. `Content-Type: text/event-stream`,
  `Cache-Control: no-cache`, `X-Accel-Buffering: no`.
- Body is a Rack streaming body responding to `each`, emitting
  `id: <n>\ndata: <json>\n\n` per event, then a final
  `event: done\ndata: {"status":"..."}\n\n` when the session reaches a terminal
  status.
- Bounded: stops after a wall-clock cap (30s default) even if the run continues,
  so a client reconnects with `after=<last_id>`. Must not spin — sleep between
  polls. Must open and close its own `Storage` handle per poll iteration or hold
  one and close it in an `ensure`; it must not leak a connection when the client
  disconnects.

### R4.4 Web UI

`session_show.erb` gains a live event log that polls `/api/sessions/:id/events`
every 2s from `last_id`, appending rows, and stops polling when `done`. Plain
inline JS consistent with the existing views — no new dependency, no build step.

### R4.5 Tests

- Normalize maps a well-formed row; a malformed payload becomes `{"raw" => ...}`.
- Empty page echoes `after` back as `last_id`.
- `after` filters strictly (`id > after`), `limit` clamps at 1000 and at 1.
- `done` is true for `completed`/`failed`/`rejected`, false for `running`/`paused`.
- Unknown session → 404. Viewer role (has `inspect_run`) can read; a role without
  `inspect_run` is rejected.
- SSE response carries the right content type and its body yields at least one
  `data:` frame for a session with audit rows.

## Integration seam (lead, after both agents land)

`apply_session_decision` (app.rb) currently sets `approved_pending_resume`. Once
both features are merged it calls `GraphEngine.resume` on approve. This crosses
both agents' file boundaries deliberately and is **not** in either agent's scope.

## As-built deltas (post-implementation, intentional)

1. `riggs_messages` gained `UNIQUE(session_id, seq)` as `idx_riggs_messages_session_seq`,
   superseding the non-unique index. The auto-allocated path was verified collision-free
   under 8 concurrent processes × 50 writes (SQLite serializes write transactions), but
   the caller-supplied `seq:` path had no guard at all.
2. `list_audit_after` now selects `session_id` too, so `Events.normalize` can read it from
   the row. The `session_id:` fallback kwarg remains for rows that lack the column.
3. `apply_session_decision` returns the resulting status, and `api_session_decision`
   surfaces it as `status` in the JSON body. Approve resumes only when the session is
   `paused` **and** has resume state; otherwise it keeps the old
   `approved_pending_resume` behavior, so previously-recorded decisions are unaffected.
4. Gates encountered *after* a web-triggered resume auto-approve, matching the existing
   behavior of `execute_workflow`. CLI resume uses the default handler instead.
5. A paused run records two `gate_pause` audit rows (the pre-existing one, plus one
   carrying `resumable: true`). Left as-is rather than mutating the original event.

## Post-review fixes (independent Codex review, all confirmed against the code)

1. **Resume was not atomically claimed.** `find_session` → check `paused` →
   `update_session("running")` was a read-then-write, so two resumers could both
   pass the check and execute the gated step twice. Now `Storage#claim_paused_session`
   does a conditional `UPDATE ... WHERE status = 'paused'` and reports whether it
   won; the loser raises. R1.3's guard clauses stay for error messages only.
2. **A client could miss the final event.** The terminal status was committed
   *before* the `workflow_complete` / `workflow_failed` audit row, so a poll landing
   between the two saw `done: true` and stopped before the last event existed. Audit
   now precedes the status flip on every terminal path (and on pause, for consistency).
3. **SSE truncated at 500 events.** `poll_events` took `list_audit_after`'s default
   limit, then signalled `done` immediately for a terminal session — so a run with
   more than 500 audit rows streamed only the first page and the client never
   reconnected. The stream now drains full pages without sleeping and refuses to
   signal `done` mid-backlog.
4. **Unknown gate results dead-ended the run.** R1.2 said unknown values are "treated
   as approved", but the raw value was passed to `resolve_next`, where neither
   `if gate.approved:` nor `if gate.rejected:` matched — so the workflow stopped after
   the gated step. Non-`:paused`/`:rejected` values now normalize to `:approved`.
   (The spec wording above was itself ambiguous: "keep current behavior (treated as
   approved)" described two different behaviors. Normalizing is the intended one.)
5. **The limit-clamp test asserted nothing.** It seeded 3 events and requested
   `limit=99999`, which returns 3 with or without a clamp. Replaced with a 1001-event
   case asserting exactly 1000; verified by mutating `MAX_LIMIT` and watching it fail.

## Definition of done

- `bundle exec rake test` green; `bundle exec rubocop` clean.
- No agent edits a file owned by the other agent or by the foundation.
- Every new public method has a test that was watched failing first.
