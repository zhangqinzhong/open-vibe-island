import AppKit
import SwiftUI

struct OpenIslandBrandMark: View {
    enum Style {
        case duotone
        case template
    }

    let size: CGFloat
    var tint: Color = .mint
    var isAnimating: Bool = false
    var style: Style = .duotone

    private static let scoutPattern = [
        "..B..B..",
        "..BBBB..",
        ".BHHHHB.",
        "BBHEHEBB",
        ".BHHHHB.",
        "..BBBB..",
        ".B....B.",
        "........",
    ]

    private static let pixels: [(x: Int, y: Int, role: Character)] = scoutPattern.enumerated().flatMap { rowIndex, row in
        row.enumerated().compactMap { columnIndex, character in
            character == "." ? nil : (columnIndex, rowIndex, character)
        }
    }

    /// Renders the brand mark as an NSImage with template mode enabled so
    /// macOS automatically inverts it for light/dark menu bar backgrounds.
    static func templateNSImage(size: CGFloat) -> NSImage {
        let gridSize = 8
        let cell = size / CGFloat(gridSize)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.black.setFill()
            for pixel in Self.pixels {
                // NSImage draws with flipped Y (origin bottom-left), so invert row.
                let x = CGFloat(pixel.x) * cell
                let y = CGFloat(gridSize - 1 - pixel.y) * cell
                let alpha: CGFloat = pixel.role == "E" ? 0.9 : 1.0
                NSColor.black.withAlphaComponent(alpha).setFill()
                NSBezierPath(rect: CGRect(x: x, y: y, width: cell, height: cell)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    var body: some View {
        GeometryReader { proxy in
            let cell = min(proxy.size.width / 8, proxy.size.height / 8)
            let markWidth = cell * 8
            let markHeight = cell * 8
            let originX = (proxy.size.width - markWidth) / 2
            let originY = (proxy.size.height - markHeight) / 2

            ZStack(alignment: .topLeading) {
                ForEach(Array(Self.pixels.enumerated()), id: \.offset) { _, pixel in
                    Rectangle()
                        .fill(fillColor(for: pixel.role))
                        .frame(width: cell, height: cell)
                        .offset(
                            x: originX + CGFloat(pixel.x) * cell,
                            y: originY + CGFloat(pixel.y) * cell
                        )
                }
            }
        }
        .frame(width: size, height: size)
        .drawingGroup(opaque: false, colorMode: .extendedLinear)
    }

    private func fillColor(for role: Character) -> Color {
        switch style {
        case .duotone:
            switch role {
            case "B":
                return tint.opacity(isAnimating ? 1.0 : 0.86)
            case "H":
                return tint.opacity(isAnimating ? 0.84 : 0.64)
            case "E":
                return Color.black.opacity(0.72)
            default:
                return .clear
            }
        case .template:
            return Color.primary.opacity(role == "E" ? 0.9 : 1.0)
        }
    }
}
