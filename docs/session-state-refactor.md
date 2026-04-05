# Session State Management Refactoring Plan

## 1. Problem Statement

The current session state management architecture is overly complex. It uses a 3-state attachment model (`attached`/`stale`/`detached`) with 6+ reconciliation passes running every 3 seconds, involving AppleScript terminal snapshots, multi-pass matching algorithms, grace windows, synthetic session creation, and CWD-based fallback matching. This makes it fragile and hard to extend — every new terminal (e.g., cmux) requires patches in multiple code paths.

The reference product (Vibe Island) achieves the same UX with a much simpler model:
- Only maintains active sessions (3 in their data store vs our 29)
- Simple status: `processing` / `waiting_for_input`
- When process exits → session disappears from list
- No complex attachment state machine

The core insight: **session visibility should be a direct function of process liveness, not a continuously recomputed attachment state.**

## 2. New State Model

### Session Lifecycle

```
[Hook: sessionStarted OR Process discovered] --> ACTIVE
ACTIVE --> ACTIVE  (hook updates, metadata updates, phase changes)
ACTIVE --> REMOVED (process exits AND no pending interaction AND grace period elapsed)
```

### Simplified State

**Remove `SessionAttachmentState` entirely.** Replace with:

```swift
// On AgentSession:
var isProcessAlive: Bool          // set by process discovery
var lastProcessSeenAt: Date?      // for brief grace window on process exit
```

**Remove `SessionOrigin`** — replace with `isDemoSession` computed property.

### Visibility Rule

A session appears in the UI if:
1. `isProcessAlive == true`, OR
2. `phase.requiresAttention` (waiting for approval/answer), OR
3. `isDemoSession`, OR
4. Time since `lastProcessSeenAt` < 10 seconds (jitter absorption)

A session is **removed from state** when:
- `isProcessAlive == false` AND `lastProcessSeenAt` > 60 seconds AND `!phase.requiresAttention`

## 3. What Changes in Each File

### Remove entirely (~1170 lines)
- `Sources/OpenIslandApp/TerminalSessionAttachmentProbe.swift`

### New file (~250 lines)
- `Sources/OpenIslandApp/TerminalJumpTargetResolver.swift` — extracted from the probe, only handles jump target precision (AppleScript snapshots for Ghostty/Terminal.app), never drives visibility

### `Sources/OpenIslandCore/AgentSession.swift`
- **Remove**: `SessionAttachmentState`, `SessionOrigin`, `attachmentState`, `origin`, `isAttachedToTerminal`, `isTrackedLiveSession`
- **Add**: `isProcessAlive: Bool`, `lastProcessSeenAt: Date?`

### `Sources/OpenIslandCore/SessionState.swift`
- **Remove**: `reconcileAttachmentStates()`, `reconcileJumpTargets()`, attachment-based counts
- **Add**: `removeSession(id:)`, `markProcessAlive(sessionID:alive:at:)`, `removeDeadSessions(olderThan:)`

### `Sources/OpenIslandApp/AppModel.swift` (~450 lines removed)
- **Remove**: `mergedWithSyntheticClaudeSessions()` and all synthetic infrastructure, `adoptProcessTTYsForClaudeSessions()`, `sanitizeCrossToolGhosttyJumpTargets()`, `mergeAttachmentState()`, `liveAttachmentKey()`, complex `displayPriority()`
- **Rewrite**: `reconcileSessionAttachments()` (70→30 lines), `computeSessionBuckets()` (35→10 lines)

### `Sources/OpenIslandCore/ClaudeSessionRegistry.swift`
- **Delete entirely** or gut to only persist pending-interaction sessions (~30 lines)

### `Sources/OpenIslandCore/DemoBridgeServer.swift`
- **Keep as-is** — hook event model is sound

## 4. Migration Phases

### Phase 1: Add `isProcessAlive` in parallel (LOW RISK)
- Add `isProcessAlive` and `lastProcessSeenAt` to `AgentSession`
- Populate in `reconcileSessionAttachments()` from process discovery
- Log discrepancies between old attachment model and new liveness model
- Write `SessionLivenessTests.swift`

**Rollback**: Remove two fields.

### Phase 2: Create `TerminalJumpTargetResolver` (LOW RISK)
- Extract jump-target-relevant logic from attachment probe into new type
- Keep old probe unchanged — new type is additive
- Verify jump targets match between old and new path

**Rollback**: Delete new file, revert AppModel.

### Phase 3: Switch visibility to `isProcessAlive` (MEDIUM RISK)
- Rewrite `computeSessionBuckets()` to use `isProcessAlive`
- Remove overflow bucket
- Simplify `displayPriority()` to simple sort
- Stop calling `TerminalSessionAttachmentProbe.sessionResolutionReport()`

**Rollback**: Revert to Phase 2 state.

### Phase 4: Session cleanup and removal (MEDIUM RISK)
- Implement automatic session removal (60s after process exit)
- Remove synthetic session creation
- Remove `adoptProcessTTYsForClaudeSessions`
- Add `SessionState.removeSession(id:)`

**Rollback**: Revert to Phase 3 state.

### Phase 5: Remove dead code (LOW RISK)
- Delete `TerminalSessionAttachmentProbe.swift` (1170 lines)
- Delete `ClaudeSessionRegistry.swift` (159 lines)
- Remove `SessionAttachmentState`, `SessionOrigin` enums
- Clean up all attachment-related helpers
- Update/delete affected tests

**Rollback**: Git revert.

## 5. Verification Plan

### Key Scenarios
1. Session appears when agent starts (within 3 seconds)
2. Session disappears when agent exits (within ~60 seconds)
3. Jump to Ghostty/Terminal.app/cmux terminal works
4. Permission approval flow works
5. Question answering flow works
6. Notification fires correctly
7. Subagent display (metadata on parent, not separate session)
8. Multiple terminals simultaneously
9. App restart recovery (session reappears within 3 seconds)
10. Process-only session (no hooks configured)
11. Codex session lifecycle
12. Demo mode unaffected

### Before/After Comparison
During Phase 1-2, log per-cycle comparisons of old `attached` set vs new `isProcessAlive` set. Investigate all discrepancies.

### Risk Areas
1. **Ghostty jump precision**: Resolver reuses existing matching logic, but needs validation
2. **Session flicker**: 10-second grace on `lastProcessSeenAt` absorbs jitter
3. **"Completed idle" behavior change**: Sessions disappear ~60s after exit vs current 15-minute grace — intentional, matches reference product
4. **Restart persistence loss**: Only pending interactions are persisted — acceptable since process discovery reconstructs active sessions

## 6. Impact Summary

| Metric | Before | After |
|---|---|---|
| TerminalSessionAttachmentProbe | 1170 lines | 0 (deleted) |
| TerminalJumpTargetResolver (new) | 0 | ~250 lines |
| AppModel session management | ~750 lines | ~300 lines |
| SessionState | 250 lines | ~200 lines |
| ClaudeSessionRegistry | 159 lines | 0 or ~30 lines |
| Attachment state values | 3 | 0 (removed) |
| Grace window constants | 3 (120s, 15min, 120s) | 1 (60s) |
| Reconciliation passes | 6+ | 2 |
| **Net lines removed** | | **~1000** |
