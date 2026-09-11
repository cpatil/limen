// Draws Bottleneck's app icon and writes Resources/Bottleneck.icns.
//
//   swift tools/make-icon.swift        (build.sh does this for you)
//
// Generated rather than checked in as pixels so the shape can be adjusted and every
// size regenerated from one description. The subject is data moving across a
// threshold, which is what the app is for and what its name means: two streams in
// opposite directions - green for read/in, blue for write/out, matching the colours
// the rows use - passing through a gap in a vertical bar.
//
// Drawn to read at 16pt as well as 1024. At the small end the two arrows and the gap
// are all that survive, so nothing else is allowed to compete with them.

import AppKit
import Foundation

func icon(_ size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)

    // macOS icons sit on a rounded square with a corner radius just over a fifth of
    // the side; anything squarer looks foreign in the Dock.
    let inset = s * 0.055
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.2237
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    ctx.saveGState()
    shape.addClip()
    let backdrop = NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.18, blue: 0.23, alpha: 1),
                                       NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 1)])!
    backdrop.draw(in: body, angle: -90)
    ctx.restoreGState()

    // The threshold: a bar down the middle with a gap the streams pass through.
    let barWidth = s * 0.055
    let gap = s * 0.34
    let barX = s / 2 - barWidth / 2
    let top = s * 0.86, bottom = s * 0.14
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22).setFill()
    for segment in [CGRect(x: barX, y: bottom, width: barWidth,
                           height: s / 2 - gap / 2 - bottom),
                    CGRect(x: barX, y: s / 2 + gap / 2, width: barWidth,
                           height: top - (s / 2 + gap / 2))] {
        NSBezierPath(roundedRect: segment, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }

    /// One stream: a thick shaft with a chevron head, pointing right or left.
    func stream(y: CGFloat, thickness: CGFloat, pointingRight: Bool, colour: NSColor) {
        let left = s * 0.16, right = s * 0.84
        let head = s * 0.17
        let path = NSBezierPath()
        let tipX = pointingRight ? right : left
        let backX = pointingRight ? left : right
        let headBase = pointingRight ? tipX - head : tipX + head
        let half = thickness / 2
        let shaftHalf = thickness * 0.30

        path.move(to: NSPoint(x: tipX, y: y))
        path.line(to: NSPoint(x: headBase, y: y + half))
        path.line(to: NSPoint(x: headBase, y: y + shaftHalf))
        path.line(to: NSPoint(x: backX, y: y + shaftHalf))
        path.line(to: NSPoint(x: backX, y: y - shaftHalf))
        path.line(to: NSPoint(x: headBase, y: y - shaftHalf))
        path.line(to: NSPoint(x: headBase, y: y - half))
        path.close()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                      blur: s * 0.03,
                      color: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45).cgColor)
        colour.setFill()
        path.fill()
        ctx.restoreGState()
    }

    // Green above moving one way, blue below moving the other: the two directions the
    // app always shows side by side.
    stream(y: s * 0.635, thickness: s * 0.26, pointingRight: true,
           colour: NSColor(srgbRed: 0.30, green: 0.85, blue: 0.44, alpha: 1))
    stream(y: s * 0.365, thickness: s * 0.26, pointingRight: false,
           colour: NSColor(srgbRed: 0.28, green: 0.62, blue: 1.00, alpha: 1))

    // A hairline rim, so the icon keeps an edge on a light desktop.
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10).setStroke()
    shape.lineWidth = max(1, s * 0.006)
    shape.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/Bottleneck.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// iconutil wants this exact naming.
let wanted: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in wanted {
    let data = icon(px).representation(using: .png, properties: [:])!
    try data.write(to: iconset.appendingPathComponent("\(name).png"))
}
print("wrote \(wanted.count) sizes to \(iconset.path)")
