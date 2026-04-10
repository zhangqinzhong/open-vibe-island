# Warp Terminal Identification Fix

Status: Implemented — pending merge
Date: 2026-04-10
Scope: Level 2 (minimal bug fix + default-fallback hardening)

## Problem Statement

When Claude Code (or Codex) runs inside Warp, Open Island mislabels the session as `"Terminal"` and clicking "jump back" opens a brand-new Terminal.app window at the working directory instead of focusing Warp.

### Root cause

The hook-side terminal classifier in `Sources/OpenIslandCore/ClaudeHooks.swift:1114-1143` reads `TERM_PROGRAM` and switches over known values. Warp sets `TERM_PROGRAM=WarpTerminal`, which is not in the switch:

```swift
let termProgram = environment["TERM_PROGRAM"]?.lowercased()
switch termProgram {
case .some("apple_terminal"):     return "Terminal"
case .some("iterm.app"), .some("iterm2"): return "iTerm"
case let value? where value.contains("ghostty"): return "Ghostty"
case .some("kaku"):               return "Kaku"
case .some("wezterm"):            return "WezTerm"
case .some("vscode"):             ...
case .some("vscode-insiders"):    return "VS Code Insiders"
case .some("windsurf"):           return "Windsurf"
case .some("trae"):               return "Trae"
default:                          break    // ← "warpterminal" falls here
}
```

`inferTerminalApp` therefore returns `nil`, and the session constructor at `ClaudeHooks.swift:679` hard-codes a wrong default:

```swift
terminalApp: terminalApp ?? "Terminal",
```

