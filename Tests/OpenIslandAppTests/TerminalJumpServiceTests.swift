import XCTest
@testable import OpenIslandApp
import OpenIslandCore

final class TerminalJumpServiceTests: XCTestCase {
    func testGhosttyJumpScriptActivatesAndWaitsForFocusToSettle() {
        let target = JumpTarget(
            terminalApp: "Ghostty",
            workspaceName: "open-island",
            paneTitle: "codex ~/p/open-island",
            workingDirectory: "/Users/wangruobing/Personal/open-island",
            terminalSessionID: "448D7E28-24FB-46F1-9504-C252F97926C1"
        )

        let script = TerminalJumpService().ghosttyJumpScript(for: target)

        XCTAssertTrue(script.contains("activate"))
        XCTAssertTrue(script.contains("focus targetTerminal"))
        XCTAssertTrue(script.contains("delay 0.15"))
        XCTAssertTrue(script.contains("focused terminal of selected tab of front window"))
        XCTAssertTrue(script.contains("(id of aTerminal as text) is \"448D7E28-24FB-46F1-9504-C252F97926C1\""))
    }

    func testGhosttyJumpScriptFallsBackToWorkingDirectoryAndTitle() {
        let target = JumpTarget(
            terminalApp: "Ghostty",
            workspaceName: "open-island",
            paneTitle: "codex ~/p/open-island",
            workingDirectory: "/Users/wangruobing/Personal/open-island"
        )

        let script = TerminalJumpService().ghosttyJumpScript(for: target)

        XCTAssertTrue(script.contains("(working directory of aTerminal as text) is \"/Users/wangruobing/Personal/open-island\""))
        XCTAssertTrue(script.contains("(name of aTerminal as text) contains \"codex ~/p/open-island\""))
        XCTAssertTrue(script.contains("if \"\" is \"\" then"))
    }
}
