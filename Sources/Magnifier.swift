import Cocoa

/// An enlarged card for whatever the pointer is over.
///
/// The rows pack a lot into small type. Rather than making every row bigger, the one
/// being looked at is shown properly: identity, link, live rates, history and what
/// is driving it, all at a size that can be read without leaning in. It follows the
/// pointer, never takes focus and never swallows clicks.
final class MagnifierView: NSView {
    enum Zone {
        case rate, chart, info
    }

    var row: Row?
    var zone: Zone = .rate
    var unit: RateUnit = .bytes
    var details: String = ""
    var sampleInterval: TimeInterval = 1

    static let size = NSSize(width: 392, height: 268)

    override var isFlipped: Bool { false }
    /// Never intercept the pointer - it sits above the list purely as decoration.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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

        let left = card.minX + 18
        let right = card.maxX - 18
        let width = right - left

        // ---- identity ----------------------------------------------------
        Icons.draw(row.icon, in: NSRect(x: left, y: card.maxY - 38, width: 20, height: 20),
                   color: NSColor.secondaryLabelColor)
        let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
        Text.draw(Text.clip(row.title, font: titleFont, maxWidth: width - 30),
                  at: NSPoint(x: left + 28, y: card.maxY - 38),
                  font: titleFont, color: NSColor.labelColor)

        let subFont = NSFont.systemFont(ofSize: 11.5)
        var identity: [String] = []
        if !row.vendor.isEmpty, row.vendor != row.title { identity.append(row.vendor) }
        if !row.deviceID.isEmpty { identity.append(row.deviceID) }
        if !row.volumes.isEmpty { identity.append(row.volumes.joined(separator: ", ")) }
        if identity.isEmpty, !row.subtitle.isEmpty { identity.append(row.subtitle) }
        Text.draw(Text.clip(identity.joined(separator: "  ·  "), font: subFont, maxWidth: width),
                  at: NSPoint(x: left, y: card.maxY - 58), font: subFont,
                  color: NSColor.secondaryLabelColor)

        // ---- link --------------------------------------------------------
        var link: [String] = []
        if !row.badge.isEmpty { link.append(row.badge) }
        if row.linkTrusted, row.linkBits > 0 {
            link.append(Fmt.dualSpeed(bitsPerSec: row.linkBits, unit: unit))
        }
        if !row.appleName.isEmpty { link.append("Apple: " + row.appleName) }
        if !link.isEmpty {
            Text.draw(Text.clip(link.joined(separator: "  ·  "), font: subFont, maxWidth: width),
                      at: NSPoint(x: left, y: card.maxY - 76), font: subFont,
                      color: NSColor.tertiaryLabelColor)
        }

        // ---- history -----------------------------------------------------
        let chart = NSRect(x: left, y: card.minY + 96, width: width, height: 74)
        Chart.draw(down: row.downHist, up: row.upHist, in: chart, lineWidth: 1.8)
        let tick = NSFont.systemFont(ofSize: 10)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.4).setFill()
        NSRect(x: chart.minX, y: chart.maxY, width: chart.width, height: 1).fill()
        let scale = Chart.peak(down: row.downHist, up: row.upHist)
        Text.draw(Fmt.rate(scale, unit: unit) + " full scale",
                  at: NSPoint(x: 0, y: chart.maxY + 3), font: tick,
                  color: NSColor.secondaryLabelColor, alignRight: right)
        let span = Double(Monitor.historyLength) * sampleInterval
        Text.draw(span >= 120 ? String(format: "last %.0f min", span / 60)
                              : String(format: "last %.0f s", span),
                  at: NSPoint(x: chart.minX, y: chart.maxY + 3), font: tick,
                  color: NSColor.tertiaryLabelColor)

        // ---- live rates --------------------------------------------------
        let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 19, weight: .medium)
        let tagFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        let rateY = card.minY + 62
        Text.draw(row.inLong, at: NSPoint(x: left, y: rateY + 20), font: tagFont, color: Palette.down)
        Text.draw(Fmt.rate(row.down, unit: unit),
                  at: NSPoint(x: left, y: rateY), font: rateFont, color: Palette.down)
        let mid = left + width / 2
        Text.draw(row.outLong, at: NSPoint(x: mid, y: rateY + 20), font: tagFont, color: Palette.up)
        Text.draw(Fmt.rate(row.up, unit: unit),
                  at: NSPoint(x: mid, y: rateY), font: rateFont, color: Palette.up)

        // ---- totals, peak, utilisation ------------------------------------
        var facts = ["total " + Fmt.bytes(Double(row.totalDown)) + " " + row.inLong.lowercased()
                     + " · " + Fmt.bytes(Double(row.totalUp)) + " " + row.outLong.lowercased()]
        if row.peak > 0 { facts.append("peak " + Fmt.rate(row.peak, unit: unit)) }
        if row.linkTrusted,
           let used = Reference.utilization(bytesPerSec: row.down + row.up, linkBits: row.linkBits) {
            facts.append(String(format: "%.0f%% of link", used * 100))
        }
        Text.draw(Text.clip(facts.joined(separator: "  ·  "), font: subFont, maxWidth: width),
                  at: NSPoint(x: left, y: card.minY + 40), font: subFont,
                  color: NSColor.secondaryLabelColor)

        // ---- who is doing it, and any advice -------------------------------
        var footer: [String] = row.actors.map {
            $0.display + " " + Fmt.rate($0.bytesPerSec, unit: unit)
        }
        if !row.hint.isEmpty { footer.append(row.hint) }
        if !footer.isEmpty {
            Text.drawWrapped(footer.joined(separator: "  ·  "),
                             in: NSRect(x: left, y: card.minY + 10, width: width, height: 28),
                             font: NSFont.systemFont(ofSize: 11),
                             color: NSColor.tertiaryLabelColor)
        }
    }
}
