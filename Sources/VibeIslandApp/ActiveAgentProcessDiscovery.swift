import Foundation
import VibeIslandCore

struct ActiveAgentProcessDiscovery {
    private static let processCommandTimeout: TimeInterval = 0.5
    private static let lsofCommandTimeout: TimeInterval = 0.2

    private final class OutputBox: @unchecked Sendable {
        var data = Data()
    }

    struct ProcessSnapshot: Equatable, Sendable {
        var tool: AgentTool
        var sessionID: String?
        var workingDirectory: String?
        var terminalTTY: String?
    }

    private struct RunningProcess {
        var pid: String
        var terminalTTY: String?
        var command: String
    }

    typealias CommandRunner = @Sendable (_ executablePath: String, _ arguments: [String]) -> String?

    private let commandRunner: CommandRunner

    init(commandRunner: @escaping CommandRunner = Self.commandOutput) {
        self.commandRunner = commandRunner
    }

    func discover() -> [ProcessSnapshot] {
        let processes = runningProcesses()
        guard !processes.isEmpty else {
            return []
        }

        var snapshots: [ProcessSnapshot] = []
        var claimedKeys: Set<String> = []

        for process in processes {
            guard process.terminalTTY != nil else {
                continue
            }

            if isCodexProcess(command: process.command) {
                guard let snapshot = codexSnapshot(for: process) else {
                    continue
                }

                let claimKey = "codex:\(snapshot.sessionID ?? process.pid)"
                guard claimedKeys.insert(claimKey).inserted else {
                    continue
                }

                snapshots.append(snapshot)
                continue
            }

            if isClaudeProcess(command: process.command) {
                guard let snapshot = claudeSnapshot(for: process) else {
                    continue
                }

                let claimKey = "claude:\(snapshot.sessionID ?? snapshot.terminalTTY ?? snapshot.workingDirectory ?? process.pid)"
                guard claimedKeys.insert(claimKey).inserted else {
                    continue
                }

                snapshots.append(snapshot)
            }
        }

        return snapshots
    }

    private func runningProcesses() -> [RunningProcess] {
        guard let output = commandRunner("/bin/ps", ["-Ao", "pid=,tty=,command="]) else {
            return []
        }

        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> RunningProcess? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return nil
                }

                let components = trimmed.split(maxSplits: 2, whereSeparator: \.isWhitespace)
                guard components.count == 3 else {
                    return nil
                }

                let pid = String(components[0])
                let tty = normalizedTTY(String(components[1]))
                let command = String(components[2]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty else {
                    return nil
                }

                return RunningProcess(pid: pid, terminalTTY: tty, command: command)
            }
    }

    private func codexSnapshot(for process: RunningProcess) -> ProcessSnapshot? {
        guard let lsofOutput = lsofOutput(pid: process.pid),
              let transcriptPath = matchingPath(in: lsofOutput, containing: "/.codex/sessions/", suffix: ".jsonl"),
              let sessionID = firstUUID(in: transcriptPath) else {
            return nil
        }

        return ProcessSnapshot(
            tool: .codex,
            sessionID: sessionID,
            workingDirectory: workingDirectory(from: lsofOutput),
            terminalTTY: process.terminalTTY
        )
    }

    private func claudeSnapshot(for process: RunningProcess) -> ProcessSnapshot? {
        let lsofOutput = lsofOutput(pid: process.pid)
        let transcriptPath = lsofOutput.flatMap {
            matchingPath(in: $0, containing: "/.claude/projects/", suffix: ".jsonl")
        }

        let workingDirectory = lsofOutput.flatMap(workingDirectory(from:))
        guard workingDirectory != nil || transcriptPath != nil else {
            return nil
        }

        return ProcessSnapshot(
            tool: .claudeCode,
            sessionID: transcriptPath.flatMap(firstUUID(in:)),
            workingDirectory: workingDirectory,
            terminalTTY: process.terminalTTY
        )
    }

    private func lsofOutput(pid: String) -> String? {
        commandRunner("/usr/sbin/lsof", ["-a", "-p", pid, "-Fn"])
    }

    private func workingDirectory(from lsofOutput: String) -> String? {
        let lines = lsofOutput.split(whereSeparator: \.isNewline).map(String.init)
        for index in lines.indices {
            guard lines[index] == "fcwd",
                  lines.indices.contains(index + 1) else {
                continue
            }

            let nextLine = lines[index + 1]
            guard nextLine.first == "n" else {
                continue
            }

            let value = String(nextLine.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("/") {
                return value
            }
        }

        return nil
    }

    private func matchingPath(in lsofOutput: String, containing fragment: String, suffix: String) -> String? {
        for line in lsofOutput.split(whereSeparator: \.isNewline) {
            guard line.first == "n" else {
                continue
            }

            let value = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.contains(fragment), value.hasSuffix(suffix) else {
                continue
            }

            return value
        }

        return nil
    }

    private func firstUUID(in text: String) -> String? {
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }

        return String(text[matchRange]).lowercased()
    }

    private func normalizedTTY(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "??" else {
            return nil
        }

        if trimmed.hasPrefix("/dev/") {
            return trimmed
        }

        return "/dev/\(trimmed)"
    }

    private func isCodexProcess(command: String) -> Bool {
        let lowered = command.lowercased()
        guard let firstToken = lowered.split(separator: " ").first.map(String.init) else {
            return false
        }

        return firstToken == "codex"
            || firstToken.hasSuffix("/codex")
            || lowered.contains("/codex/codex")
    }

    private func isClaudeProcess(command: String) -> Bool {
        let lowered = command.lowercased()
        if lowered.contains("/.local/bin/claude") {
            return true
        }

        guard let firstToken = lowered.split(separator: " ").first else {
            return false
        }

        return firstToken == "claude"
    }

    private static func commandOutput(executablePath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        let completionGroup = DispatchGroup()
        completionGroup.enter()
        process.terminationHandler = { _ in
            completionGroup.leave()
        }
        let outputGroup = DispatchGroup()
        outputGroup.enter()
        let outputBox = OutputBox()
        DispatchQueue.global(qos: .utility).async {
            outputBox.data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            outputGroup.leave()
        }
        let timeout: TimeInterval = executablePath.hasSuffix("/lsof")
            ? Self.lsofCommandTimeout
            : Self.processCommandTimeout

        do {
            try process.run()
        } catch {
            return nil
        }

        let waitResult = completionGroup.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            process.terminate()
            _ = completionGroup.wait(timeout: .now() + 0.1)
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        _ = outputGroup.wait(timeout: .now() + 0.1)
        guard let output = String(data: outputBox.data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            return nil
        }

        return output
    }
}
