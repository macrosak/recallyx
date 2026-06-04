import AppKit

// Renders a 1024×1024 Recallyx app icon: a macOS squircle with a blue→indigo
// diagonal gradient (echoing the design's wallpaper) and the white stacked-clips
// brand mark (the `Mark` from the proposal), then writes a PNG.

let S = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext

let Sf = CGFloat(S)
ctx.clear(CGRect(x: 0, y: 0, width: Sf, height: Sf))

// macOS icon grid: rounded square inset ~100px, corner radius ≈ 0.2237·side.
let margin: CGFloat = 100
let side = Sf - 2 * margin
let corner = side * 0.2237
let squircleRect = CGRect(x: margin, y: margin, width: side, height: side)
let squircle = NSBezierPath(roundedRect: squircleRect, xRadius: corner, yRadius: corner)

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// Diagonal gradient: light blue (top-left) → blue → indigo/purple (bottom-right).
ctx.saveGState()
squircle.addClip()
let cg = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [rgb(0x3A9BFF), rgb(0x1F5FE0), rgb(0x4A2F86)] as CFArray,
    locations: [0, 0.55, 1]
)!
// y-up context: top-left is (margin, S-margin), bottom-right is (S-margin, margin).
ctx.drawLinearGradient(cg,
    start: CGPoint(x: margin, y: Sf - margin),
    end: CGPoint(x: Sf - margin, y: margin),
    options: [])

// Soft top highlight for a little depth.
let hi = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18),
             CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(hi,
    start: CGPoint(x: margin, y: Sf - margin),
    end: CGPoint(x: margin, y: Sf - margin - side * 0.55),
    options: [])
ctx.restoreGState()

// ── Brand mark: two offset rounded-rect "clips" (viewBox 24, mapped to a
// 480px region centered in the tile). Back clip upper-right (faint outline),
// front clip lower-left (faint fill + crisp outline) — both white.
let scaleM: CGFloat = 480.0 / 24.0
let topY = Sf / 2 + 240            // viewBox y=0 maps here (y-up)
func markRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat) -> NSBezierPath {
    let r = CGRect(x: Sf / 2 - 240 + x * scaleM,
                   y: topY - (y + w) * scaleM,
                   width: w * scaleM, height: w * scaleM)
    return NSBezierPath(roundedRect: r, xRadius: 3.2 * scaleM, yRadius: 3.2 * scaleM)
}

ctx.saveGState()
squircle.addClip()
let lw = 1.7 * scaleM

// Back clip — outline only, faint.
let back = markRect(7.5, 3.5, 13)
back.lineWidth = lw
NSColor(white: 1, alpha: 0.55).setStroke()
back.stroke()

// Front clip — faint fill + crisp outline.
let front = markRect(3.5, 7.5, 13)
front.lineWidth = lw
NSColor(white: 1, alpha: 0.20).setFill()
front.fill()
NSColor(white: 1, alpha: 1.0).setStroke()
front.stroke()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/recallyx-icon.png"
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
