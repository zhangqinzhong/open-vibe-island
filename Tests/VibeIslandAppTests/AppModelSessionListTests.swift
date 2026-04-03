import Foundation
import Testing
@testable import VibeIslandApp
import VibeIslandCore

@MainActor
struct AppModelSessionListTests {
    @Test
    func islandListSessionsOnlyIncludeLiveAttachedSessions() {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel()
        model.state = SessionState(
            sessions: [
                AgentSession(
                    id: "live-session",
                    title: "Claude · active",
                    tool: .claudeCode,
                    origin: .live,
                    attachmentState: .attached,
                    phase: .running,
                    summary: "Running",
                    updatedAt: now,
                    jumpTarget: JumpTarget(
                        terminalApp: "Ghostty",
                        workspaceName: "active",
                        paneTitle: "claude ~/active",
                        workingDirectory: "/tmp/active",
                        terminalSessionID: "ghostty-1"
                    ),
                    claudeMetadata: ClaudeSessionMetadata(
                        transcriptPath: "/tmp/live.jsonl",
                        currentTool: "Task"
                    )
                ),
                AgentSession(
                    id: "recent-session",
                    title: "Claude · recent",
                    tool: .claudeCode,
                    origin: .live,
                    attachmentState: .stale,
                    phase: .completed,
                    summary: "Finished",
                    updatedAt: now.addingTimeInterval(-300),
                    jumpTarget: JumpTarget(
                        terminalApp: "Ghostty",
                        workspaceName: "recent",
                        paneTitle: "claude ~/recent",
                        workingDirectory: "/tmp/recent",
                        terminalSessionID: "ghostty-2"
                    ),
                    claudeMetadata: ClaudeSessionMetadata(
                        transcriptPath: "/tmp/recent.jsonl",
                        lastAssistantMessage: "Finished"
                    )
                ),
            ]
        )

        #expect(model.surfacedSessions.map(\.id) == ["live-session"])
        #expect(model.recentSessions.map(\.id) == ["recent-session"])
        #expect(model.islandListSessions.map(\.id) == ["live-session"])
    }
}
