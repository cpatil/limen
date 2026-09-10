import Cocoa

/// How much each row spells out.
///
/// Every one of these details was asked for, so none of them are gone - but all of
/// them at once, on every row, is a wall of grey text. Calm keeps what identifies the
/// device and what it is doing, and leaves the rest to the hover card, which already
/// shows the lot and is easier to read than a 10pt line.
enum RowDetail: Int {
    case calm = 0
    case detailed = 1

    static var current: RowDetail {
        RowDetail(rawValue: UserDefaults.standard.integer(forKey: "RowDetail")) ?? .calm
    }

    var showsEverything: Bool { self == .detailed }
}

/// Draws the whole list itself rather than using NSTableView cells. With fixed-height rows and
/// no interaction beyond scrolling, one draw pass is far cheaper than a tree of subviews —
/// which matters on the low-power hardware this targets.
final class TrafficListView: NSView, NSViewToolTipOwner {
    static let rowHeight: CGFloat = 84

    /// Reports what the pointer is over, so the window can magnify it.
    var onHover: ((Row?, MagnifierView.Zone, String, NSPoint) -> Void)?
    /// Emitted when rows have been dragged into a new arrangement, with the row ids in
    /// their new order. The window persists it and switches this list to custom order.
    var onReorder: (([String]) -> Void)?

    /// Index of the row being dragged, while a drag is in progress.
    private var draggingIndex: Int?
    private var dragStartedAt: NSPoint = .zero
    /// A press only becomes a drag once it has moved far enough to mean it, so a
    /// click or a right-click never quietly rearranges the list.
    private var dragArmed = false

    private var tooltips: [NSView.ToolTipTag: String] = [:]
    private var tracking: NSTrackingArea?
    /// Row under the pointer, highlighted so it is easy to keep your place.
    private var hoveredIndex: Int?

    var rows: [Row] = [] {
        didSet {
            invalidateHeight()
            rebuildTooltips()
            refreshAccessibilityRows()
            needsDisplay = true
        }
    }
    var unit: RateUnit = .bytes {
        didSet { needsDisplay = true }
    }
    var emptyMessage = "No data"

    override var isFlipped: Bool { true }

    /// Act on the first click even when Limen is not the active app. This is a window
    /// you glance at while working in something else; spending a click just to focus
    /// it before you can fold a group or drag a row is a click too many.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    private let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private let subtitleFont = NSFont.systemFont(ofSize: 11)
    private let badgeFont = NSFont.systemFont(ofSize: 10)
    /// Semibold: the card is the subject of a storage row, so it should read first.
    private let cardFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
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
        guard draggingIndex == nil else { return }
        let local = convert(event.locationInWindow, from: nil)
        let index = Int(local.y / TrafficListView.rowHeight)
        let newHover = (index >= 0 && index < rows.count) ? index : nil
        if newHover != hoveredIndex {
            hoveredIndex = newHover
            needsDisplay = true
        }
        if let (row, zone) = hit(local) {
            onHover?(row, zone, identity(for: row), convert(local, to: nil))
        } else {
            onHover?(nil, .rate, "", .zero)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredIndex != nil {
            hoveredIndex = nil
            needsDisplay = true
        }
        onHover?(nil, .rate, "", .zero)
    }

    // ---- accessibility ---------------------------------------------------

