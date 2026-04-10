import Foundation
import Testing
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
}
