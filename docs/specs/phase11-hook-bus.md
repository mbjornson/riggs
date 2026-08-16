# Phase 11 Spec — Hook Bus (#5)

Status: implemented
Gaps closed: `docs/gaps.md` #5
Date: 2026-08-16

## Motivation

No extension points exist today. `lookup_runbook` is hardcoded inside
`ToolLoop#execute_tool`. RBAC gates *starting* a workflow but has no say in what
tools that workflow then invokes. Every new cross-cutting behavior means editing
core.

Pi ships interception points and lets extensions supply features. Riggs needs
the same substrate: injectable callables, in the style `gate_handler:` already
proves fits this codebase.

## Non-goals

- A plugin package format or TypeScript extension loader (Pi's model; Riggs is Ruby).
- A `context` message-filter hook (Pi has one; not required by the gap's done-when).
- Replacing MCP or skill tool resolution.

## Decisions

1. **Three events only.** `before_provider_request`, `tool_call` (veto + mutate
   arguments), `tool_result` (rewrite output). That is the gap's listed set.
2. **Injectable `hooks:` on `GraphEngine` / `ToolLoop`.** Same pattern as
   `gate_handler:`. A host that omits hooks gets defaults; a host that supplies
   hooks replaces nothing unless they opt out of defaults.
3. **`lookup_runbook` leaves `ToolLoop`.** It lives in `Riggs::BuiltinTools` and
   is consulted before MCP. Core no longer special-cases the name.
4. **Default RBAC policy is a hook, not a hardcode.** With the run's identity,
   MCP (non-builtin) tool calls require `manage_mcp`. A host can deny any tool
   by role by registering their own `tool_call` handler — the gap's done-when —
   without patching `ToolLoop`.
5. **`Providers::Router`'s `registry:` is documented** in the README. Behavior
   unchanged.

## R11.1 `Riggs::Hooks`

New file `lib/riggs/hooks.rb`.

```ruby
hooks = Riggs::Hooks.new
hooks.on(:tool_call) { |ctx| ... }
hooks.fire(:tool_call, ctx) # => ctx, possibly mutated / with :deny
```

- `on(event, &block)` / `register(event, callable)` append handlers.
- `fire(event, ctx)` runs handlers in order. For `:tool_call`, the first handler
  that sets `ctx[:deny]` (truthy) stops the chain; argument mutations merge into
  `ctx[:arguments]`. For `:before_provider_request` and `:tool_result`, handlers
  may mutate the context hash in place; the final hash is returned.
- `Hooks.default(identity:)` builds a bus with the RBAC MCP policy installed.

## R11.2 `Riggs::BuiltinTools`

New file `lib/riggs/builtin_tools.rb`. Map of name → callable `(arguments) -> String`.
Ships `lookup_runbook`. `ToolLoop#execute_tool` checks this map before MCP.

## R11.3 Wire-through

- `GraphEngine.new(..., hooks: nil)` — nil means `Hooks.default(identity: user_identity)`.
- Pass `hooks` into `ToolLoop`.
- `ToolLoop` fires `before_provider_request` before `@router.call`, `tool_call`
  before execution, `tool_result` after.
- A denied tool call returns `TOOL_DENIED: <reason>` as the tool result (audit
  still records `tool_call` / `tool_result`).

## Done when

A host can deny a tool call by role without patching `ToolLoop`, proven by a
test that registers a `tool_call` hook denying a named tool for a given role.
`lookup_runbook` no longer appears as a special case in `ToolLoop#execute_tool`.
README documents `registry:`.
