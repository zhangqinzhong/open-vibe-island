# Warp Terminal Identification Fix

Status: Design approved — ready for implementation plan
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

## Changes

### 1. Add Warp recognition in hook-side classifiers

Add a `case .some("warpterminal"): return "Warp"` arm to `inferTerminalApp` in every file that has one. At minimum:

- `Sources/OpenIslandCore/ClaudeHooks.swift` (switch around line 1115)
- `Sources/OpenIslandCore/CodexHooks.swift` (equivalent switch, location to confirm during implementation)

If `Sources/OpenIslandCore/OpenCodeHooks.swift` has an `inferTerminalApp` equivalent, add the arm there too. If it reads `terminalApp` directly from the hook payload without classifier logic, no change is needed in that file beyond the default-fallback change below.

### 2. Replace the `?? "Terminal"` default fallback

In each of the following, change `?? "Terminal"` to `?? "Unknown"`:

- `Sources/OpenIslandCore/ClaudeHooks.swift:679`
- `Sources/OpenIslandCore/CodexHooks.swift:268`
- `Sources/OpenIslandCore/OpenCodeHooks.swift:190`

After this change, `"Unknown"` becomes the project-wide sentinel for "we could not classify this terminal" — consistent with the existing use at `Sources/OpenIslandCore/ClaudeTranscriptDiscovery.swift:183` and `Sources/OpenIslandApp/ProcessMonitoringCoordinator.swift:371`.

### 3. Verify downstream handling of "Unknown"

No code changes expected, but verify during implementation that the following already hold:

- `TerminalJumpService.resolveTerminalApp("Unknown")` returns `nil` (because the string `"unknown"` is not in any `TerminalAppDescriptor.aliases`). Verify by reading the resolver.
- With a `nil` descriptor, `TerminalJumpService.jump` falls through the chained `if let descriptor` blocks (lines 199-262) and reaches the Finder fallback at line 264:
  ```swift
  if hasWorkingDirectory, let workingDirectory = target.workingDirectory {
      try openAction([workingDirectory])
      return "Opened \(target.workspaceName) in Finder because no supported terminal app could be resolved."
  }
  ```
- `AgentSession+Presentation.swift:115` renders `"\(jumpTarget.terminalApp) · \(jumpTarget.workspaceName)"` via plain string interpolation, so a terminal value of `"Unknown"` will display as `"Unknown · my-project"` with no additional UI work. This is consistent with the existing `ClaudeTranscriptDiscovery.swift:183` behavior.

If any of these invariants do not already hold, treat it as a new finding and update this spec before implementing.

### 4. UI presentation choice

Display `"Unknown"` literally in the terminal label, matching existing precedent (`ClaudeTranscriptDiscovery.swift:183`). No branching in the presentation layer.

Alternatives considered and rejected for this fix:

- Hide the terminal label for unknown terminals — loses diagnostic signal.
- Display the raw `TERM_PROGRAM` value (e.g. `"WarpTerminal"`) — more informative but requires the hook to pass the raw value as a deeper fallback before `"Unknown"`. Can be revisited as a separate enhancement.

## Verification Path

### Unit tests (new)

1. **`ClaudeHooksTests`**: Given an environment dictionary containing `["TERM_PROGRAM": "WarpTerminal"]` (and otherwise empty of other terminal markers like `GHOSTTY_RESOURCES_DIR`, `ZELLIJ`, `CMUX_WORKSPACE_ID`, etc.), `inferTerminalApp(from:)` returns `"Warp"`.
2. **`ClaudeHooksTests`**: Given an environment with an unrecognized `TERM_PROGRAM` (e.g. `"rio"`) and no other markers, the resulting hook payload session has `terminalApp == "Unknown"` (not `"Terminal"`).
3. **`CodexHooksTests`**: Same two tests against the Codex classifier and payload constructor.
4. **`OpenCodeHooksTests`**: Test for the unknown-terminal fallback. If OpenCode has an `inferTerminalApp`, also test the `WarpTerminal` → `"Warp"` case.

### Regression

5. Run the existing hook test suite (`swift test`) to confirm none of the currently-asserted values depend on the old `?? "Terminal"` fallback. Any existing test that was unintentionally relying on that default must be updated (it was asserting a bug).

### Manual

6. In a Warp tab, run a fresh Claude Code session against any repo. Confirm Open Island's session list shows `"Warp · <workspace>"`.
7. Click the jump affordance on that session. Confirm Warp comes to the foreground and **no new Terminal.app window opens**. The specific tab that ends up focused inside Warp is whatever Warp last had focused — this is expected given Warp's lack of automation surface.
8. (Optional, if time permits) Repeat with Codex inside Warp to confirm parity.

## Open Risks / Blockers

### Low risk

- **`OpenCodeHooks.swift` shape unknown at spec-write time.** It has the `?? "Terminal"` line but I haven't confirmed whether it has a matching `inferTerminalApp` switch. Implementation step 1 must read the file first and decide whether an arm needs adding. No design change — just a decision to make during implementation.
- **Existing test coverage may have baked-in the old default.** Any test that set up a Claude hook payload with no `TERM_PROGRAM` and asserted `terminalApp == "Terminal"` is relying on the bug. Expected to be zero or very few such tests; count during implementation and fix them by either adding an explicit `TERM_PROGRAM` value or updating the expectation.

### Accepted limitations (not blockers)

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
