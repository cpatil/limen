import Cocoa

/// Draws the whole list itself rather than using NSTableView cells. With fixed-height rows and
/// no interaction beyond scrolling, one draw pass is far cheaper than a tree of subviews —
/// which matters on the low-power hardware this targets.
final class TrafficListView: NSView {
    static let rowHeight: CGFloat = 58

    var rows: [Row] = [] {
        didSet {
            invalidateHeight()
            needsDisplay = true
        }
    }
    var unit: RateUnit = .bytes {
        didSet { needsDisplay = true }
    }
    var emptyMessage = "No data"

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    private let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private let subtitleFont = NSFont.systemFont(ofSize: 11)
    private let badgeFont = NSFont.systemFont(ofSize: 10)
    private let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    private let totalFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    private func invalidateHeight() {
        let height = max(CGFloat(rows.count) * TrafficListView.rowHeight,
                         enclosingScrollView?.contentView.bounds.height ?? 0)
        if abs(frame.height - height) > 0.5 {
            setFrameSize(NSSize(width: frame.width, height: height))
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        invalidateHeight()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty else {
            let font = NSFont.systemFont(ofSize: 13)
            let size = NSAttributedString(string: emptyMessage, attributes: [.font: font]).size()
            Text.draw(emptyMessage,
                      at: NSPoint(x: (bounds.width - size.width) / 2, y: 40),
                      font: font,
                      color: NSColor.tertiaryLabelColor)
            return
        }

        for (index, row) in rows.enumerated() {
            let rect = NSRect(x: 0,
                              y: CGFloat(index) * TrafficListView.rowHeight,
                              width: bounds.width,
                              height: TrafficListView.rowHeight)
            if rect.intersects(dirtyRect) {
                draw(row: row, in: rect, index: index)
            }
        }
    }

    private func draw(row: Row, in rect: NSRect, index: Int) {
        if index % 2 == 1 {
            Palette.rowAlt.setFill()
            rect.fill()
        }

        Palette.hairline.setFill()
        NSRect(x: 12, y: rect.maxY - 1, width: rect.width - 24, height: 1).fill()

        let rightEdge = rect.maxX - 16
        let rateColumnWidth: CGFloat = 96
        let chartWidth: CGFloat = 130
        let chartRight = rightEdge - rateColumnWidth - 16
        let chartLeft = chartRight - chartWidth
        let textLimit = chartLeft - 12 - 16

        // Left column: title, then subtitle and speed badge on the second line.
        let dimmed = row.active ? 1.0 : 0.55
        let title = Text.clip(row.title, font: titleFont, maxWidth: textLimit - 16)
        Text.draw(title,
                  at: NSPoint(x: 16, y: rect.minY + 10),
                  font: titleFont,
                  color: NSColor.labelColor.withAlphaComponent(CGFloat(dimmed)))

        var cursorX: CGFloat = 16
        let secondLineY = rect.minY + 30
        if !row.badge.isEmpty {
            cursorX += Text.drawBadge(row.badge, at: NSPoint(x: cursorX, y: secondLineY), font: badgeFont) + 6
        }
        let subtitleLimit = max(0, textLimit - cursorX)
        let subtitle = Text.clip(row.subtitle, font: subtitleFont, maxWidth: subtitleLimit)
        Text.draw(subtitle,
                  at: NSPoint(x: cursorX, y: secondLineY + 1),
                  font: subtitleFont,
                  color: NSColor.secondaryLabelColor)

        if !row.note.isEmpty {
            let noteY = rect.minY + 10
            Text.draw(row.note,
                      at: NSPoint(x: 0, y: noteY),
                      font: subtitleFont,
                      color: NSColor.tertiaryLabelColor,
                      alignRight: chartRight)
        }

        // Middle column: per-row sparkline. Flip into the chart's bottom-up coordinate space.
        let chartRect = NSRect(x: chartLeft, y: rect.minY + 14, width: chartWidth, height: 30)
        if row.downHist.count > 1 || row.upHist.count > 1 {
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: 0, yBy: chartRect.maxY + chartRect.minY)
            transform.scaleX(by: 1, yBy: -1)
            transform.concat()
            Chart.draw(down: row.downHist, up: row.upHist, in: chartRect, lineWidth: 1.2)
            NSGraphicsContext.restoreGraphicsState()
        }

        // Right column: current rates over cumulative totals.
        Text.draw("\u{25BE} " + Fmt.rate(row.down, unit: unit),
                  at: NSPoint(x: 0, y: rect.minY + 9),
                  font: rateFont,
                  color: Palette.down,
                  alignRight: rightEdge)
        Text.draw("\u{25B4} " + Fmt.rate(row.up, unit: unit),
                  at: NSPoint(x: 0, y: rect.minY + 27),
                  font: rateFont,
                  color: Palette.up,
                  alignRight: rightEdge)
        Text.draw(Fmt.bytes(Double(row.totalDown)) + " / " + Fmt.bytes(Double(row.totalUp)),
                  at: NSPoint(x: 0, y: rect.minY + 44),
                  font: totalFont,
                  color: NSColor.tertiaryLabelColor,
                  alignRight: rightEdge)
    }
}
