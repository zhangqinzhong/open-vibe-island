import Foundation
import Testing
import SQLite3
@testable import OpenIslandCore

struct WarpSQLiteReaderTests {
    @Test
    func defaultDatabasePathPointsToWarpGroupContainer() {
        let path = WarpSQLiteReader.defaultDatabasePath()
        #expect(path.hasSuffix("/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite"))
        // Path should be absolute and start with the user's home dir.
        #expect(path.hasPrefix(NSHomeDirectory()))
    }

    @Test
    func readerAcceptsExplicitPathOverride() {
        let custom = "/tmp/warp-fixture.sqlite"
        let reader = WarpSQLiteReader(databasePath: custom)
        #expect(reader.databasePath == custom)
    }

    @Test
    func lookupPaneUUIDReturnsUppercaseHexForClaudeInKnownCwd() throws {
        let tmp = NSTemporaryDirectory() + "warp-fixture-\(UUID().uuidString).sqlite"
        try WarpSQLiteFixture.write(to: tmp, scenario: .threeTabsTwoClaudes)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let reader = WarpSQLiteReader(databasePath: tmp)
        let uuid = reader.lookupPaneUUID(forCwd: "/Users/u/open-vibe-island")
        #expect(uuid == "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")
    }

    @Test
    func lookupPaneUUIDReturnsNilForCwdWithoutClaudeCommand() throws {
        let tmp = NSTemporaryDirectory() + "warp-fixture-\(UUID().uuidString).sqlite"
        try WarpSQLiteFixture.write(to: tmp, scenario: .threeTabsTwoClaudes)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let reader = WarpSQLiteReader(databasePath: tmp)
        #expect(reader.lookupPaneUUID(forCwd: "/nonexistent") == nil)
    }

    @Test
    func lookupPaneUUIDReturnsNilForMissingDatabaseFile() {
        let reader = WarpSQLiteReader(databasePath: "/nonexistent/path/warp.sqlite")
        #expect(reader.lookupPaneUUID(forCwd: "/any") == nil)
    }

    @Test
    func lookupPaneUUIDFallsBackToCommandHistoryWhenTerminalPanesCwdIsStale() throws {
        // Regression for the compound-command flow: user opens a new Warp
        // tab and pastes `mkdir -p /tmp/compound-test && cd /tmp/compound-test
        // && claude` as one line. Warp's shell integration wrote a
        // precmd-<session>-1 block at the very first prompt render (before
        // the compound command ran), linking the shell session to the pane
        // uuid — but terminal_panes.cwd was never updated past the initial
        // /Users/u because the second prompt never rendered. The primary
        // cwd lookup returns nil; the fallback must inspect the commands
        // history, match the `cd /tmp/compound-test` pattern, follow
        // commands.session_id → blocks.precmd-<session_id>-* →
        // pane_leaf_uuid.
        let tmp = NSTemporaryDirectory() + "warp-fixture-\(UUID().uuidString).sqlite"
        try WarpSQLiteFixture.write(to: tmp, scenario: .compoundCommandFlow)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let reader = WarpSQLiteReader(databasePath: tmp)
        let uuid = reader.lookupPaneUUID(forCwd: "/tmp/compound-test")
        #expect(uuid == "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD")
    }

    @Test
    func lookupPaneUUIDFallbackAcceptsFirmlinkFlippedInput() throws {
        // Hook payloads arrive with /private/tmp/compound-test because
        // Claude Code captures cwd via getcwd() which resolves the
        // firmlink. The original command was typed as `cd
        // /tmp/compound-test`. The fallback must try both forms so the
        // cross-match succeeds.
        let tmp = NSTemporaryDirectory() + "warp-fixture-\(UUID().uuidString).sqlite"
        try WarpSQLiteFixture.write(to: tmp, scenario: .compoundCommandFlow)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let reader = WarpSQLiteReader(databasePath: tmp)
        let uuid = reader.lookupPaneUUID(forCwd: "/private/tmp/compound-test")
        #expect(uuid == "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD")
    }

    @Test
    func lookupPaneUUIDFallbackSkipsOrphanBlocksFromClosedTabs() throws {
        // When the user closes a Warp tab, Warp prunes the
        // `terminal_panes` row for that tab but leaves the historical
        // `commands` and `blocks` entries in place — this is visible on
        // the real database, which routinely has ~1000+ blocks against
        // a handful of live terminal_panes rows. The fallback must
        // reject matches whose resolved pane_leaf_uuid is no longer
        // present in terminal_panes, otherwise a stale hit would pass
        // a ghost uuid to the precision jump cycle loop, which would
        // spin its entire cap never seeing that uuid in the focused
        // pane read. Graceful degradation is "activate Warp, no
        // precise target" — not "cycle for a second then give up".
        let tmp = NSTemporaryDirectory() + "warp-fixture-\(UUID().uuidString).sqlite"
        try WarpSQLiteFixture.write(to: tmp, scenario: .compoundCommandFlow)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let reader = WarpSQLiteReader(databasePath: tmp)
        // The fixture has an orphan command+block pair pointing at pane
        // uuid FFFF... — no matching terminal_panes row.
        let uuid = reader.lookupPaneUUID(forCwd: "/tmp/closed-tab-cwd")
        #expect(uuid == nil)
    }

