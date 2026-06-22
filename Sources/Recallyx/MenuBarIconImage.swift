import AppKit
import RecallyxCore

/// The menu-bar glyph: the Recallyx brand mark (two offset rounded "clips")
/// rendered as a **template** image so macOS tints it to match the menu bar in
/// both light and dark mode. Same geometry as `BrandMark` / `gen-icon.swift`
/// (viewBox 24), so the status item echoes the app icon.
///
/// Resolution-independent: the drawing handler re-runs at whatever scale the
/// menu bar asks for, so it stays crisp on Retina.
enum MenuBarIconImage {
    /// Standard menu-bar glyph box. macOS reserves ~22pt height; an 18pt mark
    /// leaves the conventional padding.
    static let pointSize: CGFloat = 18

    static let shared: NSImage = {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// Draws the mark into `rect` using the viewBox-24 coordinates of `BrandMark`.
    /// Template images are alpha masks, so colors are opaque black with the front
    /// clip kept slightly lighter via a faint fill to preserve the "stacked" read.
    private static func draw(in rect: NSRect) {
        let s = min(rect.width, rect.height)
        let ox = rect.minX + (rect.width - s) / 2
        let oy = rect.minY + (rect.height - s) / 2

        func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat) -> NSBezierPath {
            // viewBox y is top-down; NSBezierPath here is bottom-up, so flip y.
            let px = ox + x / 24 * s
            let py = oy + (24 - y - w) / 24 * s
            let pw = w / 24 * s
            let r = 3.2 / 24 * s
            return NSBezierPath(roundedRect: NSRect(x: px, y: py, width: pw, height: pw),
                                xRadius: r, yRadius: r)
        }

        let lineWidth = 1.7 / 24 * s

        // Back clip — outline only, slightly faint so it reads as "behind".
        let back = rrect(7.5, 3.5, 13)
        back.lineWidth = lineWidth
        NSColor.black.withAlphaComponent(0.55).setStroke()
        back.stroke()

        // Front clip — faint fill + crisp outline.
        let front = rrect(3.5, 7.5, 13)
        front.lineWidth = lineWidth
        NSColor.black.withAlphaComponent(0.16).setFill()
        front.fill()
        NSColor.black.setStroke()
        front.stroke()
    }
}
