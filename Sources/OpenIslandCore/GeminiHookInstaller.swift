import Foundation

public struct GeminiHookFileMutation: Equatable, Sendable {
    public var contents: Data?
    public var changed: Bool
    public var managedHooksPresent: Bool

    public init(contents: Data?, changed: Bool, managedHooksPresent: Bool) {
        self.contents = contents
        self.changed = changed
        self.managedHooksPresent = managedHooksPresent
    }
}

public enum GeminiHookInstallerError: Error, LocalizedError {
    case invalidSettingsJSON

    public var errorDescription: String? {
        "The existing Gemini settings.json is not valid JSON."
    }
}

public enum GeminiHookInstaller {
    private static let hookEvents: [String] = ["SessionStart", "PreToolUse", "PostToolUse", "Stop", "UserPromptSubmit"]

    public static func hookCommand(for binaryPath: String) -> String {
        "'\(binaryPath.replacingOccurrences(of: "'", with: "'\\''"))' --source gemini"
    }

    public static func installSettingsJSON(
        existingData: Data?,
        hookCommand: String
    ) throws -> GeminiHookFileMutation {
        var root = try loadRoot(from: existingData)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for event in hookEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let alreadyPresent = entries.contains { ($0["command"] as? String)?.contains("--source gemini") == true }
            if !alreadyPresent {
                entries.append(["command": hookCommand])
                hooks[event] = entries
                changed = true
            }
        }

        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return GeminiHookFileMutation(contents: data, changed: changed, managedHooksPresent: true)
    }

    public static func uninstallSettingsJSON(
        existingData: Data?,
        hookCommand: String
    ) throws -> GeminiHookFileMutation {
        guard let existingData else {
            return GeminiHookFileMutation(contents: nil, changed: false, managedHooksPresent: false)
        }
        var root = try loadRoot(from: existingData)
        guard var hooks = root["hooks"] as? [String: Any] else {
            return GeminiHookFileMutation(contents: existingData, changed: false, managedHooksPresent: false)
        }

        var changed = false
        for event in hookEvents {
            if var entries = hooks[event] as? [[String: Any]] {
                let before = entries.count
                entries.removeAll { ($0["command"] as? String)?.contains("--source gemini") == true }
                if entries.count != before {
                    hooks[event] = entries.isEmpty ? nil : entries
                    changed = true
                }
            }
        }

        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let stillPresent = hookEvents.contains { event in
            (hooks[event] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("--source gemini") == true
            } == true
        }
        return GeminiHookFileMutation(contents: data, changed: changed, managedHooksPresent: stillPresent)
    }

    private static func loadRoot(from data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiHookInstallerError.invalidSettingsJSON
        }
        return root
    }
}