    /// The rows are drawn, not built from subviews, so they do not exist as far as
    /// VoiceOver is concerned unless they are published explicitly. Apple's guidance
    /// for one view that draws many logical objects is to vend accessibility elements
    /// for them; without this the app is a window containing four controls and no data.
    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .table }

    override func accessibilityLabel() -> String? { emptyMessage }

    /// Built with the convenience initialiser, which sets the frame in the parent's
    /// space for us. Vended as both children and rows: a table role is asked for its
    /// rows, and without them the list appears empty to VoiceOver.
    private func accessibilityRowElements() -> [NSAccessibilityElement] {
        guard let window = window else { return [] }
        return rows.enumerated().compactMap { index, row -> NSAccessibilityElement? in
            let frame = NSRect(x: 0, y: CGFloat(index) * TrafficListView.rowHeight,
                               width: max(1, bounds.width), height: TrafficListView.rowHeight)
            let element = NSAccessibilityElement.element(
                withRole: .row,
                frame: window.convertToScreen(convert(frame, to: nil)),
                label: accessibilityName(for: row),
                parent: self) as? NSAccessibilityElement
            element?.setAccessibilityValue(accessibilitySummary(for: row))
            return element
        }
    }

    /// Cached. Rebuilding these on every query hands the accessibility system a fresh
    /// object each time it asks a follow-up question, and the answers come back empty.
    private var axRows: [NSAccessibilityElement] = []

    private func refreshAccessibilityRows() {
        axRows = accessibilityRowElements()
    }

    override func accessibilityChildren() -> [Any]? {
        if axRows.count != rows.count { refreshAccessibilityRows() }
        return axRows
    }

    override func accessibilityRows() -> [Any]? { accessibilityChildren() }

    private func accessibilityName(for row: Row) -> String {
        var parts = [row.title]
        if !row.mediumClass.isEmpty { parts.append(row.mediumClass) }
        if !row.volumes.isEmpty { parts.append(row.volumes.joined(separator: ", ")) }
        if !row.badge.isEmpty { parts.append(row.badge) }
        return parts.joined(separator: ", ")
    }

    /// Spoken as a sentence rather than a row of numbers, and it names the direction
    /// so "read" and "in" are not both just "the first figure".
    private func accessibilitySummary(for row: Row) -> String {
        var parts = ["\(row.inLong) \(Fmt.rate(row.down, unit: unit))",
                     "\(row.outLong) \(Fmt.rate(row.up, unit: unit))"]
        if let gauge = Reference.gauge(down: row.down, up: row.up,
                                       peakDirectional: row.peakDirectional, peak: row.peak,
                                       linkBits: row.linkBits, linkTrusted: row.linkTrusted) {
            parts.append(gauge.label)
        }
        if !row.hint.isEmpty { parts.append(row.hint) }
        if !row.note.isEmpty { parts.append(row.note) }
        return parts.joined(separator: ", ")
    }

    // ---- dragging rows into an order ------------------------------------

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let index = Int(local.y / TrafficListView.rowHeight)
        guard index >= 0, index < rows.count else { return }
        draggingIndex = index
        dragStartedAt = local
        dragArmed = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let from = draggingIndex else { return }
        let local = convert(event.locationInWindow, from: nil)
        if !dragArmed {
            guard abs(local.y - dragStartedAt.y) > 6 else { return }
            dragArmed = true
            NSCursor.closedHand.push()
            // The hover card would otherwise sit over the rows being rearranged.
            onHover?(nil, .rate, "", .zero)
        }
        let to = min(max(0, Int(local.y / TrafficListView.rowHeight)), rows.count - 1)
        guard to != from else { return }
        // Rearranged as the pointer crosses each boundary, rather than only on drop -
        // you can see where the row is going while you are still deciding.
        let moved = rows.remove(at: from)
        rows.insert(moved, at: to)
        draggingIndex = to
        hoveredIndex = to
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { draggingIndex = nil; dragArmed = false }
        guard dragArmed else { return }
        NSCursor.pop()
        onReorder?(rows.map { $0.id })
    }

    // ---- tooltips -------------------------------------------------------

    /// Rows clip their text to fit, so the full value is offered on hover instead of
    /// being lost to an ellipsis.
    /// Just what the thing is: its name, who made it, its identifier and the volumes
    /// it presents. This is what the row clips and what hovering should reveal - not
    /// the live measurements, which are already legible beside it.
    func identity(for row: Row) -> String {
        var parts = [row.title]
        if !row.vendor.isEmpty, row.vendor != row.title { parts.append(row.vendor) }
        if !row.deviceID.isEmpty { parts.append(row.deviceID) }
        if !row.volumes.isEmpty { parts.append(row.volumes.joined(separator: ", ")) }
        if parts.count == 1, !row.subtitle.isEmpty { parts.append(row.subtitle) }
        let card = Row.cardLabel(class: row.mediumClass, volumes: row.volumes)
        if !card.isEmpty { parts.append(card) }
        if !row.badge.isEmpty { parts.append(row.badge) }
        if row.linkTrusted, row.linkBits > 0 {
            parts.append(Fmt.dualSpeed(bitsPerSec: row.linkBits, unit: unit))
        }
        if !row.appleName.isEmpty { parts.append("Apple: " + row.appleName) }
        return parts.joined(separator: "\n")
    }

    /// Tooltips cannot be selected, so copying gets its own affordance. Only the
    /// facts that identify the thing - live rates change the moment they are pasted.
    override func menu(for event: NSEvent) -> NSMenu? {
        let local = convert(event.locationInWindow, from: nil)
        let index = Int(local.y / TrafficListView.rowHeight)
        guard index >= 0, index < rows.count else { return nil }

        let row = rows[index]
        let menu = NSMenu()
        let item = NSMenuItem(title: "Copy", action: #selector(copyText(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = identity(for: row)
        menu.addItem(item)

        // Offered on the row itself, because this is a fact about this volume: macOS
        // is writing an index onto a card you are only reading from. A LaunchAgent
        // cannot do this - touching a removable volume needs consent macOS only grants
        // to an app the user runs - so it belongs here, where the prompt makes sense.
        if row.removable, !row.mountRoots.isEmpty {
            let already = row.mountRoots.allSatisfy {
                FileManager.default.fileExists(atPath: $0 + "/.metadata_never_index")
            }
            let name = row.volumes.first ?? "this card"
            let stop = NSMenuItem(title: already ? "Spotlight Indexing Already Off for “\(name)”"
                                                 : "Stop Spotlight Indexing “\(name)”",
                                  action: #selector(stopIndexing(_:)), keyEquivalent: "")
            stop.target = self
            stop.representedObject = row.mountRoots as NSArray
            stop.isEnabled = !already
            menu.addItem(NSMenuItem.separator())
            menu.addItem(stop)
        }
        return menu
    }

    /// Writes `.metadata_never_index` at the volume root - the durable way to stop
    /// Spotlight indexing a card. It needs no password, lives on the volume so it
    /// travels to any Mac, and is undone by deleting the file.
    @objc private func stopIndexing(_ sender: NSMenuItem) {
        guard let roots = sender.representedObject as? [String] else { return }
        var failed: [String] = []
        for root in roots where !FileManager.default.fileExists(atPath: root + "/.metadata_never_index") {
            let path = root + "/.metadata_never_index"
            if !FileManager.default.createFile(atPath: path, contents: Data()) {
                failed.append((root as NSString).lastPathComponent)
            }
        }
        let alert = NSAlert()
        if failed.isEmpty {
            alert.messageText = "Spotlight indexing stopped"
            alert.informativeText = "A .metadata_never_index file now sits at the volume root, "
                + "so no Mac will index it. Delete that file to undo it.\n\n"
                + "Indexing already in progress finishes; it will not start again."
        } else {
            alert.messageText = "Could not write to \(failed.joined(separator: ", "))"
            alert.informativeText = "macOS withholds access to removable volumes until it is "
                + "granted. Allow Limen under System Settings ▸ Privacy & Security ▸ "
                + "Files and Folders ▸ Removable Volumes, then try again."
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
            tooltips[tag] = identity(for: row)
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

    /// Width of the margin reserved for the drag handle.
    static let gripWidth: CGFloat = 14

    private func drawGrip(in rect: NSRect, emphasised: Bool) {
        let dot: CGFloat = 2.4
        let columns: CGFloat = 2, rowsOfDots: CGFloat = 3
        let spacing: CGFloat = 4
        let blockWidth = (columns - 1) * spacing + dot
        let blockHeight = (rowsOfDots - 1) * spacing + dot
        let originX = (TrafficListView.gripWidth - blockWidth) / 2
        let originY = rect.midY - blockHeight / 2

        (emphasised ? NSColor.secondaryLabelColor
                    : NSColor.tertiaryLabelColor.withAlphaComponent(0.55)).setFill()
        for column in 0..<Int(columns) {
            for row in 0..<Int(rowsOfDots) {
                let box = NSRect(x: originX + CGFloat(column) * spacing,
                                 y: originY + CGFloat(row) * spacing,
                                 width: dot, height: dot)
                NSBezierPath(ovalIn: box).fill()
            }
        }
    }

    /// A hand over the handle, so the affordance is felt as well as seen. The whole
    /// row still drags - restricting it to the grip would make reordering harder, and
    /// the point of the grip is to advertise it, not to gate it.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard !rows.isEmpty else { return }
        addCursorRect(NSRect(x: 0, y: 0, width: TrafficListView.gripWidth, height: bounds.height),
                      cursor: .openHand)
    }

    private func draw(row: Row, in rect: NSRect, index: Int) {
        if index % 2 == 1 {
            Palette.rowAlt.setFill()
            rect.fill()
        }
        if index == hoveredIndex {
            Palette.hover.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 2), xRadius: 7, yRadius: 7).fill()
        }
        if dragArmed, index == draggingIndex {
            // Outlined while it is being carried, so it is obvious which row moves.
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 2),
                                    xRadius: 7, yRadius: 7)
            NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 2
            path.stroke()
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
        let verbose = RowDetail.current.showsEverything

        // ---- the drag handle ---------------------------------------------
        // Rows have always been draggable, but nothing said so, so nobody tried it.
        // The grip lives in the margin the icon already left empty, which is why
        // adding it moved nothing else on the row.
        drawGrip(in: rect, emphasised: index == hoveredIndex || index == draggingIndex)

        // ---- left column: what this is -----------------------------------
        let iconBox = NSRect(x: 16, y: rect.minY + 18, width: 18, height: 18)
        Icons.draw(row.icon, in: iconBox,
                   color: NSColor.secondaryLabelColor.withAlphaComponent(row.active ? 0.9 : 0.45))

        let textLeft: CGFloat = 42
        let title = Text.clip(row.title, font: titleFont, maxWidth: textLimit - textLeft)
        Text.draw(title,
                  at: NSPoint(x: textLeft, y: rect.minY + 16),
                  font: titleFont,
                  color: NSColor.labelColor.withAlphaComponent(CGFloat(dimmed)))

        var cursorX: CGFloat = textLeft
        let secondLineY = rect.minY + 36
        // Standard name plus its speed in the selected unit, with the other in
        // brackets - the eight-times relationship is the confusing part.
        // The selected unit goes in the pill; the other follows in lighter text, so
        // switching units visibly changes the row instead of only reordering it.
        var badgeText = row.badge
        var alternate = ""
        if row.linkTrusted, row.linkBits > 0 {
            let primary = Fmt.speed(bitsPerSec: row.linkBits, unit: unit)
            badgeText = badgeText.isEmpty ? primary : badgeText + " · " + primary
            // The same speed restated in the other unit: useful once, noise on every
            // row forever. Hovering still shows both.
            if verbose { alternate = "= " + Fmt.alternateSpeed(bitsPerSec: row.linkBits, unit: unit) }
        }
        // The card leads. When you look at a reader the question is what is in it, not
        // what it is plugged into - so its type, capacity and name come first, in their
        // own colour and at full strength.
        let card = Row.cardLabel(class: row.mediumClass, volumes: row.volumes)
        if !card.isEmpty {
            cursorX += Text.drawBadge(Text.clip(card, font: cardFont, maxWidth: textLimit - 24),
                                      at: NSPoint(x: cursorX, y: secondLineY),
                                      font: cardFont,
                                      fill: Palette.cardBadge,
                                      textColor: NSColor.labelColor) + 6
        }
        if !badgeText.isEmpty {
            let badge = Text.clip(badgeText, font: badgeFont, maxWidth: textLimit - 24)
            cursorX += Text.drawBadge(badge, at: NSPoint(x: cursorX, y: secondLineY),
                                      font: badgeFont, prominent: true) + 6
        }
        if !alternate.isEmpty, cursorX + Text.width(alternate, font: badgeFont) < textLimit {
            Text.draw(alternate, at: NSPoint(x: cursorX, y: secondLineY + 1),
                      font: badgeFont, color: NSColor.tertiaryLabelColor)
            cursorX += Text.width(alternate, font: badgeFont) + 8
        }
        // Once the badges have taken the line, a vendor clipped to "G..." says nothing
        // and looks broken. Drop it rather than stub it - the hover card and the
        // tooltip both carry it in full.
        let subtitleRoom = textLimit - cursorX
        if subtitleRoom >= 60 {
            Text.draw(Text.clip(row.subtitle, font: subtitleFont, maxWidth: subtitleRoom),
                      at: NSPoint(x: cursorX, y: secondLineY + 1),
                      font: subtitleFont,
                      color: NSColor.secondaryLabelColor)
        }

        // Third line: either why we cannot measure this, or what the rate is
        // comparable to. The comparison is the point of the feature - "6.2 MB/s"
        // means little on its own, "half of USB 2.0" means something.
        var context = row.note
        if context.isEmpty && combined > 0 {
            if row.wireless && !row.linkTrusted {
                // Throughput cannot identify a Wi-Fi generation, and the reported link
                // rate is not usable either, so this says what was seen rather than
                // naming a standard it cannot establish.
                context = row.peak > 0 ? "best this session " + Fmt.rate(row.peak, unit: unit) : ""
            } else {
                context = Reference.comparison(bytesPerSec: combined,
                                               families: row.compareFamilies.isEmpty ? nil : row.compareFamilies,
                                               roles: row.compareRoles.isEmpty ? nil : row.compareRoles,
                                               internalMedium: row.internalMedium)
            }
        }
        Text.draw(Text.clip(context, font: subtitleFont, maxWidth: textLimit - textLeft),
                  at: NSPoint(x: textLeft, y: rect.minY + 56),
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

        // Every row that has ever moved data gets a bar. Where the link ceiling is
        // believable the bar measures against it; where it is not - Wi-Fi, whose
        // reported rate is fiction, and the internal drive, which has no cable - it
        // measures against the fastest that device has actually gone.
        let gauge = Reference.gauge(down: row.down, up: row.up,
                                    peakDirectional: row.peakDirectional, peak: row.peak,
                                    linkBits: row.linkBits, linkTrusted: row.linkTrusted)
        if let gauge = gauge {
            let bar = NSRect(x: chartLeft, y: rect.minY + 56, width: chartWidth, height: 5)
            Palette.hairline.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 2.5, yRadius: 2.5).fill()

            let fraction = CGFloat(min(1.0, max(0.0, gauge.fraction)))
            // Once a transfer is near the ceiling the link is the limit, not the
            // device at either end. Colour says which regime you are in.
            // Orange says "the link is the limit". Against a device's own best that is
            // no limit at all - a full bar only means it is doing what it usually does -
            // so the peak-relative bar stays neutral however full it looks.
            let fill: NSColor
            if gauge.ofLink {
                fill = gauge.fraction >= 0.85 ? NSColor.systemOrange
                     : (gauge.fraction >= 0.40 ? Palette.down : Palette.up)
            } else {
                fill = NSColor.secondaryLabelColor
            }
            fill.setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY,
                                             width: max(2, bar.width * fraction),
                                             height: bar.height),
                         xRadius: 2.5, yRadius: 2.5).fill()

            // A tick at the session peak, so a link that briefly maxed out still
            // shows it after the transfer settles down. Only meaningful against a
            // fixed ceiling - against the peak itself the tick is always at the end.
            if gauge.ofLink,
               let peakUsed = Reference.utilization(down: row.peakDirectional, up: 0,
                                                    linkBits: row.linkBits),
               peakUsed > gauge.fraction + 0.03 {
                let x = bar.minX + bar.width * CGFloat(min(1.0, peakUsed))
                NSColor.labelColor.withAlphaComponent(0.6).setFill()
                NSRect(x: min(bar.maxX - 2, max(bar.minX, x - 1)), y: bar.minY - 2,
                       width: 2, height: bar.height + 4).fill()
            }
        }

        // ---- right column: the numbers -----------------------------------
        // A row that is moving data gets its figures on a tinted plate, so the ones
        // that matter are findable at a glance among a column of zeroes.
        if row.active {
            let plate = NSRect(x: rightEdge - rateColumnWidth - 8, y: rect.minY + 10,
                               width: rateColumnWidth + 14, height: 40)
            Palette.emphasis.setFill()
            NSBezierPath(roundedRect: plate, xRadius: 7, yRadius: 7).fill()
        }
        Text.draw(row.inShort + " " + Fmt.rate(row.down, unit: unit),
                  at: NSPoint(x: 0, y: rect.minY + 16),
                  font: rateFont, color: Palette.down, alignRight: rightEdge)
        Text.draw(row.outShort + " " + Fmt.rate(row.up, unit: unit),
                  at: NSPoint(x: 0, y: rect.minY + 34),
                  font: rateFont, color: Palette.up, alignRight: rightEdge)
        Text.draw(Fmt.bytes(Double(row.totalDown)) + " / " + Fmt.bytes(Double(row.totalUp)),
                  at: NSPoint(x: 0, y: rect.minY + 53),
                  font: totalFont, color: NSColor.tertiaryLabelColor, alignRight: rightEdge)

        // Against a real link, name the figure. Against the device's own best, the
        // useful number is that best itself - the bar already shows how near it is.
        if let gauge = gauge, gauge.ofLink {
            Text.draw(gauge.label,
                      at: NSPoint(x: 0, y: rect.minY + 65),
                      font: totalFont,
                      color: gauge.fraction >= 0.85 ? NSColor.systemOrange
                                                    : NSColor.tertiaryLabelColor,
                      alignRight: rightEdge)
        } else if row.peak > 0 {
            Text.draw("peak " + Fmt.rate(row.peak, unit: unit),
                      at: NSPoint(x: 0, y: rect.minY + 65),
                      font: totalFont, color: NSColor.tertiaryLabelColor, alignRight: rightEdge)
        }

        // Fourth line: the processes the kernel says are responsible, then any
        // suggestion. Kept small and grey so it informs without shouting.
        var footer = ""
        // Calm rows keep the recommendation - it is the reason to read the row at all -
        // and drop the running commentary of processes and Apple's marketing name,
        // both of which the hover card shows in full.
        if verbose, !row.actors.isEmpty {
            footer = row.actors.map { "\($0.display) \(Fmt.rate($0.bytesPerSec, unit: unit))" }
                .joined(separator: "   ")
        }
        if verbose, !row.appleName.isEmpty {
            let apple = "Apple: " + row.appleName
            footer += footer.isEmpty ? apple : "   ·   " + apple
        }
        if !row.hint.isEmpty {
            footer += footer.isEmpty ? row.hint : "   ·   " + row.hint
        }
        if !footer.isEmpty {
            // Stop short of the rate column, which shares this baseline.
            Text.draw(Text.clip(footer, font: totalFont, maxWidth: max(0, chartRight - textLeft - 8)),
                      at: NSPoint(x: textLeft, y: rect.minY + 68),
                      font: totalFont,
                      color: NSColor.tertiaryLabelColor)
        }
    }
}
