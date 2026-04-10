import Foundation
import SQLite3

/// Read-only access to Warp's live SQLite state for precision jump targeting.
///
/// This depends on Warp's internal schema and is not a supported Warp API.
/// All query failures degrade silently: callers receive nil/0 and should
/// fall back to whatever non-Warp behavior they had.
public struct WarpSQLiteReader: Sendable {
    public let databasePath: String

    public init(databasePath: String = WarpSQLiteReader.defaultDatabasePath()) {
        self.databasePath = databasePath
    }

    /// Returns the standard on-disk location of Warp's SQLite database for the
    /// stable release channel. Warp stores state inside its Group Container,
    /// not the per-app Application Support, because Warp is sandboxed.
    public static func defaultDatabasePath() -> String {
        NSHomeDirectory()
            + "/Library/Group Containers/2BBY89MBSN.dev.warp"
            + "/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite"
    }
}