Downstream, `TerminalJumpService.jump` receives `terminalApp = "Terminal"`, runs the Terminal.app AppleScript handler, fails to match any TTY/title (because the process isn't actually inside Terminal.app), and falls through to the best-effort cwd fallback at `TerminalJumpService.swift:254`:

```swift
try openAction(["-b", descriptor.bundleIdentifier, workingDirectory])
```

which is `open -b com.apple.Terminal /path/to/cwd` — producing the observed symptom of a new Terminal.app window.

### Why the bug will recur without structural fix

The same `?? "Terminal"` hard-code exists in:

- `Sources/OpenIslandCore/ClaudeHooks.swift:679`
- `Sources/OpenIslandCore/CodexHooks.swift:268`
- `Sources/OpenIslandCore/OpenCodeHooks.swift:190`

And each of those files has (or in Claude/Codex's case, definitely has) its own `inferTerminalApp` switch that duplicates parts of the whitelist in `ProcessMonitoringCoordinator.supportedTerminalApp` (`Sources/OpenIslandApp/ProcessMonitoringCoordinator.swift:710-758`). The two lists drift independently.

Notably, `supportedTerminalApp` **already recognizes Warp** (lines 725-726):

```swift
case "warp", "warpterminal":
    return "Warp"
```

The canonical whitelist was updated; the hook-side classifier was not. Every future new terminal that sets a novel `TERM_PROGRAM` will repeat this bug until the two classifiers are unified.

## Intended End State

### Functional

1. A Claude Code session running inside Warp appears in Open Island's UI labeled `"Warp"` (not `"Terminal"`).
2. Clicking the jump affordance on such a session brings the Warp application to the foreground via `open -b dev.warp.Warp-Stable`. Because Warp exposes no tab identity (no AppleScript, no CLI, no per-tab env vars, no URL focus action), we accept that the activated tab is whichever tab Warp itself had focused last — we do not attempt tab-level precision in this fix.
3. A Codex session running inside Warp is labeled `"Warp"` by the same mechanism.
4. If Open Code runs inside Warp, its sessions are also labeled `"Warp"` (parity fix).

### Hardening

5. Any agent running inside an unrecognized terminal (no `TERM_PROGRAM` match and no other env-var signal) is labeled `"Unknown"` rather than `"Terminal"`. Clicking jump on such a session opens the working directory in Finder via the existing fallback at `TerminalJumpService.swift:264-267` — a semantically correct "I don't know where this lives" response — instead of mis-routing to Terminal.app.

### Explicitly out of scope

- **Warp-specific jump handler.** No attempt to add a `case "dev.warp.Warp-Stable"` branch in `TerminalJumpService.jump`'s switch. Warp's automation surface was empirically confirmed too thin to support tab-level precision (see Risks below). Can be revisited if Warp ships a CLI or AppleScript dictionary in the future.
- **Unifying the two terminal whitelists** (`inferTerminalApp` vs `supportedTerminalApp`) into a single source of truth. This is a worthwhile architectural cleanup but crosses the boundary of a minimal bug fix. Tracked as a followup.
- **CGWindowList / Accessibility-based window matching.** Would require new macOS permission prompts for uncertain benefit.

## Findings During Implementation

The spec was drafted from a code read that predicted the `CodexHooks` and `OpenCodeHooks` files would need the same shape of fix as `ClaudeHooks`. Reading the files more carefully during implementation surfaced three refinements:

### Finding 1 · CodexHooks already recognizes Warp

`Sources/OpenIslandCore/CodexHooks.swift:481-551` defines an `inferTerminalApp` that already has **two** independent Warp detection paths:

- Line 500-502: `if environment["WARP_IS_LOCAL_SHELL_SESSION"] != nil { return "Warp" }` — env-var fast path before the `TERM_PROGRAM` switch.
- Line 515-516: `case let value? where value.contains("warp"): return "Warp"` — substring match inside the switch.

Codex sessions running inside Warp were already being labeled correctly. The visible bug was Claude-only. CodexHooks still needs the `?? "Terminal"` → `?? "Unknown"` change for the hardening goal (step 2 below), but the classifier is untouched.

### Finding 2 · OpenCodeHooks has no `inferTerminalApp`

`Sources/OpenIslandCore/OpenCodeHooks.swift` has no classifier function at all. Its `terminalApp` field comes directly from the hook payload without runtime inference. Only the default-fallback change is needed in that file.

### Finding 3 · `resolveTerminalApp` has a silent fallback that swallows the "Unknown" sentinel

The spec originally assumed `TerminalJumpService.resolveTerminalApp("Unknown")` would return `nil` and let `jump()` fall through to the Finder fallback. Reading `Sources/OpenIslandApp/TerminalJumpService.swift:852-864` showed the resolver actually has a generic "first installed known app" fallback:

```swift
if let exact = Self.knownApps.first(where: { descriptor in
    descriptor.displayName.lowercased() == normalized || descriptor.aliases.contains(normalized)
}) {
    return exact
}

return Self.knownApps.first(where: { isInstalled(bundleIdentifier: $0.bundleIdentifier) })
```

Without intervention, passing `"Unknown"` would silently return whatever known terminal is installed first (iTerm, by `knownApps` ordering) — and `jump()` would then activate *that* wrong terminal. This was confirmed empirically by the failing test `testUnknownTerminalAppFallsBackToFinderInsteadOfFirstInstalledTerminal` before the fix was applied: clicking jump on an "Unknown" target with iTerm installed as a test stub produced `"Activated iTerm. Exact pane targeting is still best-effort."` instead of the intended Finder fallback.

The fix is an explicit `"unknown"` guard at the top of `resolveTerminalApp`, narrow enough not to change behavior for any currently-passing value.

## Changes (as implemented)

### 1. Add Warp recognition in `ClaudeHooks.inferTerminalApp`

Added two detection arms to `Sources/OpenIslandCore/ClaudeHooks.swift`, matching the pattern already in `CodexHooks`:

- Env-var fast path: `if environment["WARP_IS_LOCAL_SHELL_SESSION"] != nil { return "Warp" }` placed next to the existing `GHOSTTY_RESOURCES_DIR` check.
- Switch arm: `case let value? where value.contains("warp"): return "Warp"` placed next to the existing `value.contains("ghostty")` arm.

Both arms are present for defense in depth — the env var fires first in the normal case, the switch arm catches `TERM_PROGRAM=WarpTerminal` if the env var is ever absent.

**No changes** to `CodexHooks.inferTerminalApp` — already correct (see Finding 1).

**No changes** to `OpenCodeHooks` classifier — no classifier exists (see Finding 2).

### 2. Replace the `?? "Terminal"` default fallback

Changed `?? "Terminal"` to `?? "Unknown"` in all three hook payload `defaultJumpTarget` computed properties:

- `Sources/OpenIslandCore/ClaudeHooks.swift:679`
- `Sources/OpenIslandCore/CodexHooks.swift:268`
- `Sources/OpenIslandCore/OpenCodeHooks.swift:190`

After this change, `"Unknown"` is the project-wide sentinel for "we could not classify this terminal" — consistent with the pre-existing uses at `Sources/OpenIslandCore/ClaudeTranscriptDiscovery.swift:183` and `Sources/OpenIslandApp/ProcessMonitoringCoordinator.swift:371`.

### 3. Add explicit "unknown" guard in `resolveTerminalApp`

Added a four-line guard at the top of `Sources/OpenIslandApp/TerminalJumpService.resolveTerminalApp`:

```swift
if normalized == "unknown" {
    return nil
}
```

With this, `jump()` will skip the descriptor-keyed switch entirely for `"Unknown"` targets and either:

- activate Finder on the working directory (line 264-267) — the common case, because the hook fired from within a cwd that exists on disk, or
- throw `TerminalJumpError.unsupportedTerminal("Unknown")` if even the working directory is missing (pathological case).

No behavior change for any other terminal name, because all existing known terminal names either match `displayName` or `aliases` exactly and return a descriptor on the first `.first(where:)` call — never reaching the generic "first installed" fallback that is being bypassed.

### 4. UI presentation

Display `"Unknown"` literally in the terminal label at `AgentSession+Presentation.swift:115`, matching existing precedent (`ClaudeTranscriptDiscovery.swift:183`). No code changes — the existing string interpolation renders whatever value the session carries.

Alternatives considered and rejected for this fix:

- Hide the terminal label for unknown terminals — loses diagnostic signal.
- Display the raw `TERM_PROGRAM` value (e.g. `"WarpTerminal"`) — more informative but requires the hook to pass the raw value as a deeper fallback before `"Unknown"`. Can be revisited as a separate enhancement.

## Verification Path (as executed)

### Unit tests added

1. ✅ `ClaudeHooksTests.claudeInferTerminalAppRecognizesWarpViaEnvVar` — environment `["WARP_IS_LOCAL_SHELL_SESSION": "1"]` causes `withRuntimeContext` to set `payload.terminalApp == "Warp"`.
2. ✅ `ClaudeHooksTests.claudeInferTerminalAppRecognizesWarpViaTermProgram` — environment `["TERM_PROGRAM": "WarpTerminal"]` does the same, via the switch arm.
3. ✅ `ClaudeHooksTests.claudeDefaultJumpTargetUsesUnknownSentinelForUnrecognizedTerminal` — environment `["TERM_PROGRAM": "rio"]` leaves `payload.terminalApp == nil` and `payload.defaultJumpTarget.terminalApp == "Unknown"` (not `"Terminal"`).
4. ✅ `TerminalJumpServiceTests.testUnknownTerminalAppFallsBackToFinderInsteadOfFirstInstalledTerminal` — with iTerm stubbed as installed, `jump()` called with `terminalApp: "Unknown"` and a real `/tmp` workingDirectory opens `["/tmp"]` (Finder) — not `["-b", "com.googlecode.iterm2"]`.

All four tests were written first, observed failing (TDD red), then the production code was changed to turn them green.

Tests for the default-fallback change in `CodexHooks.swift:268` and `OpenCodeHooks.swift:190` were not added as dedicated new tests — the type system and the full regression suite below cover the change, and the ClaudeHooks unknown-sentinel test exercises the same code path on the same-shaped computed property.

### Regression

✅ `swift test` — 141 tests across 17 suites pass. No pre-existing test depended on the old `?? "Terminal"` default.

### Manual (pending on merge)

- [ ] In a Warp tab, run a fresh Claude Code session. Open Island's session list should show `"Warp · <workspace>"`.
- [ ] Click the jump affordance. Warp should come to the foreground and **no new Terminal.app window should open**. The specific tab that ends up focused is whatever Warp last had focused — expected given Warp's lack of automation surface.
- [ ] (Optional) Confirm Codex parity — not strictly necessary since CodexHooks classifier was already correct.

## Resolved Risks

- **`OpenCodeHooks.swift` shape**: confirmed to have no `inferTerminalApp` classifier. Only the default-fallback change was needed there.
- **Existing test coverage baking in the old default**: no tests in the suite asserted `terminalApp == "Terminal"` as a fallback value. Full `swift test` run stays green after the default change.

## Accepted Limitations (not blockers)

- **Tab-level precision is impossible for Warp today.** Empirical findings during design:
  - No AppleScript dictionary (`tell application "Warp"` returns app name only, not scriptable).
  - No `warp` CLI (only `/Applications/Warp.app/Contents/Resources/bin/oz` at 122 bytes, unrelated to pane control).
  - URL scheme (`warp://action/new_window`, `warp://action/new_tab`, `warp://launch/...`) only creates new windows/tabs — no focus-existing action.
  - No per-tab identifier in subprocess environment. `TERM_PROGRAM=WarpTerminal`, `WARP_IS_LOCAL_SHELL_SESSION=1`, `WARP_CLI_AGENT_PROTOCOL_VERSION=1` are per-tab identical, not unique.
  - App activation via `open -b dev.warp.Warp-Stable` is the ceiling for now.
- This means jump-back for Warp is functionally equivalent to "activate Warp" regardless of how many tabs the user has open. Users with multiple Warp tabs may need to manually select the right tab after jump. This tradeoff was explicitly accepted during brainstorming.

## Followups (not in this fix)

1. **Unify terminal whitelists.** Refactor `ClaudeHooks`/`CodexHooks`/`OpenCodeHooks` `inferTerminalApp` implementations to return raw `TERM_PROGRAM` strings (plus the existing env-var signal detection for Zellij/cmux/Ghostty/etc.), and let `ProcessMonitoringCoordinator.supportedTerminalApp` be the single source of truth for canonicalization. Would have prevented this bug entirely. Separate issue.
2. **Revisit Warp tab precision** if Warp ships any of: an AppleScript dictionary, a `warp` CLI with a list/activate subcommand, or a URL scheme action for focusing an existing session. Track upstream at https://github.com/warpdotdev/Warp/discussions/612.
3. **Consider showing raw `TERM_PROGRAM`** (option (c) from brainstorming) as a secondary label for unknown terminals, to surface future undetected terminals to users without looking like a broken display.
