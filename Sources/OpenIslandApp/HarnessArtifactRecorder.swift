import AppKit
import Foundation

struct HarnessArtifactReport: Codable {
    struct WindowArtifact: Codable {
        let kind: String
        let title: String
        let frame: RectSnapshot
        let imagePath: String
    }

    struct RectSnapshot: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(_ rect: NSRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.size.width
            height = rect.size.height
        }
    }

    struct OverlaySnapshot: Codable {
        let screenID: String
        let screenName: String
        let selectionSummary: String
        let mode: String
        let screenFrame: RectSnapshot
        let visibleFrame: RectSnapshot
        let overlayFrame: RectSnapshot
        let safeAreaInsets: EdgeInsetsSnapshot
    }

    struct EdgeInsetsSnapshot: Codable {
        let top: Double
        let left: Double
        let bottom: Double
        let right: Double

        init(_ insets: NSEdgeInsets) {
            top = insets.top
            left = insets.left
            bottom = insets.bottom
            right = insets.right
        }
    }

    struct SessionSnapshot: Codable {
        let id: String
        let tool: String
        let phase: String
        let attachmentState: String
        let title: String
        let summary: String
    }

    let scenario: String?
    let presentOverlay: Bool
    let showedControlCenter: Bool
    let startedBridge: Bool
    let performedBootAnimation: Bool
    let capturedAt: Date
    let launchToCaptureSeconds: Double
    let windows: [WindowArtifact]
    let overlay: OverlaySnapshot?
    let sessionCount: Int
    let liveSessionCount: Int
    let attentionCount: Int
    let selectedSessionID: String?
    let islandSurface: String
    let notchStatus: String
    let sessions: [SessionSnapshot]
}

@MainActor
enum HarnessArtifactRecorder {
    static func record(
        configuration: HarnessLaunchConfiguration,
        model: AppModel,
        launchedAt: Date,
        fileManager: FileManager = .default
    ) throws {
        guard let directoryURL = configuration.artifactDirectoryURL else {
            return
        }

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var windows: [HarnessArtifactReport.WindowArtifact] = []
        for window in orderedVisibleWindows() {
            guard let imageData = snapshotPNGData(for: window) else {
                continue
            }

            let imageName = imageFileName(for: window, ordinal: windows.count + 1)
            let imageURL = directoryURL.appendingPathComponent(imageName)
            try imageData.write(to: imageURL)

            windows.append(
                HarnessArtifactReport.WindowArtifact(
                    kind: windowKind(for: window),
                    title: window.title,
                    frame: .init(window.frame),
                    imagePath: imageName
                )
            )
        }

        let report = HarnessArtifactReport(
            scenario: configuration.scenario?.rawValue,
            presentOverlay: configuration.presentOverlay,
            showedControlCenter: configuration.shouldShowControlCenter,
            startedBridge: configuration.shouldStartBridge,
            performedBootAnimation: configuration.shouldPerformBootAnimation,
            capturedAt: .now,
            launchToCaptureSeconds: Date().timeIntervalSince(launchedAt),
            windows: windows,
            overlay: overlaySnapshot(from: model.overlayPlacementDiagnostics),
            sessionCount: model.sessions.count,
            liveSessionCount: model.liveSessionCount,
            attentionCount: model.liveAttentionCount,
            selectedSessionID: model.selectedSessionID,
            islandSurface: surfaceDescription(model.islandSurface),
            notchStatus: notchStatusDescription(model.notchStatus),
            sessions: model.sessions.map {
                HarnessArtifactReport.SessionSnapshot(
                    id: $0.id,
                    tool: $0.tool.rawValue,
                    phase: $0.phase.rawValue,
                    attachmentState: $0.attachmentState.rawValue,
                    title: $0.title,
                    summary: $0.summary
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let reportURL = directoryURL.appendingPathComponent("report.json")
        try encoder.encode(report).write(to: reportURL)
    }

    private static func orderedVisibleWindows() -> [NSWindow] {
        NSApp.windows
            .filter { window in
                window.isVisible && recognizedWindowKind(for: window) != nil
            }
            .sorted { lhs, rhs in
                lhs.frame.maxY > rhs.frame.maxY
            }
    }

    private static func snapshotPNGData(for window: NSWindow) -> Data? {
        window.displayIfNeeded()
        guard let contentView = window.contentView else {
            return nil
        }

        contentView.layoutSubtreeIfNeeded()
        let bounds = contentView.bounds.integral
        guard bounds.width > 0,
              bounds.height > 0,
              let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }

        bitmap.size = bounds.size
        contentView.cacheDisplay(in: bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func imageFileName(for window: NSWindow, ordinal: Int) -> String {
        let baseName: String
        switch recognizedWindowKind(for: window) ?? "window" {
        case "overlay":
            baseName = "overlay"
        case "control-center":
            baseName = "control-center"
        default:
            baseName = "window-\(ordinal)"
        }

        return "\(baseName).png"
    }

    private static func windowKind(for window: NSWindow) -> String {
        recognizedWindowKind(for: window) ?? "window"
    }

    private static func recognizedWindowKind(for window: NSWindow) -> String? {
        if window is NSPanel {
            return window.frame.width >= 120 ? "overlay" : nil
        }

        if window.title == "Open Island Debug" {
            return "control-center"
        }

        return nil
    }

    private static func overlaySnapshot(
        from diagnostics: OverlayPlacementDiagnostics?
    ) -> HarnessArtifactReport.OverlaySnapshot? {
        guard let diagnostics else {
            return nil
        }

        return HarnessArtifactReport.OverlaySnapshot(
            screenID: diagnostics.targetScreenID,
            screenName: diagnostics.targetScreenName,
            selectionSummary: diagnostics.selectionSummary,
            mode: diagnostics.mode.rawValue,
            screenFrame: .init(diagnostics.screenFrame),
            visibleFrame: .init(diagnostics.visibleFrame),
            overlayFrame: .init(diagnostics.overlayFrame),
            safeAreaInsets: .init(diagnostics.safeAreaInsets)
        )
    }

    private static func surfaceDescription(_ surface: IslandSurface) -> String {
        switch surface {
        case .sessionList:
            "sessionList"
        case let .approvalCard(sessionID):
            "approvalCard:\(sessionID)"
        case let .questionCard(sessionID):
            "questionCard:\(sessionID)"
        case let .completionCard(sessionID):
            "completionCard:\(sessionID)"
        }
    }

    private static func notchStatusDescription(_ status: NotchStatus) -> String {
        switch status {
        case .closed:
            "closed"
        case .opened:
            "opened"
        case .popping:
            "popping"
        }
    }
}
