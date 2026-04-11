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

    /// Resolves the Warp pane UUID hosting a Claude/Codex agent running in
    /// `cwd`. Returns uppercase hex string (32 chars, no separators), or nil
    /// on any error / when no pane can be located.
    ///
    /// Tries two lookup strategies in order:
    ///
    /// **Primary — `terminal_panes.cwd` direct match.** Queries Warp's
    /// per-pane cwd column. Fast and precise when Warp's shell integration
    /// had a chance to update the column, which happens whenever the shell
    /// renders a prompt with a cwd different from the pane's initial
    /// launch cwd. Both firmlink forms of the input cwd are tried because
    /// Claude Code captures cwd via `getcwd()` (resolved:
    /// `/private/tmp/foo`) while Warp usually stores the unresolved form
    /// the shell sent over OSC (`/tmp/foo`).
    ///
    /// **Fallback — `commands → blocks` cross-reference.** If the primary
    /// miss, inspect the command history for a row whose text contains
    /// `cd <target>` (both firmlink forms, bounded so `/tmp/foo` doesn't
    /// false-positive-match `/tmp/foo-extended`), take that row's
    /// `session_id`, and join to a `precmd-<session_id>-*` block to get
    /// the pane uuid. Covers the common "compound command" flow where a
    /// user pastes `mkdir -p /tmp/foo && cd /tmp/foo && claude` as a
    /// single line: Warp renders the first prompt (writing
    /// `precmd-<session>-1` and linking the shell session to the pane
    /// uuid), then claude's TUI takes over before a second prompt can
    /// fire, so terminal_panes.cwd never updates past the initial
    /// `/Users/u`. The commands table still has the full pasted text, so
    /// matching on `cd /tmp/foo` recovers the mapping.
    ///
    /// Known limitations:
    /// - Substring collision within the fallback is mitigated by
    ///   bounding the match on a shell separator (space / `;` / `&` /
    ///   `|`) or end-of-command. Exotic separators (newline-only,
    ///   trailing-slash path normalization) are not handled.
    /// - If two Warp tabs share the same cwd in either table, the most
    ///   recently created row (`id DESC`) wins. Disambiguating
    ///   same-cwd panes from SQLite alone is not possible because Warp
    ///   does not expose a per-pane PID or TTY.
    /// - Paths containing SQLite GLOB meta-characters (`*`, `?`, `[`,
    ///   `]`) will fall through the fallback silently. These are
    ///   vanishingly rare in practice; the primary lookup still handles
    ///   them correctly.
    public func lookupPaneUUID(forCwd cwd: String) -> String? {
        guard let db = openReadOnly() else { return nil }
        defer { sqlite3_close(db) }

        if let uuid = lookupViaTerminalPanesCwd(db: db, cwd: cwd) {
            return uuid
        }
        if let uuid = lookupViaCommandsHistory(db: db, cwd: cwd) {
            return uuid
        }
        return nil
    }

    private func lookupViaTerminalPanesCwd(db: OpaquePointer, cwd: String) -> String? {
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

    private func lookupViaCommandsHistory(db: OpaquePointer, cwd: String) -> String? {
        let candidates = Self.cwdLookupCandidates(for: cwd)

        // Skip the fallback if any candidate contains SQLite GLOB meta
        // characters — escaping them safely is more effort than this
        // fallback is worth for paths that are effectively never used.
        if candidates.contains(where: { path in path.contains(where: { "*?[".contains($0) }) }) {
            return nil
        }

        // Two GLOB patterns per candidate:
        //   1. `*cd <path>[ ;&|]*` — `cd <path>` followed by a shell
        //      separator (standard case, e.g. `cd /tmp/foo && claude`).
        //   2. `*cd <path>`       — `cd <path>` at the very end of the
        //      command string.
        // The `[ ;&|]` character class is what prevents substring
        // collision: a lookup for `/tmp/foo` will not match a command
        // containing `cd /tmp/foo-extended` because the character after
        // `foo` is `-`, not one of the separators.
        var globPatterns: [String] = []
        for candidate in candidates {
            globPatterns.append("*cd \(candidate)[ ;&|]*")
            globPatterns.append("*cd \(candidate)")
        }

        let whereClause = Array(repeating: "c.command GLOB ?", count: globPatterns.count)
            .joined(separator: " OR ")

        // The inner JOIN against `terminal_panes` is load-bearing: Warp
        // prunes terminal_panes rows when the user closes a tab, but
        // leaves the historical commands + blocks entries in place. On
        // a real database the ratio is routinely ~1000 orphan blocks
        // per live pane. Without this filter the fallback would happily
        // return a stale "pane uuid that used to exist", which the
        // precision jump cycle loop would then chase around the tab
        // list for its entire cap before timing out with a "could not
        // confirm precision focus" message — terrible UX. Joining
        // against terminal_panes keeps the result set constrained to
        // currently-live panes, so a miss immediately cleanly degrades
        // to "no precise pane mapping available" at the caller.
        let sql = """
        SELECT hex(tp.uuid)
        FROM commands c
        JOIN blocks b ON b.block_id LIKE 'precmd-' || c.session_id || '-%'
        JOIN terminal_panes tp ON tp.uuid = b.pane_leaf_uuid
        WHERE \(whereClause)
        ORDER BY c.id DESC
        LIMIT 1;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var heldCStrings: [UnsafeMutablePointer<CChar>?] = []
        defer { heldCStrings.forEach { free($0) } }

        for (index, pattern) in globPatterns.enumerated() {
            let cString = pattern.withCString { strdup($0) }
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
