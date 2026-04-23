import Foundation

/// A user-configured application whose terminal sessions should be tracked.
/// Stored by bundle ID; the display name shown in the island badge is `terminalAppKey`.
public struct CustomTrackedApp: Codable, Equatable, Identifiable, Sendable {
    public var id: String { bundleID }
    public var bundleID: String
    public var appName: String
    /// The short label shown in the island session badge (e.g. "Superset", "MyTerm").
    public var terminalAppKey: String

    public init(bundleID: String, appName: String, terminalAppKey: String) {
        self.bundleID = bundleID
        self.appName = appName
        self.terminalAppKey = terminalAppKey
    }
}

/// Persists and vends the list of user-configured tracked apps.
public final class CustomTrackedAppStore: @unchecked Sendable {
    public static let shared = CustomTrackedAppStore()

    private static let defaultsKey = "discovery.customTrackedApps"

    private let lock = NSLock()
    private var _apps: [CustomTrackedApp] = []

    public var apps: [CustomTrackedApp] {
        get { lock.withLock { _apps } }
        set { lock.withLock { _apps = newValue }; persist(newValue) }
    }

    private init() {
        _apps = load()
    }

    // MARK: - Lookup

    /// Returns the terminalAppKey for the given bundle ID, if the user has added it.
    public func terminalAppKey(forBundleID bundleID: String) -> String? {
        lock.withLock {
            _apps.first { $0.bundleID == bundleID }?.terminalAppKey
        }
    }

    /// Returns the terminalAppKey for any app whose bundle ID is contained in
    /// the given process command string (case-insensitive path match).
    public func terminalAppKey(matchingCommand command: String) -> String? {
        let lower = command.lowercased()
        return lock.withLock {
            _apps.first { app in
                // Match on the bundle ID converted to a path fragment, e.g.
                // "com.example.myterminal" → "/myterminal.app/"
                let appNameFragment = app.appName.lowercased()
                return lower.contains("/\(appNameFragment).app/")
                    || lower.contains(app.bundleID.lowercased())
            }?.terminalAppKey
        }
    }

    // MARK: - Persistence

    private func load() -> [CustomTrackedApp] {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([CustomTrackedApp].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persist(_ apps: [CustomTrackedApp]) {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
