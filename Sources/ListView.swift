import Cocoa

/// Draws the whole list itself rather than using NSTableView cells. With fixed-height rows and
/// no interaction beyond scrolling, one draw pass is far cheaper than a tree of subviews —
/// which matters on the low-power hardware this targets.
final class TrafficListView: NSView {
    static let rowHeight: CGFloat = 72

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
        let combined = row.down + row.up
        let dimmed = row.active ? 1.0 : 0.55

        // ---- left column: what this is -----------------------------------
        let title = Text.clip(row.title, font: titleFont, maxWidth: textLimit - 16)
        Text.draw(title,
                  at: NSPoint(x: 16, y: rect.minY + 8),
                  font: titleFont,
                  color: NSColor.labelColor.withAlphaComponent(CGFloat(dimmed)))

        var cursorX: CGFloat = 16
        let secondLineY = rect.minY + 28
        if !row.badge.isEmpty {
            cursorX += Text.drawBadge(row.badge, at: NSPoint(x: cursorX, y: secondLineY), font: badgeFont) + 6
        }
        Text.draw(Text.clip(row.subtitle, font: subtitleFont, maxWidth: max(0, textLimit - cursorX)),
                  at: NSPoint(x: cursorX, y: secondLineY + 1),
                  font: subtitleFont,
                  color: NSColor.secondaryLabelColor)

        // Third line: either why we cannot measure this, or what the rate is
        // comparable to. The comparison is the point of the feature - "6.2 MB/s"
        // means little on its own, "half of USB 2.0" means something.
        var context = row.note
        if context.isEmpty && combined > 0 {
            context = Reference.comparison(bytesPerSec: combined)
        }
        Text.draw(Text.clip(context, font: subtitleFont, maxWidth: textLimit),
                  at: NSPoint(x: 16, y: rect.minY + 48),
                  font: subtitleFont,
                  color: NSColor.tertiaryLabelColor)

        // ---- middle column: history, then link utilisation ---------------
        let chartRect = NSRect(x: chartLeft, y: rect.minY + 12, width: chartWidth, height: 30)
        if row.downHist.count > 1 || row.upHist.count > 1 {
            NSGraphicsContext.saveGraphicsState()
            let flip = NSAffineTransform()
            flip.translateX(by: 0, yBy: chartRect.maxY + chartRect.minY)
            flip.scaleX(by: 1, yBy: -1)
            flip.concat()
            Chart.draw(down: row.downHist, up: row.upHist, in: chartRect, lineWidth: 1.2)
            NSGraphicsContext.restoreGraphicsState()
        }

        // Only meaningful when the link rate is believable and the row has actually
        // carried traffic; an idle port showing "0% of link" is just noise.
        let credible = Reference.linkRateIsCredible(observedBytesPerSec: max(combined, row.peak),
                                                    linkBits: row.linkBits)
        let showUtilisation = credible && (combined > 0 || row.peak > 0)
        if showUtilisation,
           let used = Reference.utilization(bytesPerSec: combined, linkBits: row.linkBits) {
            let bar = NSRect(x: chartLeft, y: rect.minY + 48, width: chartWidth, height: 5)
            Palette.hairline.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 2.5, yRadius: 2.5).fill()

            let fraction = CGFloat(min(1.0, max(0.0, used)))
            // Once a transfer is near the ceiling the link is the limit, not the
            // device at either end. Colour says which regime you are in.
            let fill = used >= 0.85 ? NSColor.systemOrange
                     : (used >= 0.40 ? Palette.down : Palette.up)
            fill.setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY,
                                             width: max(2, bar.width * fraction),
                                             height: bar.height),
                         xRadius: 2.5, yRadius: 2.5).fill()

            // A tick at the session peak, so a link that briefly maxed out still
            // shows it after the transfer settles down.
            if let peakUsed = Reference.utilization(bytesPerSec: row.peak, linkBits: row.linkBits),
               peakUsed > used + 0.03 {
                let x = bar.minX + bar.width * CGFloat(min(1.0, peakUsed))
                NSColor.labelColor.withAlphaComponent(0.6).setFill()
                NSRect(x: min(bar.maxX - 2, max(bar.minX, x - 1)), y: bar.minY - 2,
                       width: 2, height: bar.height + 4).fill()
            }
        }

        // ---- right column: the numbers -----------------------------------
        Text.draw("\u{25BE} " + Fmt.rate(row.down, unit: unit),
                  at: NSPoint(x: 0, y: rect.minY + 8),
                  font: rateFont, color: Palette.down, alignRight: rightEdge)
        Text.draw("\u{25B4} " + Fmt.rate(row.up, unit: unit),
                  at: NSPoint(x: 0, y: rect.minY + 26),
                  font: rateFont, color: Palette.up, alignRight: rightEdge)
        Text.draw(Fmt.bytes(Double(row.totalDown)) + " / " + Fmt.bytes(Double(row.totalUp)),
                  at: NSPoint(x: 0, y: rect.minY + 45),
                  font: totalFont, color: NSColor.tertiaryLabelColor, alignRight: rightEdge)

        if showUtilisation,
           let used = Reference.utilization(bytesPerSec: combined, linkBits: row.linkBits) {
            Text.draw(String(format: "%.0f%% of link", used * 100),
                      at: NSPoint(x: 0, y: rect.minY + 57),
                      font: totalFont,
                      color: used >= 0.85 ? NSColor.systemOrange : NSColor.tertiaryLabelColor,
                      alignRight: rightEdge)
        } else if row.peak > 0 {
            Text.draw("peak " + Fmt.rate(row.peak, unit: unit),
                      at: NSPoint(x: 0, y: rect.minY + 57),
                      font: totalFont, color: NSColor.tertiaryLabelColor, alignRight: rightEdge)
        }
    }
}
