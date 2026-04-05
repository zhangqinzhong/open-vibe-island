import AppKit
import Foundation
import OpenIslandCore

/// Resolves precise jump targets for sessions by querying Ghostty and
/// Terminal.app via AppleScript. This type is responsible ONLY for jump
/// target precision — it never affects session visibility or attachment state.
///
/// Introduced in Phase 2 of the session state refactoring to separate
/// jump-target resolution from the attachment state machine.
struct TerminalJumpTargetResolver {
    typealias ActiveProcessSnapshot = ActiveAgentProcessDiscovery.ProcessSnapshot

    struct GhosttyTerminalSnapshot: Sendable {
        var sessionID: String
        var workingDirectory: String
        var title: String
    }

    struct TerminalTabSnapshot: Sendable {
        var tty: String
        var customTitle: String
    }

    private static let appleScriptTimeout: TimeInterval = 3
    private static let fieldSeparator = "\u{1F}"
    private static let recordSeparator = "\u{1E}"

    // MARK: - Public API

    /// Resolve jump target updates for the given sessions. Returns a dictionary
    /// of session ID → corrected JumpTarget for sessions whose targets changed.
    func resolveJumpTargets(
        for sessions: [AgentSession],
        activeProcesses: [ActiveProcessSnapshot]
    ) -> [String: JumpTarget] {
        guard !sessions.isEmpty else { return [:] }

        let ghosttySessions = sessions.filter { normalizedTerminalName(for: $0.jumpTarget?.terminalApp) == "ghostty" }
        let terminalSessions = sessions.filter { normalizedTerminalName(for: $0.jumpTarget?.terminalApp) == "terminal" }

        var jumpTargetUpdates: [String: JumpTarget] = [:]

        // Ghostty: match sessions to AppleScript snapshots.
        if !ghosttySessions.isEmpty || sessions.contains(where: { needsGhosttyProbe($0) }) {
            let ghosttySnapshots = fetchGhosttySnapshots()
            if let snapshots = ghosttySnapshots {
                let allGhosttyCandidates = sessions.filter {
                    normalizedTerminalName(for: $0.jumpTarget?.terminalApp) == "ghostty"
                        || ($0.jumpTarget?.terminalApp == nil && $0.jumpTarget == nil)
                }
                let matched = matchGhosttySnapshots(snapshots, to: allGhosttyCandidates, activeProcesses: activeProcesses)
                for (sessionID, snapshot) in matched {
                    if let session = sessions.first(where: { $0.id == sessionID }),
                       let corrected = correctedGhosttyJumpTarget(for: session, snapshot: snapshot) {
                        jumpTargetUpdates[sessionID] = corrected
                    }
                }
            }
        }

        // Terminal.app: match sessions to AppleScript snapshots.
        if !terminalSessions.isEmpty {
            let terminalSnapshots = fetchTerminalSnapshots()
            if let snapshots = terminalSnapshots {
                let matched = matchTerminalSnapshots(snapshots, to: terminalSessions)
                for (sessionID, snapshot) in matched {
                    if let session = sessions.first(where: { $0.id == sessionID }),
                       let corrected = correctedTerminalJumpTarget(for: session, snapshot: snapshot) {
                        jumpTargetUpdates[sessionID] = corrected
                    }
                }
            }
        }

        return jumpTargetUpdates
    }

    // MARK: - Ghostty matching

