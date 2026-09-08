import Cocoa

/// An enlarged card for whatever the pointer is over.
///
/// The rows clip text to fit their columns, so this is where the full value has to be
/// readable - which means it sizes itself to its content and wraps rather than
/// truncating. A panel that also cut its text off would defeat its own purpose.
final class MagnifierView: NSView {
    enum Zone {
        case rate, chart, info
    }

    var row: Row?
    var zone: Zone = .rate
    var unit: RateUnit = .bytes
    var details: String = ""
    var sampleInterval: TimeInterval = 1

    static let width: CGFloat = 400
    private static let pad: CGFloat = 18
    private static let chartHeight: CGFloat = 76

    private let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private let bodyFont = NSFont.systemFont(ofSize: 12.5)
    private let smallFont = NSFont.systemFont(ofSize: 12)
    private let badgeFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private let tickFont = NSFont.systemFont(ofSize: 10)
    private let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 19, weight: .medium)
    private let tagFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)

    /// Text-only in a flipped space, so blocks can be laid out top-down and measured
    /// with the same code that draws them.
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var contentWidth: CGFloat { MagnifierView.width - MagnifierView.pad * 2 }

    // The variable-length blocks, in the order they appear.
    private func blocks(for row: Row) -> [(text: String, font: NSFont, color: NSColor)] {
        var out: [(String, NSFont, NSColor)] = []

        var identity: [String] = []
        if !row.vendor.isEmpty, row.vendor != row.title { identity.append(row.vendor) }
        if !row.deviceID.isEmpty { identity.append(row.deviceID) }
        if !row.volumes.isEmpty { identity.append(row.volumes.joined(separator: ", ")) }
        if identity.isEmpty, !row.subtitle.isEmpty { identity.append(row.subtitle) }
        if !identity.isEmpty {
            out.append((identity.joined(separator: "  ·  "), bodyFont, NSColor.labelColor))
        }

        if !row.appleName.isEmpty {
            // Its own line. Squeezed onto the link row beside the badge and the speed
            // it had nowhere to go and was being cut mid-word.
            out.append(("Apple calls this " + row.appleName, smallFont, NSColor.secondaryLabelColor))
        }
        return out
    }

    private func footerBlocks(for row: Row) -> [(text: String, font: NSFont, color: NSColor)] {
        var out: [(String, NSFont, NSColor)] = []

        var facts = ["total " + Fmt.bytes(Double(row.totalDown)) + " " + row.inLong.lowercased()
                     + " · " + Fmt.bytes(Double(row.totalUp)) + " " + row.outLong.lowercased()]
        if row.peak > 0 { facts.append("peak " + Fmt.rate(row.peak, unit: unit)) }
        out.append((facts.joined(separator: "  ·  "), bodyFont, NSColor.secondaryLabelColor))

        for actor in row.actors {
            out.append((actor.display + "   " + Fmt.rate(actor.bytesPerSec, unit: unit),
                        smallFont, NSColor.labelColor))
        }
        if !row.hint.isEmpty {
            out.append((row.hint, smallFont, NSColor.systemBlue))
        }
        return out
    }

    /// How much of the link is in use, when that can be judged.
    private func usage(_ row: Row) -> Double? {
        guard row.linkTrusted else { return nil }
        return Reference.utilization(bytesPerSec: row.down + row.up, linkBits: row.linkBits)
    }

    private func hasLinkRow(_ row: Row) -> Bool {
        !row.badge.isEmpty || (row.linkTrusted && row.linkBits > 0) || !row.appleName.isEmpty
    }

    /// Exactly as tall as its content needs, so nothing is ever cut off.
    var fittingHeight: CGFloat {
        guard let row = row else { return 120 }
        let pad = MagnifierView.pad
        var height = pad + 26                                    // icon + title
        for block in blocks(for: row) {
            height += Text.wrappedHeight(block.text, font: block.font, width: contentWidth) + 5
        }
        if hasLinkRow(row) { height += 26 }
        if usage(row) != nil { height += 28 }
        height += 10 + 14 + MagnifierView.chartHeight + 12       // scale labels + chart
        height += 46                                             // the two big rates
        for block in footerBlocks(for: row) {
            height += Text.wrappedHeight(block.text, font: block.font, width: contentWidth) + 4
        }
        return height + pad
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row = row else { return }

        let card = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
        // Concrete components with full alpha, so the fill cannot be translucent
        // whatever the appearance resolves to.
        let base = (NSColor.controlBackgroundColor.usingColorSpace(.sRGB)
                    ?? NSColor.white).withAlphaComponent(1.0)
        base.setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1
        path.stroke()

        let pad = MagnifierView.pad
        let left = card.minX + pad
        let width = contentWidth
        var y = card.minY + pad

        Icons.draw(row.icon, in: NSRect(x: left, y: y, width: 20, height: 20),
                   color: NSColor.secondaryLabelColor)
        Text.draw(row.title, at: NSPoint(x: left + 28, y: y + 1),
                  font: titleFont, color: NSColor.labelColor)
        y += 24

        for block in blocks(for: row) {
            let h = Text.wrappedHeight(block.text, font: block.font, width: width)
            Text.drawWrapped(block.text, in: NSRect(x: left, y: y, width: width, height: h),
                             font: block.font, color: block.color)
            y += h + 5
        }

        // ---- the link, given the weight it deserves -------------------------
        // The standard is what a row is most often read for, so it gets a badge and
        // full-strength text rather than being the faintest thing on the card.
        if hasLinkRow(row) {
            var x = left
            if !row.badge.isEmpty {
                x += Text.drawBadge(row.badge, at: NSPoint(x: x, y: y + 2),
                                    font: badgeFont, prominent: true) + 8
            }
            if row.linkTrusted, row.linkBits > 0 {
                let primary = Fmt.speed(bitsPerSec: row.linkBits, unit: unit)
                Text.draw(primary, at: NSPoint(x: x, y: y + 4), font: bodyFont,
                          color: NSColor.labelColor)
                x += Text.width(primary, font: bodyFont) + 8
                let other = "= " + Fmt.alternateSpeed(bitsPerSec: row.linkBits, unit: unit)
                Text.draw(other, at: NSPoint(x: x, y: y + 5), font: smallFont,
                          color: NSColor.tertiaryLabelColor)
            }
            y += 26
        }

        // ---- history, labelled with its own scale ---------------------------
        y += 10
        let scale = Chart.peak(down: row.downHist, up: row.upHist)
        let span = Double(Monitor.historyLength) * sampleInterval
        Text.draw(span >= 120 ? String(format: "last %.0f min", span / 60)
                              : String(format: "last %.0f s", span),
                  at: NSPoint(x: left, y: y), font: tickFont, color: NSColor.tertiaryLabelColor)
        Text.draw(Fmt.rate(scale, unit: unit) + " full scale",
                  at: NSPoint(x: 0, y: y), font: tickFont,
                  color: NSColor.secondaryLabelColor, alignRight: left + width)
        y += 14
        NSColor.tertiaryLabelColor.withAlphaComponent(0.4).setFill()
        NSRect(x: left, y: y, width: width, height: 1).fill()

        let chart = NSRect(x: left, y: y, width: width, height: MagnifierView.chartHeight)
        NSGraphicsContext.saveGraphicsState()
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: chart.maxY + chart.minY)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        Chart.draw(down: row.downHist, up: row.upHist, in: chart, lineWidth: 1.8)
        NSGraphicsContext.restoreGraphicsState()
        y += MagnifierView.chartHeight + 12

        // ---- live rates -----------------------------------------------------
        let mid = left + width / 2
        Text.draw(row.inLong, at: NSPoint(x: left, y: y), font: tagFont, color: Palette.down)
        Text.draw(row.outLong, at: NSPoint(x: mid, y: y), font: tagFont, color: Palette.up)
        Text.draw(Fmt.rate(row.down, unit: unit), at: NSPoint(x: left, y: y + 13),
                  font: rateFont, color: Palette.down)
        Text.draw(Fmt.rate(row.up, unit: unit), at: NSPoint(x: mid, y: y + 13),
                  font: rateFont, color: Palette.up)
        y += 46

        // A bar as well as a number: the share of a link is a proportion, and a
        // proportion is read faster as a length than as text.
        if let used = usage(row) {
            let barWidth = width - 92
            let bar = NSRect(x: left, y: y + 5, width: barWidth, height: 7)
            Palette.hairline.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 3.5, yRadius: 3.5).fill()
            let fraction = CGFloat(min(1, max(0, used)))
            let fill = used >= 0.85 ? NSColor.systemOrange
                     : (used >= 0.40 ? Palette.down : Palette.up)
            fill.setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY,
                                             width: max(3, barWidth * fraction), height: bar.height),
                         xRadius: 3.5, yRadius: 3.5).fill()
            if let peakUsed = Reference.utilization(bytesPerSec: row.peak, linkBits: row.linkBits),
               peakUsed > used + 0.03 {
                let x = bar.minX + barWidth * CGFloat(min(1, peakUsed))
                NSColor.labelColor.withAlphaComponent(0.6).setFill()
                NSRect(x: min(bar.maxX - 2, x - 1), y: bar.minY - 3, width: 2, height: 13).fill()
            }
            Text.draw(String(format: "%.0f%% of link", used * 100),
                      at: NSPoint(x: bar.maxX + 10, y: y),
                      font: smallFont,
                      color: used >= 0.85 ? NSColor.systemOrange : NSColor.secondaryLabelColor)
            y += 28
        }

        for block in footerBlocks(for: row) {
            let h = Text.wrappedHeight(block.text, font: block.font, width: width)
            Text.drawWrapped(block.text, in: NSRect(x: left, y: y, width: width, height: h),
                             font: block.font, color: block.color)
            y += h + 4
        }
    }
}
