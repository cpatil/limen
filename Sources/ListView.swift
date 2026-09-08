import Cocoa

/// Draws the whole list itself rather than using NSTableView cells. With fixed-height rows and
/// no interaction beyond scrolling, one draw pass is far cheaper than a tree of subviews —
/// which matters on the low-power hardware this targets.
final class TrafficListView: NSView, NSViewToolTipOwner {
    static let rowHeight: CGFloat = 84

    /// Reports what the pointer is over, so the window can magnify it.
    var onHover: ((Row?, MagnifierView.Zone, String, NSPoint) -> Void)?

    private var tooltips: [NSView.ToolTipTag: String] = [:]
    private var tracking: NSTrackingArea?

    var rows: [Row] = [] {
        didSet {
            invalidateHeight()
            rebuildTooltips()
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
        rebuildTooltips()
    }

    // ---- hovering -------------------------------------------------------

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = tracking { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  // activeAlways: this is a window you glance at, so
                                  // hovering should enlarge without having to click
                                  // into it first.
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    /// Which part of a row a point falls in. The geometry has to match draw(row:).
    private func hit(_ point: NSPoint) -> (Row, MagnifierView.Zone)? {
        let index = Int(point.y / TrafficListView.rowHeight)
        guard index >= 0, index < rows.count else { return nil }
        let row = rows[index]
        let rightEdge = bounds.maxX - 16
        let rateColumnWidth: CGFloat = 92
        let chartWidth = min(130, max(54, bounds.width * 0.22))
        let chartRight = rightEdge - rateColumnWidth - 16
        if point.x >= chartRight { return (row, .rate) }
        if point.x >= chartRight - chartWidth { return (row, .chart) }
        return (row, .info)
    }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if let (row, zone) = hit(local) {
            onHover?(row, zone, details(for: row), convert(local, to: nil))
        } else {
            onHover?(nil, .rate, "", .zero)
        }
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil, .rate, "", .zero)
    }

    // ---- tooltips -------------------------------------------------------

    /// Rows clip their text to fit, so the full value is offered on hover instead of
    /// being lost to an ellipsis.
    /// Everything a row knows, unclipped. Shared by the tooltip, the magnified
    /// panel and the copy command so the three never disagree.
    func details(for row: Row) -> String {
        var parts = [row.title]
        if !row.badge.isEmpty { parts.append(row.badge) }
        if row.linkTrusted, row.linkBits > 0 {
            parts.append(Fmt.dualSpeed(bitsPerSec: row.linkBits, unit: unit))
        }
        if !row.subtitle.isEmpty { parts.append(row.subtitle) }
        if !row.appleName.isEmpty { parts.append("Apple: " + row.appleName) }
        if !row.mountRoots.isEmpty { parts.append("Mounted: " + row.mountRoots.joined(separator: ", ")) }
        parts.append("Down " + Fmt.rate(row.down, unit: unit) + " · up " + Fmt.rate(row.up, unit: unit))
        parts.append("Total " + Fmt.bytes(Double(row.totalDown)) + " in · "
                     + Fmt.bytes(Double(row.totalUp)) + " out")
        if row.peak > 0 { parts.append("Peak " + Fmt.rate(row.peak, unit: unit)) }
        for actor in row.actors {
            parts.append(actor.display + " " + Fmt.rate(actor.bytesPerSec, unit: unit))
        }
        if !row.hint.isEmpty { parts.append(row.hint) }
        return parts.joined(separator: "\n")
    }