    private func matchGhosttySnapshots(
        _ snapshots: [GhosttyTerminalSnapshot],
        to sessions: [AgentSession],
        activeProcesses: [ActiveProcessSnapshot]
    ) -> [String: GhosttyTerminalSnapshot] {
        var assignments: [String: GhosttyTerminalSnapshot] = [:]
        var claimedSessionIDs: Set<String> = []
        var claimedSnapshotIDs: Set<String> = []

        // Pass 1: exact session ID match via terminal session ID.
        for snapshot in snapshots where !claimedSnapshotIDs.contains(snapshot.sessionID) {
            if let session = sessions.first(where: {
                !claimedSessionIDs.contains($0.id)
                    && nonEmptyValue($0.jumpTarget?.terminalSessionID) == snapshot.sessionID
            }) {
                assignments[session.id] = snapshot
                claimedSessionIDs.insert(session.id)
                claimedSnapshotIDs.insert(snapshot.sessionID)
            }
        }

        // Pass 2: working directory match.
        for snapshot in snapshots where !claimedSnapshotIDs.contains(snapshot.sessionID) {
            let snapshotCWD = normalizedPathForMatching(snapshot.workingDirectory)
            if let session = sessions.first(where: {
                !claimedSessionIDs.contains($0.id)
                    && snapshotCWD != nil
                    && normalizedPathForMatching($0.jumpTarget?.workingDirectory) == snapshotCWD
            }) {
                assignments[session.id] = snapshot
                claimedSessionIDs.insert(session.id)
                claimedSnapshotIDs.insert(snapshot.sessionID)
            }
        }

        // Pass 3: pane title match.
        for snapshot in snapshots where !claimedSnapshotIDs.contains(snapshot.sessionID) {
            if let session = sessions.first(where: {
                !claimedSessionIDs.contains($0.id)
                    && nonEmptyValue($0.jumpTarget?.paneTitle).map { snapshot.title.contains($0) } == true
            }) {
                assignments[session.id] = snapshot
                claimedSessionIDs.insert(session.id)
                claimedSnapshotIDs.insert(snapshot.sessionID)
            }
        }

        return assignments
    }

    private func correctedGhosttyJumpTarget(
        for session: AgentSession,
        snapshot: GhosttyTerminalSnapshot
    ) -> JumpTarget? {
        let hadExistingJumpTarget = session.jumpTarget != nil
        var jumpTarget = session.jumpTarget ?? JumpTarget(
            terminalApp: "Ghostty",
            workspaceName: URL(fileURLWithPath: snapshot.workingDirectory).lastPathComponent,
            paneTitle: snapshot.title,
            workingDirectory: snapshot.workingDirectory,
            terminalSessionID: snapshot.sessionID
        )

        var changed = !hadExistingJumpTarget

        if normalizedTerminalName(for: jumpTarget.terminalApp) != "ghostty" {
            jumpTarget.terminalApp = "Ghostty"
            changed = true
        }

        if nonEmptyValue(jumpTarget.terminalSessionID) != snapshot.sessionID {
            jumpTarget.terminalSessionID = snapshot.sessionID
            changed = true
        }

        if nonEmptyValue(jumpTarget.workingDirectory) != snapshot.workingDirectory {
            jumpTarget.workingDirectory = snapshot.workingDirectory
            changed = true
        }

        if let title = nonEmptyValue(snapshot.title), title != jumpTarget.paneTitle {
            jumpTarget.paneTitle = title
            changed = true
        }

        let workspaceName = URL(fileURLWithPath: snapshot.workingDirectory).lastPathComponent
        if !workspaceName.isEmpty, workspaceName != jumpTarget.workspaceName {
            jumpTarget.workspaceName = workspaceName
            changed = true
        }

        return changed ? jumpTarget : nil
    }

    // MARK: - Terminal.app matching

    private func matchTerminalSnapshots(
        _ snapshots: [TerminalTabSnapshot],
        to sessions: [AgentSession]
    ) -> [String: TerminalTabSnapshot] {
        var assignments: [String: TerminalTabSnapshot] = [:]

        for snapshot in snapshots {
            // TTY match.
            if let session = sessions.first(where: {
                assignments[$0.id] == nil
                    && nonEmptyValue($0.jumpTarget?.terminalTTY) == snapshot.tty
            }) {
                assignments[session.id] = snapshot
                continue
            }

            // Pane title match.
            if let session = sessions.first(where: {
                assignments[$0.id] == nil
                    && nonEmptyValue($0.jumpTarget?.paneTitle).map { snapshot.customTitle.contains($0) } == true
            }) {
                assignments[session.id] = snapshot
            }
        }

        return assignments
    }

    private func correctedTerminalJumpTarget(
        for session: AgentSession,
        snapshot: TerminalTabSnapshot
    ) -> JumpTarget? {
        guard var jumpTarget = session.jumpTarget else {
            return nil
        }

        var changed = false

        if normalizedTerminalName(for: jumpTarget.terminalApp) != "terminal" {
            jumpTarget.terminalApp = "Terminal"
            changed = true
        }

        if nonEmptyValue(jumpTarget.terminalTTY) != snapshot.tty {
            jumpTarget.terminalTTY = snapshot.tty
            changed = true
        }

        if let title = nonEmptyValue(snapshot.customTitle),
           title != jumpTarget.paneTitle {
            jumpTarget.paneTitle = title
            changed = true
        }

        return changed ? jumpTarget : nil
    }