    @Test
    func lookupPaneUUIDFallbackDoesNotFalsePositiveOnSubstringCwd() throws {
        // The fallback uses LIKE '%cd <target>%' which is vulnerable to
        // substring collision: a query for `/tmp/foo` must not match a
        // command like `cd /tmp/foo-extended`. Pin the boundary behavior.
        let tmp = NSTemporaryDirectory() + "warp-fixture-\(UUID().uuidString).sqlite"
        try WarpSQLiteFixture.write(to: tmp, scenario: .compoundCommandFlow)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let reader = WarpSQLiteReader(databasePath: tmp)
        // The fixture has a `cd /tmp/compound-test-extended && claude`
        // command pointed at a different pane uuid. A lookup for the
        // shorter path must NOT match it.
        let uuid = reader.lookupPaneUUID(forCwd: "/tmp/compound")
        #expect(uuid == nil)
    }

    @Test
    func lookupPaneUUIDPrimaryStillWinsWhenTerminalPanesCwdIsPopulated() throws {
        // When terminal_panes.cwd IS populated (normal case where the
        // user ran a non-TUI command between `cd` and `claude`), the
        // primary cwd query should still win and we should not fall
        // through to the slower commands-table fallback. This is pinned
        // by reusing the threeTabsTwoClaudes scenario which has populated
        // terminal_panes.cwd for /Users/u/open-vibe-island.
        let tmp = NSTemporaryDirectory() + "warp-fixture-\(UUID().uuidString).sqlite"
        try WarpSQLiteFixture.write(to: tmp, scenario: .threeTabsTwoClaudes)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let reader = WarpSQLiteReader(databasePath: tmp)
        let uuid = reader.lookupPaneUUID(forCwd: "/Users/u/open-vibe-island")
        #expect(uuid == "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")
    }

    @Test
    func currentFocusedPaneUUIDReturnsActiveTabsUUID() throws {
        let tmp = NSTemporaryDirectory() + "warp-fixture-\(UUID().uuidString).sqlite"
        try WarpSQLiteFixture.write(to: tmp, scenario: .threeTabsTwoClaudes)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // Scenario has active_tab_index = 1 which is tab id 2 (open-vibe-island).
        let reader = WarpSQLiteReader(databasePath: tmp)
        #expect(reader.currentFocusedPaneUUID() == "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")
    }

    @Test
    func currentFocusedPaneUUIDReturnsNilForMissingDatabase() {
        let reader = WarpSQLiteReader(databasePath: "/nonexistent.sqlite")
        #expect(reader.currentFocusedPaneUUID() == nil)
    }

    @Test
    func tabCountInActiveWindowReturnsCount() throws {
        let tmp = NSTemporaryDirectory() + "warp-fixture-\(UUID().uuidString).sqlite"
        try WarpSQLiteFixture.write(to: tmp, scenario: .threeTabsTwoClaudes)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let reader = WarpSQLiteReader(databasePath: tmp)
        #expect(reader.tabCountInActiveWindow() == 3)
    }

    @Test
    func tabCountInActiveWindowReturnsZeroForMissingDatabase() {
        let reader = WarpSQLiteReader(databasePath: "/nonexistent.sqlite")
        #expect(reader.tabCountInActiveWindow() == 0)
    }
}

// MARK: - Fixture

/// Builds a minimal synthetic warp.sqlite with the exact schema columns the
/// reader queries. Only the queried subset is present; other tables and
/// constraints are omitted intentionally to keep the fixture short.
enum WarpSQLiteFixture {
    static func write(to path: String, scenario: Scenario) throws {
        // Open (create) the file
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw NSError(domain: "WarpSQLiteFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "open failed"])
        }
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE app (id INTEGER PRIMARY KEY, active_window_id INTEGER);
        CREATE TABLE windows (id INTEGER PRIMARY KEY, active_tab_index INTEGER NOT NULL);
        CREATE TABLE tabs (id INTEGER PRIMARY KEY, window_id INTEGER NOT NULL);
        CREATE TABLE pane_nodes (id INTEGER PRIMARY KEY, tab_id INTEGER NOT NULL, is_leaf BOOLEAN NOT NULL);
        CREATE TABLE terminal_panes (id INTEGER PRIMARY KEY, uuid BLOB NOT NULL, cwd TEXT);
        CREATE TABLE commands (id INTEGER PRIMARY KEY, session_id INTEGER, command TEXT, pwd TEXT);
        CREATE TABLE blocks (id INTEGER PRIMARY KEY, pane_leaf_uuid BLOB, block_id TEXT);
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "WarpSQLiteFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "schema failed: \(String(cString: sqlite3_errmsg(db)))"])
        }