    /// Tooltips cannot be selected, so copying gets its own affordance.
    override func menu(for event: NSEvent) -> NSMenu? {
        let local = convert(event.locationInWindow, from: nil)
        let index = Int(local.y / TrafficListView.rowHeight)
        guard index >= 0, index < rows.count else { return nil }
        let row = rows[index]

        let menu = NSMenu()
        let all = NSMenuItem(title: "Copy Details", action: #selector(copyText(_:)), keyEquivalent: "")
        all.target = self
        all.representedObject = details(for: row)
        menu.addItem(all)

        if !row.subtitle.isEmpty {
            let sub = NSMenuItem(title: "Copy “\(Text.clip(row.subtitle, font: subtitleFont, maxWidth: 260))”",
                                 action: #selector(copyText(_:)), keyEquivalent: "")
            sub.target = self
            sub.representedObject = row.subtitle
            menu.addItem(sub)
        }
        let name = NSMenuItem(title: "Copy “\(row.title)”", action: #selector(copyText(_:)), keyEquivalent: "")
        name.target = self
        name.representedObject = row.title
        menu.addItem(name)
        return menu
    }

    @objc private func copyText(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func rebuildTooltips() {
        removeAllToolTips()
        tooltips.removeAll()
        guard bounds.width > 0 else { return }
        let rightEdge = bounds.maxX - 16
        let chartWidth = min(130, max(54, bounds.width * 0.22))
        let textWidth = max(40, rightEdge - 92 - 16 - chartWidth - 28)

        for (index, row) in rows.enumerated() {
            let y = CGFloat(index) * TrafficListView.rowHeight
            let rect = NSRect(x: 12, y: y, width: textWidth, height: TrafficListView.rowHeight)
            let tag = addToolTip(rect, owner: self, userData: nil)
            tooltips[tag] = details(for: row)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        tooltips[tag] ?? ""
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
        // The pane is half the window now, so the middle column gives way first.
        let rateColumnWidth: CGFloat = 92
        let chartWidth: CGFloat = min(130, max(54, rect.width * 0.22))
        let chartRight = rightEdge - rateColumnWidth - 16
        let chartLeft = chartRight - chartWidth
        let textLimit = chartLeft - 12 - 16
        let combined = row.down + row.up
        let dimmed = row.active ? 1.0 : 0.55

        // ---- left column: what this is -----------------------------------
        let title = Text.clip(row.title, font: titleFont, maxWidth: textLimit - 16)
        Text.draw(title,
                  at: NSPoint(x: 16, y: rect.minY + 16),
                  font: titleFont,
                  color: NSColor.labelColor.withAlphaComponent(CGFloat(dimmed)))

        var cursorX: CGFloat = 16
        let secondLineY = rect.minY + 36
        // Standard name plus its speed in the selected unit, with the other in
        // brackets - the eight-times relationship is the confusing part.
        var badgeText = row.badge
        if row.linkTrusted, row.linkBits > 0 {
            let speed = Fmt.dualSpeed(bitsPerSec: row.linkBits, unit: unit)
            badgeText = badgeText.isEmpty ? speed : badgeText + " · " + speed
        }
        if !badgeText.isEmpty {
            let badge = Text.clip(badgeText, font: badgeFont, maxWidth: textLimit - 24)
            cursorX += Text.drawBadge(badge, at: NSPoint(x: cursorX, y: secondLineY), font: badgeFont) + 6
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
            context = Reference.comparison(bytesPerSec: combined,
                                           families: row.compareFamilies.isEmpty ? nil : row.compareFamilies)
        }
        Text.draw(Text.clip(context, font: subtitleFont, maxWidth: textLimit),
                  at: NSPoint(x: 16, y: rect.minY + 56),
                  font: subtitleFont,
                  color: NSColor.tertiaryLabelColor)

        // ---- middle column: history, then link utilisation ---------------
        let chartRect = NSRect(x: chartLeft, y: rect.minY + 20, width: chartWidth, height: 30)
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
        let credible = row.linkTrusted
            && Reference.linkRateIsCredible(observedBytesPerSec: max(combined, row.peak),
                                            linkBits: row.linkBits)
        let showUtilisation = credible && (combined > 0 || row.peak > 0)
        if showUtilisation,
           let used = Reference.utilization(bytesPerSec: combined, linkBits: row.linkBits) {
            let bar = NSRect(x: chartLeft, y: rect.minY + 56, width: chartWidth, height: 5)
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
                  at: NSPoint(x: 0, y: rect.minY + 16),
                  font: rateFont, color: Palette.down, alignRight: rightEdge)
        Text.draw("\u{25B4} " + Fmt.rate(row.up, unit: unit),
                  at: NSPoint(x: 0, y: rect.minY + 34),
                  font: rateFont, color: Palette.up, alignRight: rightEdge)
        Text.draw(Fmt.bytes(Double(row.totalDown)) + " / " + Fmt.bytes(Double(row.totalUp)),
                  at: NSPoint(x: 0, y: rect.minY + 53),
                  font: totalFont, color: NSColor.tertiaryLabelColor, alignRight: rightEdge)

        if showUtilisation,
           let used = Reference.utilization(bytesPerSec: combined, linkBits: row.linkBits) {
            Text.draw(String(format: "%.0f%% of link", used * 100),
                      at: NSPoint(x: 0, y: rect.minY + 65),
                      font: totalFont,
                      color: used >= 0.85 ? NSColor.systemOrange : NSColor.tertiaryLabelColor,
                      alignRight: rightEdge)
        } else if row.peak > 0 {
            Text.draw("peak " + Fmt.rate(row.peak, unit: unit),
                      at: NSPoint(x: 0, y: rect.minY + 65),
                      font: totalFont, color: NSColor.tertiaryLabelColor, alignRight: rightEdge)
        }

        // Fourth line: the processes the kernel says are responsible, then any
        // suggestion. Kept small and grey so it informs without shouting.
        var footer = ""
        if !row.actors.isEmpty {
            footer = row.actors.map { "\($0.display) \(Fmt.rate($0.bytesPerSec, unit: unit))" }
                .joined(separator: "   ")
        }
        if !row.appleName.isEmpty {
            let apple = "Apple: " + row.appleName
            footer += footer.isEmpty ? apple : "   ·   " + apple
        }
        if !row.hint.isEmpty {
            footer += footer.isEmpty ? row.hint : "   ·   " + row.hint
        }
        if !footer.isEmpty {
            // Stop short of the rate column, which shares this baseline.
            Text.draw(Text.clip(footer, font: totalFont, maxWidth: max(0, chartRight - 24)),
                      at: NSPoint(x: 16, y: rect.minY + 68),
                      font: totalFont,
                      color: NSColor.tertiaryLabelColor)
        }
    }
}
