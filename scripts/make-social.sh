#!/usr/bin/env bash
# Composites a screenshot into the social-banner template:
#
#   ./scripts/make-social.sh [SCREENSHOT]   (default: docs/recallyx-history-dark.png)
#
# → docs/recallyx-social.png (2560×1280, referenced by the README)
# → docs/recallyx-social-1280x640.png (for GitHub's social-preview upload,
#   which rejects files over ~1 MB)
#
# The template (docs/recallyx-banner-template-2560x1280.png) carries a
# transparent rounded-rect hole; the script finds it by scanning for long
# transparent pixel runs (so the template can be re-exported with a moved or
# resized slot and nothing here changes), aspect-fills the screenshot into the
# hole's bounds, and draws the template over it — the hole's anti-aliased
# rounded edge does the clipping.
set -euo pipefail
cd "$(dirname "$0")/.."

SHOT="${1:-docs/recallyx-history-dark.png}"
TEMPLATE=docs/recallyx-banner-template-2560x1280.png
OUT=docs/recallyx-social.png
OUT_SMALL=docs/recallyx-social-1280x640.png

[[ -f "$SHOT" ]] || { echo "screenshot not found: $SHOT" >&2; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "template not found: $TEMPLATE" >&2; exit 1; }

swift - "$TEMPLATE" "$SHOT" "$OUT" "$OUT_SMALL" <<'EOF'
import AppKit

let args = CommandLine.arguments
func loadCG(_ path: String) -> CGImage {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fputs("cannot read \(path)\n", stderr); exit(1)
    }
    return cg
}
let template = loadCG(args[1])
let shot = loadCG(args[2])
let W = template.width, H = template.height

// Render the template once to inspect alpha (RGBA8, buffer row 0 = top row).
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let scan = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                     bytesPerRow: W * 4, space: cs,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
scan.draw(template, in: CGRect(x: 0, y: 0, width: W, height: H))
let buf = scan.data!.bindMemory(to: UInt8.self, capacity: W * H * 4)

// Longest fully-transparent run per row; runs > 600 px belong to the hole.
func holeRun(row: Int) -> (start: Int, end: Int)? {
    var best: (Int, Int)? = nil
    var runStart = -1
    for x in 0...W {
        let isHole = x < W && buf[(row * W + x) * 4 + 3] < 8
        if isHole { if runStart < 0 { runStart = x } }
        else if runStart >= 0 {
            if best == nil || x - runStart > best!.1 - best!.0 { best = (runStart, x - 1) }
            runStart = -1
        }
    }
    if let b = best, b.1 - b.0 + 1 > 600 { return b }
    return nil
}

var top = -1, bottom = -1, left = W, right = -1
for y in 0..<H {
    guard let run = holeRun(row: y) else { continue }
    if top < 0 { top = y }
    bottom = y
    left = min(left, run.start)
    right = max(right, run.end)
}
guard top >= 0 else { fputs("no transparent placeholder found in template\n", stderr); exit(1) }

let slot = CGRect(x: left, y: H - 1 - bottom,                       // CG bottom-left origin
                  width: right - left + 1, height: bottom - top + 1)
fputs("slot: \(Int(slot.width))×\(Int(slot.height)) at (\(left),\(top))\n", stderr)

let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                    bytesPerRow: W * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high

// Screenshot under, template over: the hole's rounded edge clips the shot.
// Aspect-fill crops a sliver of the screenshot's wallpaper margin; the
// overflow is hidden by the opaque template around the hole.
let scale = max(slot.width / CGFloat(shot.width), slot.height / CGFloat(shot.height))
let drawW = CGFloat(shot.width) * scale, drawH = CGFloat(shot.height) * scale
ctx.draw(shot, in: CGRect(x: slot.midX - drawW / 2, y: slot.midY - drawH / 2,
                          width: drawW, height: drawH))
ctx.draw(template, in: CGRect(x: 0, y: 0, width: W, height: H))

let out = ctx.makeImage()!
func writePNG(_ image: CGImage, to path: String) {
    let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fputs("PNG write failed: \(path)\n", stderr); exit(1) }
}
writePNG(out, to: args[3])

// Half-size variant for GitHub's social-preview upload (~1 MB cap).
let small = CGContext(data: nil, width: W / 2, height: H / 2, bitsPerComponent: 8,
                      bytesPerRow: W / 2 * 4, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
small.interpolationQuality = .high
small.draw(out, in: CGRect(x: 0, y: 0, width: W / 2, height: H / 2))
writePNG(small.makeImage()!, to: args[4])
EOF

echo "$OUT"
echo "$OUT_SMALL"
