import Foundation
import ApplicationServices

/// Checks whether the current process has macOS Accessibility permission,
/// required for CGEventPost keystroke injection used by Warp precision jump.
public protocol AccessibilityPermissionChecker {
    func isTrusted() -> Bool
}

public struct DefaultAccessibilityPermissionChecker: AccessibilityPermissionChecker {
    public init() {}

    public func isTrusted() -> Bool {
        // Pass `prompt: false` so unit tests don't pop the system dialog.
        // The real jump flow calls AXIsProcessTrustedWithOptions with the
        // prompt key separately, guarded by the first-jump-attempt code path.
        AXIsProcessTrusted()
    }
}
