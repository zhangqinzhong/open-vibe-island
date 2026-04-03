# Claude Code Runtime Plan

## Status

This document captures the current best plan for the `Claude Code` adapter as of `2026-04-03`.

It is based on four inputs:

- original app package and helper analysis
- the `claude-island` open-source implementation
- restored Claude Code source from `/Users/wangruobing/Personal/claude-research/claude-code-sourcemap/restored-src/src`
- direct runtime observations from this machine while reproducing session-count mismatches

The goal is to preserve the design intent before more implementation work happens.

## Product Rule

The island session list should reflect the number of code agents that are currently open in supported terminals.

For `Claude Code`, this means:

- do not count recent transcript sessions as live
- do not infer a live session from history alone
- prefer false negatives over false positives when live ownership is ambiguous

Supported boundary remains:

- `Claude Code`
- `Codex`
- `Terminal.app`
- `Ghostty`

## Key Findings

### From Claude Code source

The restored Claude Code source confirms these stable session signals:

- hook input includes `session_id`
- hook input includes `transcript_path`
- hook input includes `cwd`
- `SessionStart` includes `source` with `startup`, `resume`, `clear`, `compact`
- CLI supports `--resume [value]`
- CLI supports `--session-id <uuid>`

The restored source does not show `terminal_tty` or `terminal_session_id` as official hook schema fields. Those terminal hints must therefore be treated as local augmentations that Vibe Island derives at runtime.

### From original app analysis

The original product behaves like a multi-source bridge:

- install hooks into `~/.claude/settings.json`
- install a managed status line
- route interactive approval and question flows through a helper
- preserve richer Claude semantics such as `PermissionRequest`, `AskUserQuestion`, and subagent events

This implies the original product is not relying on transcript parsing alone for live state.

### From claude-island

`claude-island` is useful mainly for Claude-specific edge cases:

- it covers the right Claude hook events
- it handles the `PermissionRequest` without `tool_use_id` by correlating `PreToolUse`
- it uses transcript files for recovery and enrichment

It is not the right end-state architecture for Vibe Island because it depends on a separate Python/socket/runtime stack and includes tmux/yabai-specific behavior outside our current scope.

### From direct runtime observation

The most important runtime fact is:

- an active `claude` process does not always keep its transcript file open

That means:

- `lsof -> transcript_path -> session_id` is not reliable enough as the only live mapping strategy
- `cwd` is too weak to identify a single live Claude session
- the CLI command line often contains a stronger signal such as `--resume <session-id>`

This directly explains the earlier false positive where one live Claude process caused an older transcript session from the same repo to appear in the live list.

## Design Principles

1. Hooks own session semantics.
2. Runtime probing owns terminal attribution.
3. A local registry owns restart recovery for live bindings.
4. Transcript discovery is for cold-start recovery and text enrichment only.
5. Live list count must come from strong signals, never from transcript recency.

## Recommended Architecture

Use four layers for the Claude adapter.

### 1. Hook layer

Responsibility:

- normalize official Claude hook events into shared `AgentEvent` values
- preserve session semantics such as approvals, questions, stop events, and subagent activity

Required events:

- `SessionStart`
- `UserPromptSubmit`
- `PreToolUse`
- `PermissionRequest`
- `PostToolUse`
- `PostToolUseFailure`
- `Notification`
- `Stop`
- `StopFailure`
- `SessionEnd`
- `SubagentStart`
- `SubagentStop`
- `PreCompact`

Important rule:

- continue correlating `PermissionRequest` with `PreToolUse` to recover `tool_use_id`

### 2. Runtime augmentation layer

Responsibility:

- enrich hook payloads with terminal-local hints that are not part of the official Claude hook schema

Examples:

- `terminalApp`
- `terminalTTY`
- `terminalSessionID`
- `terminalTitle`

Source of these values:

- environment inspection
- `tty`
- terminal-specific AppleScript locators for supported terminals