        for row in scenario.rows {
            guard sqlite3_exec(db, row, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "WarpSQLiteFixture", code: 3, userInfo: [NSLocalizedDescriptionKey: "insert failed: \(String(cString: sqlite3_errmsg(db)))"])
            }
        }
    }

    struct Scenario {
        var rows: [String]

        /// Models the "compound command" flow where Warp's shell
        /// integration never updates `terminal_panes.cwd` past the
        /// initial shell cwd because the user ran `cd <target> && claude`
        /// as a single pasted line and claude's TUI took over before a
        /// second prompt could render.
        ///
        /// Pane D had one prompt render at shell startup (cwd /Users/u),
        /// wrote precmd-9001-1, then executed the compound command — so
        /// terminal_panes.cwd stays /Users/u but the commands table
        /// records the full text with `cd /tmp/compound-test`.
        ///
        /// Pane E is a separate shell that ran a NEAR-miss command
        /// (`cd /tmp/compound-test-extended`) so we can pin that the
        /// fallback doesn't false-positive on substring collisions.
        static let compoundCommandFlow = Scenario(rows: [
            "INSERT INTO app (id, active_window_id) VALUES (1, 1);",
            "INSERT INTO windows (id, active_tab_index) VALUES (1, 0);",
            "INSERT INTO tabs (id, window_id) VALUES (1, 1), (2, 1);",
            "INSERT INTO pane_nodes (id, tab_id, is_leaf) VALUES (1, 1, 1), (2, 2, 1);",
            "INSERT INTO terminal_panes (id, uuid, cwd) VALUES " +
                "(1, x'DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD', '/Users/u')," +
                "(2, x'EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE', '/Users/u');",
            "INSERT INTO commands (id, session_id, command, pwd) VALUES " +
                "(300, 9001, 'mkdir -p /tmp/compound-test && cd /tmp/compound-test && claude', '/Users/u')," +
                "(301, 9002, 'mkdir -p /tmp/compound-test-extended && cd /tmp/compound-test-extended && claude', '/Users/u')," +
                // Orphan row: represents a shell session whose tab was
                // closed. commands + blocks linger but terminal_panes is
                // pruned. The fallback must not return FFFF... because
                // no such pane exists anymore.
                "(302, 9003, 'cd /tmp/closed-tab-cwd && claude', '/Users/u');",
            "INSERT INTO blocks (id, pane_leaf_uuid, block_id) VALUES " +
                "(1, x'DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD', 'precmd-9001-1')," +
                "(2, x'EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE', 'precmd-9002-1')," +
                "(3, x'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF', 'precmd-9003-1');",
        ])

        /// Three tabs in one window. Tab 1 cwd=giftcard (pane uuid AAAA...),
        /// tab 2 cwd=open-vibe-island (pane uuid BBBB...), tab 3 cwd=/tmp (pane uuid CCCC...).
        /// Claude was launched in giftcard from Warp shell session 1001 and in open-vibe-island from 1002.
        static let threeTabsTwoClaudes = Scenario(rows: [
            "INSERT INTO app (id, active_window_id) VALUES (1, 1);",
            "INSERT INTO windows (id, active_tab_index) VALUES (1, 1);", // tab index 1 = second tab (0-based)
            "INSERT INTO tabs (id, window_id) VALUES (1, 1), (2, 1), (3, 1);",
            "INSERT INTO pane_nodes (id, tab_id, is_leaf) VALUES (1, 1, 1), (2, 2, 1), (3, 3, 1);",
            "INSERT INTO terminal_panes (id, uuid, cwd) VALUES " +
                "(1, x'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', '/Users/u/giftcard')," +
                "(2, x'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB', '/Users/u/open-vibe-island')," +
                "(3, x'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC', '/tmp');",
            "INSERT INTO commands (id, session_id, command, pwd) VALUES " +
                "(100, 1001, 'cd giftcard', '/Users/u')," +
                "(101, 1001, 'claude --dangerously-skip-permissions', '/Users/u/giftcard')," +
                "(200, 1002, 'claude --dangerously-skip-permissions', '/Users/u/open-vibe-island');",
            "INSERT INTO blocks (id, pane_leaf_uuid, block_id) VALUES " +
                "(1, x'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'precmd-1001-1')," +
                "(2, x'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'precmd-1001-2')," +
                "(3, x'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB', 'precmd-1002-1');",
        ])
    }
}
