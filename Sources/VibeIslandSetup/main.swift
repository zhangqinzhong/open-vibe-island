import Foundation
import VibeIslandCore

@main
struct VibeIslandSetupCLI {
    static func main() {
        do {
            let command = try SetupCommand(arguments: Array(CommandLine.arguments.dropFirst()))
            try command.run()
        } catch let error as SetupError {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

private struct SetupCommand {
    enum Action: String {
        case install
        case uninstall
        case status
        case installClaude
        case uninstallClaude
        case statusClaude
    }

    let action: Action
    let codexDirectory: URL
    let claudeDirectory: URL
    let hooksBinary: URL?

    init(arguments: [String]) throws {
        guard let rawAction = arguments.first,
              let action = Action(rawValue: rawAction) else {
            throw SetupError.usage
        }

        self.action = action

        var hooksBinary: URL?
        var codexDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        var claudeDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)

        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--hooks-binary":
                index += 1
                guard index < arguments.count else {
                    throw SetupError.missingValue("--hooks-binary")
                }
                hooksBinary = URL(fileURLWithPath: arguments[index]).standardizedFileURL

            case "--codex-dir":
                index += 1
                guard index < arguments.count else {
                    throw SetupError.missingValue("--codex-dir")
                }
                codexDirectory = URL(fileURLWithPath: arguments[index]).standardizedFileURL

            case "--claude-dir":
                index += 1
                guard index < arguments.count else {
                    throw SetupError.missingValue("--claude-dir")
                }
                claudeDirectory = URL(fileURLWithPath: arguments[index]).standardizedFileURL

            default:
                throw SetupError.unexpectedArgument(arguments[index])
            }

            index += 1
        }

        if (action == .install || action == .installClaude), hooksBinary == nil {
            hooksBinary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/release/VibeIslandHooks")
                .standardizedFileURL
        }

        self.codexDirectory = codexDirectory
        self.claudeDirectory = claudeDirectory
        self.hooksBinary = hooksBinary
    }

    func run() throws {
        switch action {
        case .install:
            try install()
        case .uninstall:
            try uninstall()
        case .status:
            try status()
        case .installClaude:
            try installClaude()
        case .uninstallClaude:
            try uninstallClaude()
        case .statusClaude:
            try statusClaude()
        }
    }

    private func install() throws {
        guard let hooksBinary else {
            throw SetupError.usage
        }

        let manager = CodexHookInstallationManager(codexDirectory: codexDirectory)
        let status = try manager.install(hooksBinaryURL: hooksBinary)

        print("Installed Vibe Island Codex hooks.")
        print("Codex dir: \(status.codexDirectory.path)")
        print("Hooks binary: \(hooksBinary.path)")
        if status.manifest?.enabledCodexHooksFeature == true {
            print("Updated config.toml to enable [features].codex_hooks = true")
        } else {
            print("config.toml already had codex_hooks enabled")
        }
    }

    private func uninstall() throws {
        let manager = CodexHookInstallationManager(codexDirectory: codexDirectory)
        let status = try manager.uninstall()

        print("Removed Vibe Island Codex hooks.")
        print("Codex dir: \(status.codexDirectory.path)")
        if FileManager.default.fileExists(atPath: status.hooksURL.path) {
            print("Preserved unrelated hooks.json entries.")
        }
    }

    private func status() throws {
        let manager = CodexHookInstallationManager(codexDirectory: codexDirectory)
        let status = try manager.status(hooksBinaryURL: hooksBinary)

        print("Codex dir: \(status.codexDirectory.path)")
        print("Feature flag enabled: \(status.featureFlagEnabled ? "yes" : "no")")
        print("Managed hooks present: \(status.managedHooksPresent ? "yes" : "no")")
        if let hooksBinary {
            print("Hooks binary: \(hooksBinary.path)")
        }
        if let manifest = status.manifest {
            print("Manifest: present")
            print("Feature enabled by installer: \(manifest.enabledCodexHooksFeature ? "yes" : "no")")
        } else {
            print("Manifest: missing")
        }
    }

    private func installClaude() throws {
        guard let hooksBinary else {
            throw SetupError.usage
        }

        let manager = ClaudeHookInstallationManager(claudeDirectory: claudeDirectory)
        let status = try manager.install(hooksBinaryURL: hooksBinary)

        print("Installed Vibe Island Claude hooks.")
        print("Claude dir: \(status.claudeDirectory.path)")
        print("Hooks binary: \(hooksBinary.path)")
        if status.hasClaudeIslandHooks {
            print("Note: claude-island hooks are still present alongside Vibe Island hooks.")
        }
    }

    private func uninstallClaude() throws {
        let manager = ClaudeHookInstallationManager(claudeDirectory: claudeDirectory)
        let status = try manager.uninstall()

        print("Removed Vibe Island Claude hooks.")
        print("Claude dir: \(status.claudeDirectory.path)")
        if status.hasClaudeIslandHooks {
            print("Preserved claude-island hooks.")
        }
    }

    private func statusClaude() throws {
        let manager = ClaudeHookInstallationManager(claudeDirectory: claudeDirectory)
        let status = try manager.status(hooksBinaryURL: hooksBinary)

        print("Claude dir: \(status.claudeDirectory.path)")
        print("Managed hooks present: \(status.managedHooksPresent ? "yes" : "no")")
        print("claude-island hooks present: \(status.hasClaudeIslandHooks ? "yes" : "no")")
        if let hooksBinary {
            print("Hooks binary: \(hooksBinary.path)")
        }
        if let manifest = status.manifest {
            print("Manifest: present")
            print("Hook command: \(manifest.hookCommand)")
        } else {
            print("Manifest: missing")
        }
    }
}

private enum SetupError: Error, LocalizedError {
    case usage
    case missingValue(String)
    case unexpectedArgument(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            """
            Usage:
              swift run VibeIslandSetup install [--hooks-binary /abs/path/to/VibeIslandHooks] [--codex-dir /abs/path/to/.codex]
              swift run VibeIslandSetup uninstall [--codex-dir /abs/path/to/.codex]
              swift run VibeIslandSetup status [--hooks-binary /abs/path/to/VibeIslandHooks] [--codex-dir /abs/path/to/.codex]
              swift run VibeIslandSetup installClaude [--hooks-binary /abs/path/to/VibeIslandHooks] [--claude-dir /abs/path/to/.claude]
              swift run VibeIslandSetup uninstallClaude [--claude-dir /abs/path/to/.claude]
              swift run VibeIslandSetup statusClaude [--hooks-binary /abs/path/to/VibeIslandHooks] [--claude-dir /abs/path/to/.claude]
            """
        case let .missingValue(flag):
            "Missing value for \(flag)"
        case let .unexpectedArgument(argument):
            "Unexpected argument: \(argument)"
        }
    }
}
