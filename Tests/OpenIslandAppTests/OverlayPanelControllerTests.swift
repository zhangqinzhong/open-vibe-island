import AppKit
import Testing
@testable import OpenIslandApp

struct OverlayPanelControllerTests {
    @Test
    func closedSurfaceRectRemovesPanelShadowInsets() {
        let panelFrame = NSRect(x: 100, y: 900, width: 320, height: 38)

        let rect = OverlayPanelController.closedSurfaceRect(
            for: panelFrame,
            shadowInsets: (horizontal: 12, bottom: 14)
        )

        #expect(rect.minX == 112)
        #expect(rect.minY == 914)
        #expect(rect.width == 296)
        #expect(rect.height == 24)
    }

    @Test
    func closedSurfaceRectKeepsFullVisibleWidthInteractive() {
        let panelFrame = NSRect(x: 500, y: 1_000, width: 420, height: 38)

        let rect = OverlayPanelController.closedSurfaceRect(
            for: panelFrame,
            shadowInsets: (horizontal: 12, bottom: 14)
        )

        #expect(rect.contains(NSPoint(x: rect.minX + 2, y: rect.midY)))
        #expect(rect.contains(NSPoint(x: rect.maxX - 2, y: rect.midY)))
        #expect(!rect.contains(NSPoint(x: rect.minX - 1, y: rect.midY)))
        #expect(!rect.contains(NSPoint(x: rect.maxX + 1, y: rect.midY)))
    }
}