These fields are useful, but they are not official Claude hook guarantees. They must always be treated as best-effort local observations.

### 3. Session registry layer

Responsibility:

- persist the best-known live binding between Claude sessions and terminal identity
- survive app restart without falling back to transcript guessing

Suggested stored fields:

- `sessionID`
- `terminalApp`
- `terminalSessionID`
- `terminalTTY`
- `terminalTitle`
- `workingDirectory`
- `transcriptPath`
- `lastSeenAt`

Update policy:

- update on every live hook event
- refresh when terminal probing later learns a better terminal identifier
- expire stale bindings conservatively instead of deleting immediately

This registry should become the primary restart-recovery source for Claude live session ownership.

### 4. Transcript discovery layer

Responsibility:

- recover recent Claude sessions on cold start
- provide title, prompt preview, last assistant text, current tool, and model data

Transcript discovery must not:

- mark a session as live on its own
- increase the live list count on its own

Recovered transcript sessions should enter state as `stale` until a stronger live signal claims them.

## Live Matching Rules

For Claude, active process to session matching should use this priority:

1. exact `sessionID`
2. exact `terminalSessionID`
3. exact `terminalTTY`
4. unique `workingDirectory` candidate
5. otherwise do not attach

Important constraints:

- never attach multiple Claude sessions to one active Claude process
- never choose “most recent in same cwd” when multiple sessions are plausible
- `workingDirectory` is last-resort fallback only

Acceptable outcome:

- when strong signals are missing, the UI may temporarily undercount a Claude session

Unacceptable outcome:

- overcounting live sessions by reviving older transcripts from the same repository

## UI Semantics

The main island list should show only live attached sessions.

Transcript-recovered sessions may exist in state, but they should remain outside the live list unless they receive a strong live claim.

For Claude interaction cards:

- `PermissionRequest` and `AskUserQuestion` are attention states
- dismissing the overlay must not clear the underlying waiting state
- incidental running updates must not overwrite question or approval state

## Source-of-Truth Model

Use this hierarchy.

### Live session identity

- primary: hook `session_id`
- fallback: process command line `--resume` or `--session-id`
- fallback: process-open transcript UUID when available

### Live terminal ownership

- primary: persisted registry binding
- fallback: current terminal snapshot exact match
- fallback: active process exact `tty`
- fallback: unique `cwd` candidate

### Session text enrichment

- transcript content
- hook payload previews

## Implementation Plan

### P0

- keep current strict Claude matching behavior
- parse Claude process command line for `--resume` and `--session-id`
- prevent one Claude process from reviving multiple same-cwd sessions

This work is already partially implemented.

### P1

- add `ClaudeSessionRegistry`
- write registry entries from live hooks and corrected jump targets
- use registry-first recovery on app launch before transcript discovery fallback

This is the highest-ROI next step.

### P2

- tighten terminal rehome around registry and explicit snapshot matches
- reduce remaining best-effort `cwd` reliance after restart
- add more regression coverage for restart and cross-worktree resume paths

### P3

- optional richer transcript watching for better summaries and long-running Claude tool visibility

This is lower ROI than the registry work and should not come first.

## Why Not Use Claude-Island As-Is

Because its strongest ideas are narrower than its implementation:

- keep the hook coverage
- keep the `PreToolUse` to `PermissionRequest` correlation
- keep transcript enrichment

Do not copy:

- Python hook runtime as the primary integration path
- tmux/yabai/send-keys control logic
- transcript-driven live ownership

Vibe Island should stay a native bridge with a generic event core and a Claude-specific adapter.

## Current Recommendation

If more Claude work resumes later, the next change should be:

1. implement `ClaudeSessionRegistry`
2. make app launch recovery registry-first
3. leave transcript recovery as enrichment only

That is the shortest path to matching the original product more closely without expanding scope or overfitting to fragile transcript heuristics.
