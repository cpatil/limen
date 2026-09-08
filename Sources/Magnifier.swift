import Cocoa

/// An enlarged view of whatever the pointer is over.
///
/// The rows pack a lot into small type. Rather than making every row bigger, the
/// one thing being looked at is shown large: hovering a rate enlarges the numbers,
/// hovering a chart redraws it several times the size. It follows the pointer and
/// never takes focus or swallows clicks.
final class MagnifierView: NSView {
    enum Zone {
        case rate, chart, info
    }

    var row: Row?
    var zone: Zone = .rate
    var unit: RateUnit = .bytes
    /// Full, unclipped detail text for the hovered row.
    var details: String = ""
    /// Seconds per sample, so the chart can say how much time it covers.
    var sampleInterval: TimeInterval = 1

    static let size = NSSize(width: 360, height: 186)

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

        let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        Text.draw(Text.clip(row.title, font: titleFont, maxWidth: card.width - 32),
                  at: NSPoint(x: card.minX + 16, y: card.maxY - 30),
                  font: titleFont, color: NSColor.labelColor)

        switch zone {
        case .rate:
            let big = NSFont.monospacedDigitSystemFont(ofSize: 30, weight: .medium)
            Text.draw(row.inLong.padding(toLength: 5, withPad: " ", startingAt: 0) + " " + Fmt.rate(row.down, unit: unit),
                      at: NSPoint(x: card.minX + 16, y: card.maxY - 78),
                      font: big, color: Palette.down)
            Text.draw(row.outLong.padding(toLength: 5, withPad: " ", startingAt: 0) + " " + Fmt.rate(row.up, unit: unit),
                      at: NSPoint(x: card.minX + 16, y: card.maxY - 122),
                      font: big, color: Palette.up)
            let small = NSFont.systemFont(ofSize: 11)
            Text.draw("total " + Fmt.bytes(Double(row.totalDown)) + " " + row.inLong.lowercased() + " · "
                        + Fmt.bytes(Double(row.totalUp)) + " " + row.outLong.lowercased(),
                      at: NSPoint(x: card.minX + 16, y: card.minY + 12),
                      font: small, color: NSColor.tertiaryLabelColor)

        case .info:
            // The rows clip this text to fit; here it is in full and large enough to
            // read, which is the whole point of the panel.
            // details() leads with the name, which the panel already shows as a
            // heading; drop it rather than printing it twice.
            var body = details
            if let firstBreak = body.range(of: "\n"), body.hasPrefix(row.title) {
                body = String(body[firstBreak.upperBound...])
            }
            Text.drawWrapped(body,
                             in: NSRect(x: card.minX + 16, y: card.minY + 30,
                                        width: card.width - 32, height: card.height - 62),
                             font: NSFont.systemFont(ofSize: 13),
                             color: NSColor.labelColor)
            Text.draw("right-click the row to copy",
                      at: NSPoint(x: card.minX + 16, y: card.minY + 10),
                      font: NSFont.systemFont(ofSize: 10),
                      color: NSColor.tertiaryLabelColor)

        case .chart:
            let chart = NSRect(x: card.minX + 16, y: card.minY + 34,
                               width: card.width - 32, height: card.height - 76)
            Chart.draw(down: row.downHist, up: row.upHist, in: chart, lineWidth: 2)

            // Label the scale. Without it the shape conveys nothing about magnitude:
            // an idle line and a saturated one look identical.
            let scale = Chart.peak(down: row.downHist, up: row.upHist)
            let tick = NSFont.systemFont(ofSize: 10)
            NSColor.tertiaryLabelColor.withAlphaComponent(0.45).setFill()
            NSRect(x: chart.minX, y: chart.maxY, width: chart.width, height: 1).fill()
            Text.draw(Fmt.rate(scale, unit: unit) + " full scale",
                      at: NSPoint(x: 0, y: chart.maxY + 3), font: tick,
                      color: NSColor.secondaryLabelColor, alignRight: chart.maxX)
            let span = Double(Monitor.historyLength) * sampleInterval
            Text.draw(span >= 120 ? String(format: "last %.0f min", span / 60)
                                  : String(format: "last %.0f s", span),
                      at: NSPoint(x: chart.minX, y: chart.maxY + 3), font: tick,
                      color: NSColor.tertiaryLabelColor)
            let small = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            Text.draw(row.inShort + " " + Fmt.rate(row.down, unit: unit),
                      at: NSPoint(x: card.minX + 16, y: card.minY + 12),
                      font: small, color: Palette.down)
            Text.draw(row.outShort + " " + Fmt.rate(row.up, unit: unit),
                      at: NSPoint(x: card.minX + 150, y: card.minY + 12),
                      font: small, color: Palette.up)
        }
    }
}
