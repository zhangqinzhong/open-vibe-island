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

    /// Resolves the Warp pane UUID hosting a Claude/Codex agent running in `cwd`.
    ///
    /// Queries `terminal_panes` directly for a pane whose stored cwd matches
    /// the requested cwd, ordered by `id DESC` so the most recently created
    /// pane wins. This handles the common case where the user opens a new
    /// Warp tab and runs `claude` directly: Warp does not write a
    /// `precmd-<session>-<n>` block for that shell session (because claude
    /// takes over the TUI before any shell prompt is rendered), so a join
    /// through the blocks table would silently miss the new tab and return
    /// the pane uuid of an OLDER claude session in the same cwd. Querying
    /// `terminal_panes.cwd` directly avoids the dependency on precmd blocks.
    ///
    /// Known limitation: if two Warp tabs both have the same cwd recorded in
    /// `terminal_panes`, both will resolve to the most recently created one
    /// (highest `id`). Disambiguating same-cwd panes from external state
    /// alone is not possible because Warp does not expose a per-pane PID
    /// or TTY in its SQLite schema. Workaround: launch each agent in a
    /// distinct cwd.
    ///
    /// Returns uppercase hex string (32 chars, no separators) suitable for
    /// comparison against the result of `currentFocusedPaneUUID`. Returns nil
    /// on any error or when no pane is found for the requested cwd.
    ///
    /// Both forms of the cwd are tried, because Claude Code captures cwd via
    /// `getcwd()` which resolves the macOS firmlink (`/tmp` →
    /// `/private/tmp`, `/var` → `/private/var`), while Warp records whatever
    /// path the shell sent through its OSC integration — typically the
    /// unresolved form because zsh's `pwd` returns the user-facing path. So
    /// hook payloads commonly carry `/private/tmp/foo` while
    /// `terminal_panes.cwd` stores `/tmp/foo`. Equality matching against one
    /// form alone misses the row. We query both candidates in a single
    /// statement and return the most recently created (`id DESC`) match.
    public func lookupPaneUUID(forCwd cwd: String) -> String? {
        guard let db = openReadOnly() else { return nil }
        defer { sqlite3_close(db) }

        let candidates = Self.cwdLookupCandidates(for: cwd)

        let sql = """
        SELECT hex(uuid)
        FROM terminal_panes
        WHERE cwd IN (\(Array(repeating: "?", count: candidates.count).joined(separator: ", ")))
        ORDER BY id DESC
        LIMIT 1;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var heldCStrings: [UnsafeMutablePointer<CChar>?] = []
        defer { heldCStrings.forEach { free($0) } }

        for (index, candidate) in candidates.enumerated() {
            let cString = candidate.withCString { strdup($0) }
            heldCStrings.append(cString)
            sqlite3_bind_text(stmt, Int32(index + 1), cString, -1, nil)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cString = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cString)
    }

    /// Generates the set of equivalent cwd strings to query Warp's SQLite
    /// against. macOS firmlinks `/tmp` → `/private/tmp` (and `/var` →
    /// `/private/var`), so a single conceptual directory has two valid
    /// string forms. Always returns the input as-is plus, when applicable,
    /// the firmlink-flipped sibling.
    static func cwdLookupCandidates(for cwd: String) -> [String] {
        var result: [String] = [cwd]
        if cwd.hasPrefix("/private/tmp/") || cwd == "/private/tmp" {
            result.append(String(cwd.dropFirst("/private".count)))
        } else if cwd.hasPrefix("/tmp/") || cwd == "/tmp" {
            result.append("/private" + cwd)
        } else if cwd.hasPrefix("/private/var/") || cwd == "/private/var" {
            result.append(String(cwd.dropFirst("/private".count)))
        } else if cwd.hasPrefix("/var/") || cwd == "/var" {
            result.append("/private" + cwd)
        }
        return result
    }

    /// Resolves the pane UUID of the currently focused pane in the currently
    /// active Warp window. This is what drives the polling loop during a
    /// precision jump.
    ///
    /// Returns uppercase hex string suitable for direct comparison to the
    /// output of `lookupPaneUUID`. Returns nil on any error or if there is
    /// no active window.
    public func currentFocusedPaneUUID() -> String? {
        guard let db = openReadOnly() else { return nil }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT hex(tp.uuid)
        FROM tabs t
        JOIN pane_nodes pn ON pn.tab_id = t.id AND pn.is_leaf = 1
        JOIN terminal_panes tp ON tp.id = pn.id
        WHERE t.window_id = (SELECT active_window_id FROM app LIMIT 1)
        ORDER BY t.id
        LIMIT 1 OFFSET (
            SELECT active_tab_index FROM windows
            WHERE id = (SELECT active_window_id FROM app LIMIT 1)
        );
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cString = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cString)
    }

    /// Returns the number of tabs in the currently active Warp window.
    /// Used as the upper bound for the keystroke cycle retry loop during
    /// precision jump. Returns 0 on any error.
    public func tabCountInActiveWindow() -> Int {
        guard let db = openReadOnly() else { return 0 }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT COUNT(*) FROM tabs
        WHERE window_id = (SELECT active_window_id FROM app LIMIT 1);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Internal

    private func openReadOnly() -> OpaquePointer? {
        var db: OpaquePointer?
        let flags: Int32 = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databasePath, &db, flags, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        // Set a short busy timeout so we don't hang if Warp is mid-transaction.
        sqlite3_busy_timeout(db, 60) // ms
        return db
    }
}
