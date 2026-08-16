# Phase 11 Hook Bus — Implementation Plan

**Goal:** Injectable hook bus so a host can deny/mutate tool calls and inspect provider requests without patching `ToolLoop`; move `lookup_runbook` to `BuiltinTools`; document `Router` `registry:`.

**Tech stack:** Ruby 4.0, Minitest, RuboCop.

## Files

| File | Action |
|---|---|
| `lib/riggs/hooks.rb` | Create |
| `lib/riggs/builtin_tools.rb` | Create |
| `lib/riggs/workflow/tool_loop.rb` | Wire hooks + builtins |
| `lib/riggs/workflow/graph_engine.rb` | Accept/`default` hooks, pass through |
| `lib/riggs.rb` | Require new files |
| `test/test_hooks.rb` | Create |
| `README.md` | Document hooks + `registry:` |

## Tasks

1. Tests for `Hooks` fire/deny/mutate and `BuiltinTools.lookup_runbook`.
2. Implement modules; wire `ToolLoop` / `GraphEngine`.
3. Integration test: host denies a tool by role via hook without touching `ToolLoop`.
4. README `registry:` + hooks section.
