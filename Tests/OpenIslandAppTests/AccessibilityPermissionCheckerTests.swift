import XCTest
@testable import OpenIslandApp

final class AccessibilityPermissionCheckerTests: XCTestCase {
    func testCheckerReportsBoolWithoutCrashing() {
        // We cannot assume the test host has (or lacks) Accessibility.
        // The point of this test is that the call returns cleanly and
        // doesn't prompt the user during `swift test`.
        let checker = DefaultAccessibilityPermissionChecker()
        _ = checker.isTrusted()
    }

    func testStubCheckerReturnsInjectedValue() {
        let trueChecker = AccessibilityPermissionCheckerStub(trusted: true)
        XCTAssertTrue(trueChecker.isTrusted())

        let falseChecker = AccessibilityPermissionCheckerStub(trusted: false)
        XCTAssertFalse(falseChecker.isTrusted())
    }
}

struct AccessibilityPermissionCheckerStub: AccessibilityPermissionChecker {
    let trusted: Bool
    func isTrusted() -> Bool { trusted }
}
