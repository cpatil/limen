import Cocoa

/// An enlarged view of whatever the pointer is over.
///
/// The rows pack a lot into small type. Rather than making every row bigger, the
/// one thing being looked at is shown large: hovering a rate enlarges the numbers,
/// hovering a chart redraws it several times the size. It follows the pointer and
/// never takes focus or swallows clicks.
final class MagnifierView: NSView {
    enum Zone {
        case rate, chart
    }

    var row: Row?
    var zone: Zone = .rate
    var unit: RateUnit = .bytes

    static let size = NSSize(width: 340, height: 168)

    override var isFlipped: Bool { false }
    /// Never intercept the pointer - it sits above the list purely as decoration.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let row = row else { return }

        let card = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
        (NSColor.windowBackgroundColor.withAlphaComponent(0.98)).setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        path.lineWidth = 1
        path.stroke()

        let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        Text.draw(Text.clip(row.title, font: titleFont, maxWidth: card.width - 32),
                  at: NSPoint(x: card.minX + 16, y: card.maxY - 30),
                  font: titleFont, color: NSColor.labelColor)

        switch zone {
        case .rate:
            let big = NSFont.monospacedDigitSystemFont(ofSize: 30, weight: .medium)
            Text.draw("\u{25BE} " + Fmt.rate(row.down, unit: unit),
                      at: NSPoint(x: card.minX + 16, y: card.maxY - 78),
                      font: big, color: Palette.down)
            Text.draw("\u{25B4} " + Fmt.rate(row.up, unit: unit),
                      at: NSPoint(x: card.minX + 16, y: card.maxY - 122),
                      font: big, color: Palette.up)
            let small = NSFont.systemFont(ofSize: 11)
            Text.draw("total " + Fmt.bytes(Double(row.totalDown)) + " in · "
                        + Fmt.bytes(Double(row.totalUp)) + " out",
                      at: NSPoint(x: card.minX + 16, y: card.minY + 12),
                      font: small, color: NSColor.tertiaryLabelColor)

        case .chart:
            let chart = NSRect(x: card.minX + 16, y: card.minY + 34,
                               width: card.width - 32, height: card.height - 76)
            Chart.draw(down: row.downHist, up: row.upHist, in: chart, lineWidth: 2)
            let small = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            Text.draw("\u{25BE} " + Fmt.rate(row.down, unit: unit),
                      at: NSPoint(x: card.minX + 16, y: card.minY + 12),
                      font: small, color: Palette.down)
            Text.draw("\u{25B4} " + Fmt.rate(row.up, unit: unit),
                      at: NSPoint(x: card.minX + 150, y: card.minY + 12),
                      font: small, color: Palette.up)
        }
    }
}
