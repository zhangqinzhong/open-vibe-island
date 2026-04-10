import Foundation
import CoreGraphics

/// Injection point for CGEvent keystroke delivery. Implementations must be
/// safe to call from any thread.
public protocol KeystrokeInjector {
    func sendCmdShiftRightBracket()
}

/// Production implementation that posts a synthetic Cmd+Shift+] via CGEventPost.
/// Requires macOS Accessibility permission; will silently no-op (events are
/// dropped by the system) if permission is denied. Callers should check
/// permission separately if they need reliable delivery.
public struct DefaultKeystrokeInjector: KeystrokeInjector {
    public init() {}

    public func sendCmdShiftRightBracket() {
        // Virtual keycode 0x1E is the US-layout `]` key. Cmd+Shift+] is the
        // Warp default "next tab" shortcut.
        let keyCode: CGKeyCode = 0x1E
        let source = CGEventSource(stateID: .combinedSessionState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return
        }

        keyDown.flags = [.maskCommand, .maskShift]
        keyUp.flags = [.maskCommand, .maskShift]

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