    // MARK: - AppleScript fetching

    private func fetchGhosttySnapshots() -> [GhosttyTerminalSnapshot]? {
        guard isRunning(bundleIdentifier: "com.mitchellh.ghostty") else {
            return []
        }

        let script = """
        set fieldSeparator to ASCII character 31
        set recordSeparator to ASCII character 30
        tell application "Ghostty"
            if not (it is running) then return ""
            set outputLines to {}
            repeat with aTerminal in terminals
                set terminalID to ""
                set terminalDirectory to ""
                set terminalTitle to ""
                try
                    set terminalID to (id of aTerminal as text)
                end try
                try
                    set terminalDirectory to (working directory of aTerminal as text)
                end try
                try
                    set terminalTitle to (name of aTerminal as text)
                end try
                set end of outputLines to terminalID & fieldSeparator & terminalDirectory & fieldSeparator & terminalTitle
            end repeat
            set AppleScript's text item delimiters to recordSeparator
            set joinedOutput to outputLines as string
            set AppleScript's text item delimiters to ""
            return joinedOutput
        end tell
        """

        guard let output = try? runAppleScript(script) else {
            return nil
        }

        return output
            .split(separator: Character(Self.recordSeparator), omittingEmptySubsequences: true)
            .map(String.init)
            .compactMap { line in
                let values = line.components(separatedBy: Self.fieldSeparator)
                guard values.count == 3 else { return nil }
                return GhosttyTerminalSnapshot(
                    sessionID: values[0],
                    workingDirectory: values[1],
                    title: values[2]
                )
            }
    }

    private func fetchTerminalSnapshots() -> [TerminalTabSnapshot]? {
        guard isRunning(bundleIdentifier: "com.apple.Terminal") else {
            return []
        }

        let script = """
        set fieldSeparator to ASCII character 31
        set recordSeparator to ASCII character 30
        tell application "Terminal"
            if not (it is running) then return ""
            set outputLines to {}
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    set tabTTY to ""
                    set tabTitle to ""
                    try
                        set tabTTY to (tty of aTab as text)
                    end try
                    try
                        set tabTitle to (custom title of aTab as text)
                    end try
                    set end of outputLines to tabTTY & fieldSeparator & tabTitle
                end repeat
            end repeat
            set AppleScript's text item delimiters to recordSeparator
            set joinedOutput to outputLines as string
            set AppleScript's text item delimiters to ""
            return joinedOutput
        end tell
        """

        guard let output = try? runAppleScript(script) else {
            return nil
        }

        return output
            .split(separator: Character(Self.recordSeparator), omittingEmptySubsequences: true)
            .map(String.init)
            .compactMap { line in
                let values = line.components(separatedBy: Self.fieldSeparator)
                guard values.count == 2 else { return nil }
                return TerminalTabSnapshot(
                    tty: values[0],
                    customTitle: values[1]
                )
            }
    }

    // MARK: - Helpers

    private func needsGhosttyProbe(_ session: AgentSession) -> Bool {
        session.jumpTarget == nil && session.isProcessAlive
    }

    private func normalizedTerminalName(for value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedPathForMatching(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL.path.lowercased()
    }

    private func nonEmptyValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func isRunning(bundleIdentifier: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty == false
    }

    private func runAppleScript(_ script: String) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        let completionGroup = DispatchGroup()
        completionGroup.enter()
        task.terminationHandler = { _ in
            completionGroup.leave()
        }

        try task.run()
        let waitResult = completionGroup.wait(timeout: .now() + Self.appleScriptTimeout)
        if waitResult == .timedOut {
            task.terminate()
            _ = completionGroup.wait(timeout: .now() + 0.2)
            throw NSError(domain: "TerminalJumpTargetResolver", code: 408, userInfo: [
                NSLocalizedDescriptionKey: "AppleScript probe timed out.",
            ])
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard task.terminationStatus == 0 else {
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(domain: "TerminalJumpTargetResolver", code: Int(task.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: stderr.isEmpty ? "AppleScript probe failed." : stderr,
            ])
        }

        return output
    }
}
