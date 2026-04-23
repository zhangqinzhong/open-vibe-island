import Foundation
import OpenIslandCore

enum IslandSurface: Equatable {
    case sessionList(actionableSessionID: String? = nil)

    var sessionID: String? {
        switch self {
        case let .sessionList(actionableSessionID):
            actionableSessionID
        }
    }

    var isNotificationCard: Bool {
        sessionID != nil
    }

    func autoDismissesWhenPresentedAsNotification(session: AgentSession?) -> Bool {
        guard sessionID != nil else { return false }
        return session?.phase == .completed
    }

    static func notificationSurface(for event: AgentEvent) -> IslandSurface? {
        switch event {
        case let .permissionRequested(payload):
            .sessionList(actionableSessionID: payload.sessionID)
        case let .questionAsked(payload):
            .sessionList(actionableSessionID: payload.sessionID)
        case let .sessionCompleted(payload):
            payload.isInterrupt == true ? nil : .sessionList(actionableSessionID: payload.sessionID)
        default:
            nil
        }
    }

    func matchesCurrentState(of session: AgentSession?) -> Bool {
        guard sessionID != nil else {
            return true
        }

        guard let session else {
            return false
        }

        switch session.phase {
        case .waitingForApproval:
            return session.permissionRequest != nil
        case .waitingForAnswer:
            return session.questionPrompt != nil
        case .completed:
            return true
        case .running:
            // A .running update can race with a permissionRequest/questionAsked
            // event: the hook sends PreToolUse (→ .running) immediately before
            // PermissionRequest (→ .waitingForApproval). Keep the notification
            // card open if the session still has a pending permission request or
            // question — the card will self-dismiss once the user acts on it.
            return session.permissionRequest != nil || session.questionPrompt != nil
        }
    }
}
