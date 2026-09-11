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
    /// A click that turned out not to be a drag. The card for that row is then held
    /// open until it is dismissed, so it can be read and copied from.
    var onPin: ((Row, MagnifierView.Zone, String, NSPoint) -> Void)?
    /// Emitted when rows have been dragged into a new arrangement, with the row ids in
    /// their new order. The window persists it and switches this list to custom order.
    var onReorder: (([String]) -> Void)?
    /// Something about a mounted volume changed, so the next sample should re-read it.
    var onVolumeChanged: (() -> Void)?

    /// Index of the row being dragged, while a drag is in progress.
    private var draggingIndex: Int?
    private var dragStartedAt: NSPoint = .zero
    /// Where within the row the pointer took hold, and where the row is now.
    private var dragGrabOffset: CGFloat = 0
    private var dragFloatY: CGFloat = 0
    /// A press only becomes a drag once it has moved far enough to mean it, so a
    /// click or a right-click never quietly rearranges the list.
    private var dragArmed = false

    private var tooltips: [NSView.ToolTipTag: String] = [:]
    private var tracking: NSTrackingArea?
    /// Row under the pointer, highlighted so it is easy to keep your place.
    private var hoveredIndex: Int?

    private(set) var rows: [Row] = [] {
        didSet {
            invalidateHeight()
            // Tooltip and accessibility rebuilds walk every row. Doing that on each
            // frame of a drag is most of why dragging felt heavy, and neither is worth
            // anything until the row lands.
            if !dragArmed {
                rebuildTooltips()
                refreshAccessibilityRows()
            }
            needsDisplay = true
        }
    }

    /// Takes a fresh sample from the monitor.
    ///
    /// Mid-drag this keeps the arrangement on screen and refreshes only the numbers
    /// inside it. Assigning the sampler's order straight in used to undo the drag in
    /// progress - and if a sample landed in the moment between the last mouse-move and
    /// letting go, the ids written down on drop were the sampler's, not yours, so the
    /// row sprang back. That is the "it didn't stick" bug.
    func update(_ incoming: [Row]) {
        rows = TrafficListView.nextRows(current: rows, incoming: incoming,
                                        reordering: dragArmed)
    }

    /// What the list should show given a fresh sample. Pure, so the choice itself is
    /// covered rather than only the merge it delegates to.
    static func nextRows(current: [Row], incoming: [Row], reordering: Bool) -> [Row] {
        reordering ? merged(holding: current, incoming: incoming) : incoming
    }

    /// Fresh values in the order already on screen.
    ///
    /// Anything that vanished mid-drag drops out; anything new waits until the drag is
    /// over rather than materialising under the pointer.
    static func merged(holding current: [Row], incoming: [Row]) -> [Row] {
        var byID: [String: Row] = [:]
        for row in incoming { byID[row.id] = row }
        return current.compactMap { byID[$0.id] }
    }

    /// Which slot a row being carried at `floatY` should drop into.
    ///
    /// Measured from the middle of the floating row rather than the pointer. With the
    /// pointer the row is already beneath the cursor when the test runs, so a single
    /// pixel of movement can flip it back and forth across a boundary - which is what
    /// made dragging feel jumpy.
    static func insertionIndex(floatY: CGFloat, rowCount: Int,
                               rowHeight: CGFloat = TrafficListView.rowHeight) -> Int {
        guard rowCount > 0 else { return 0 }
        let centre = floatY + rowHeight / 2
        return min(max(0, Int(centre / rowHeight)), rowCount - 1)
    }
    var unit: RateUnit = .bytes {
        didSet { needsDisplay = true }
    }
    var emptyMessage = "No data"

    override var isFlipped: Bool { true }

    /// Act on the first click even when Bottleneck is not the active app. This is a window
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
        // The handle's gutter magnifies nothing: you are on your way to grab the row.
        guard !TrafficListView.isOverHandle(x: point.x) else { return nil }
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
        // Spelled out rather than left to the glyph: VoiceOver reads "almost equal
        // to", which is not what the mark means here.
        if !row.mediumClass.isEmpty {
            parts.append("card type inferred from capacity: " + row.mediumClass)
        }
        if !Fmt.fsName(row.fsType).isEmpty {
            parts.append("formatted as " + Fmt.fsName(row.fsType))
        }
        if !row.volumes.isEmpty { parts.append(row.volumes.joined(separator: ", ")) }
        if row.indexingWorthReporting {
            parts.append(row.indexingDisabled
                ? "Spotlight told to skip this volume"
                : "nothing is stopping Spotlight indexing this volume")
        }
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
            parts.append(gauge.isInferred ? "estimated " + gauge.longLabel : gauge.label)
        }
        if !row.hint.isEmpty { parts.append("inferred: " + row.hint) }
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
        // Where inside the row it was grabbed, so it does not snap its top to the
        // pointer the moment it lifts.
        dragGrabOffset = local.y - CGFloat(index) * TrafficListView.rowHeight
        dragFloatY = CGFloat(index) * TrafficListView.rowHeight
        dragArmed = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let from = draggingIndex else { return }
        let local = convert(event.locationInWindow, from: nil)
        if !dragArmed {
            guard abs(local.y - dragStartedAt.y) > 4 else { return }
            dragArmed = true
            NSCursor.closedHand.push()
            // The hover card would otherwise sit over the rows being rearranged.
            onHover?(nil, .rate, "", .zero)
        }

        // The row tracks the pointer continuously; the list reflows around it. Moving
        // the row only in whole-row steps was what made this feel jumpy.
        let height = TrafficListView.rowHeight
        let limit = max(0, CGFloat(rows.count - 1) * height)
        dragFloatY = min(max(0, local.y - dragGrabOffset), limit)

        // Insertion follows the middle of the floating row, not the pointer. Using the
        // pointer means the row is already under the cursor when the test runs, so it
        // can swap back and forth across a boundary on a single pixel of movement.
        let to = TrafficListView.insertionIndex(floatY: dragFloatY, rowCount: rows.count,
                                                rowHeight: height)
        if to != from {
            let moved = rows.remove(at: from)
            rows.insert(moved, at: to)
            draggingIndex = to
        }
        hoveredIndex = draggingIndex
        autoscroll(with: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            draggingIndex = nil
            dragArmed = false
            rebuildTooltips()
            refreshAccessibilityRows()
            needsDisplay = true
        }
        guard dragArmed else {
            // Not a drag after all, so it was a click on the row: hold its card open.
            // The handle's gutter is excluded by hit(), the same rule hovering uses -
            // reaching for the grip should not open anything.
            let local = convert(event.locationInWindow, from: nil)
            if let (row, zone) = hit(local) {
                onPin?(row, zone, identity(for: row), convert(local, to: nil))
            }
            return
        }
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
        if !card.isEmpty { parts.append(Palette.mark + card) }
        // What it is formatted as. This is the text the tooltip shows and the Copy
        // item puts on the pasteboard, so anything the row states has to be here too
        // - a fact you can see but not copy is a fact you have to retype.
        // What it is formatted as. This is the text the tooltip shows and the Copy
        // item puts on the pasteboard, so anything the row states has to be here too
        // - a fact you can see but not copy is a fact you have to retype.
        let format = Fmt.fsName(row.fsType)
        if !format.isEmpty { parts.append(format) }
        if row.capacityBytes > 0 {
            parts.append(Fmt.bytes(Double(row.capacityBytes - row.usedBytes)) + " free of "
                         + Fmt.bytes(Double(row.capacityBytes)))
        }
        if !row.badge.isEmpty { parts.append(row.badge) }
        if row.linkTrusted, row.linkBits > 0 {
            parts.append(Fmt.dualSpeed(bitsPerSec: row.linkBits, unit: unit))
        }
        for name in [row.alsoKnown, row.appleName] where !name.isEmpty {
            parts.append("Also known as " + name)
        }
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
        // Out of sight, still counted. Offered on every row, and the same item takes
        // it back - "Show all hidden rows" in the View menu finds them again if the
        // row itself is no longer on screen to right-click.
        let hidden = Hidden.isHidden(id: row.id)
        let hideItem = NSMenuItem(title: hidden ? "Show \u{201C}\(row.title)\u{201D} Again"
                                                : "Hide \u{201C}\(row.title)\u{201D}",
                                  action: #selector(toggleHidden(_:)), keyEquivalent: "")
        hideItem.target = self
        hideItem.representedObject = [row.id, row.title]
        hideItem.toolTip = "Hidden rows keep being measured and keep being logged. "
            + "They leave the list, and their transfers stop being bumped to the top "
            + "of the session log."
        menu.addItem(NSMenuItem.separator())
        menu.addItem(hideItem)

        if row.removable, !row.mountRoots.isEmpty {
            let already = row.mountRoots.allSatisfy {
                FileManager.default.fileExists(atPath: $0 + "/.metadata_never_index")
            }
            let name = row.volumes.first ?? "this card"
            // Both directions, from the same menu. Writing a marker onto someone's
            // card and giving them no way to take it off would leave them editing a
            // hidden file by hand to undo a menu click.
            let item = NSMenuItem(title: already ? "Let Spotlight Index “\(name)” Again"
                                                 : "Stop Spotlight Indexing “\(name)”",
                                  action: #selector(toggleIndexing(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = row.mountRoots as NSArray
            menu.addItem(NSMenuItem.separator())
            menu.addItem(item)
        }
        return menu
    }

    /// Writes `.metadata_never_index` at the volume root - the durable way to stop
    /// Spotlight indexing a card. It needs no password, lives on the volume so it
    /// travels to any Mac, and is undone by deleting the file.
    /// Adds or removes `.metadata_never_index` at the volume root - the durable way to
    /// stop Spotlight indexing a card, and to allow it again. It needs no password,
    /// lives on the volume so it travels to any Mac, and either direction is one click.
    @objc private func toggleHidden(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        Hidden.set(id: pair[0], name: pair[1], hidden: !Hidden.isHidden(id: pair[0]))
        onVolumeChanged?()
    }

    @objc private func toggleIndexing(_ sender: NSMenuItem) {
        guard let roots = sender.representedObject as? [String] else { return }
        let marker = "/.metadata_never_index"
        let fm = FileManager.default
        let turningOff = !roots.allSatisfy { fm.fileExists(atPath: $0 + marker) }

        var failed: [String] = []
        for root in roots {
            let path = root + marker
            let exists = fm.fileExists(atPath: path)
            do {
                if turningOff && !exists {
                    guard fm.createFile(atPath: path, contents: Data()) else {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                } else if !turningOff && exists {
                    try fm.removeItem(atPath: path)
                }
            } catch {
                failed.append((root as NSString).lastPathComponent)
            }
        }

        onVolumeChanged?()
        let alert = NSAlert()
        if failed.isEmpty {
            alert.messageText = turningOff ? "Spotlight indexing stopped"
                                           : "Spotlight may index this volume again"
            alert.informativeText = turningOff
                ? "A .metadata_never_index file now sits at the volume root, so no Mac "
                    + "will index it. Choosing this again removes that file.\n\n"
                    + "Indexing already under way finishes; it will not start again."
                : "The .metadata_never_index file has been removed. Whether macOS "
                    + "actually indexes the volume now is its decision, not Bottleneck's."
        } else {
            alert.messageText = "Could not change \(failed.joined(separator: ", "))"
            alert.informativeText = "macOS withholds access to removable volumes until "
                + "it is granted. Allow Bottleneck under System Settings ▸ Privacy & "
                + "Security ▸ Files and Folders ▸ Removable Volumes, then try again."
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
            let rect = NSRect(x: TrafficListView.contentLeft, y: y,
                              width: max(40, textWidth - TrafficListView.contentLeft + 12),
                              height: TrafficListView.rowHeight)
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
                      color: Palette.faint)
            return
        }

        for (index, row) in rows.enumerated() {
            let rect = NSRect(x: 0,
                              y: CGFloat(index) * TrafficListView.rowHeight,
                              width: bounds.width,
                              height: TrafficListView.rowHeight)
            guard rect.intersects(dirtyRect) else { continue }
            if dragArmed, index == draggingIndex {
                // The gap the row will drop into, so the destination is visible while
                // the row itself is somewhere else under the pointer.
                NSColor.labelColor.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 3),
                             xRadius: 7, yRadius: 7).fill()
                continue
            }
            draw(row: row, in: rect, index: index)
        }

        // Last, so it rides above the rest.
        if dragArmed, let index = draggingIndex, index < rows.count {
            let floating = NSRect(x: 0, y: dragFloatY,
                                  width: bounds.width, height: TrafficListView.rowHeight)
            NSGraphicsContext.saveGraphicsState()
            let plate = NSBezierPath(roundedRect: floating.insetBy(dx: 5, dy: 2),
                                     xRadius: 8, yRadius: 8)
            NSShadow.lifted.set()
            // Opaque: a translucent row picks up whatever it happens to pass over,
            // which reads as a rendering fault rather than as a lifted row.
            (NSColor.controlBackgroundColor.usingColorSpace(.sRGB)
                ?? NSColor.controlBackgroundColor).setFill()
            plate.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
            plate.lineWidth = 1.5
            plate.stroke()
            draw(row: rows[index], in: floating, index: index)
        }
    }

    /// The capacity level's own lane, between the icon and the text.
    ///
    /// Its own column rather than borrowed space beside the chart: how full a disk is
    /// belongs with what the disk *is*, not with what it is doing this second.
    /// Where the all-time peak sits on a bar, or nil when there is nothing to show.
    ///
    /// Nothing to show covers three cases: no peak recorded, no denominator to place
    /// it against, and a peak the current reading has already reached - a tick sitting
    /// under the end of the fill is not a second fact, it is a smudge.
    static func peakMark(in bar: NSRect, peak: Double, denominator: Double,
                         current: Double) -> NSRect? {
        guard peak > 0, denominator > 0, peak <= denominator else { return nil }
        let fraction = peak / denominator
        guard fraction > current + 0.03 else { return nil }
        let x = bar.minX + bar.width * CGFloat(fraction)
        return NSRect(x: min(bar.maxX - 2, max(bar.minX, x - 1)), y: bar.minY - 2,
                      width: 2, height: bar.height + 4)
    }

    /// Whether the best this device has ever done is off the end of this scale.
    ///
    /// Worth its own answer rather than a tick clamped to the last pixel. Clamping
    /// drew the mark exactly where "peaked at precisely the yardstick" would put it,
    /// so a drive whose best is eight times the scale looked like one that had just
    /// reached it - the reading was not merely imprecise, it was the wrong statement.
    static func peakIsBeyond(peak: Double, denominator: Double) -> Bool {
        peak > 0 && denominator > 0 && peak > denominator
    }

    /// A chevron at the end of the bar: "further than this scale goes".
    static func beyondMark(in bar: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let x = bar.maxX - 1
        let mid = bar.midY
        let h = bar.height / 2 + 2.5
        path.move(to: NSPoint(x: x - 3.5, y: mid - h))
        path.line(to: NSPoint(x: x + 1, y: mid))
        path.line(to: NSPoint(x: x - 3.5, y: mid + h))
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    static func capacityGauge(in row: NSRect) -> NSRect {
        NSRect(x: gaugeLeft, y: row.minY + 15, width: 8, height: 54)
    }

    /// Left edge of the capacity lane, and of the text that follows it.
    static let gaugeLeft: CGFloat = 48
    static let textLeft: CGFloat = 66

    /// Green while there is room, amber as it tightens, red when a copy is about to
    /// fail for want of space. The familiar reading for a disk.
    static func capacityColour(fraction: Double) -> NSColor {
        switch fraction {
        case ..<0.70: return NSColor.systemGreen
        case ..<0.90: return NSColor.systemYellow
        default: return NSColor.systemRed
        }
    }

    /// The filled part of the level, for a fullness of 0...1.
    ///
    /// The list view is flipped, so a larger y is further down the row: anchoring the
    /// fill to the gauge's maxY is what makes it rise from the bottom. Getting this
    /// backwards would draw a disk that empties as it fills, which no value check
    /// would catch, so it is a function that can be asserted about.
    static func capacityFill(in gauge: NSRect, fraction: Double) -> NSRect {
        let clamped = min(max(0, fraction), 1)
        let height = max(2, gauge.height * CGFloat(clamped))
        return NSRect(x: gauge.minX, y: gauge.maxY - height, width: gauge.width, height: height)
    }

    /// Where the chart column starts, for a row of this width.
    static func chartLeftEdge(rowWidth: CGFloat) -> CGFloat {
        let rightEdge = rowWidth - 16
        let chartWidth = min(130, max(54, rowWidth * 0.22))
        return rightEdge - 92 - 16 - chartWidth
    }

    /// Width of the margin reserved for the drag handle.
    static let gripWidth: CGFloat = 20

    /// Where a row's own content starts. Everything left of this is the handle's
    /// gutter, and one definition keeps the icon, the hover test and the tooltip
    /// rectangles from drifting apart.
    static let contentLeft: CGFloat = 24

    /// True when the pointer is in the handle's gutter.
    ///
    /// Hover magnification and dragging want the same pixels, and magnification wins
    /// by default because it needs no click. Reaching for the grip would raise a card
    /// over the row you were about to pick up, so the gutter is kept quiet.
    static func isOverHandle(x: CGFloat) -> Bool { x < contentLeft }

    private func drawGrip(in rect: NSRect, emphasised: Bool) {
        let dot: CGFloat = 4.0
        let columns = 2, dotRows = 3
        let spacing: CGFloat = 5.6
        let blockWidth = CGFloat(columns - 1) * spacing + dot
        let blockHeight = CGFloat(dotRows - 1) * spacing + dot
        let originX = (TrafficListView.gripWidth - blockWidth) / 2
        let originY = rect.midY - blockHeight / 2

        // Explicit alphas against labelColor rather than the tertiary/secondary pair.
        // Those are tuned for text sitting next to other text; a 3pt dot in the margin
        // needs more contrast than a word does to be noticed at all.
        NSColor.labelColor.withAlphaComponent(emphasised ? 0.80 : 0.45).setFill()
        for column in 0..<columns {
            for row in 0..<dotRows {
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
        let iconBox = NSRect(x: TrafficListView.contentLeft, y: rect.minY + 18,
                             width: 18, height: 18)
        Icons.draw(row.icon, in: iconBox,
                   color: Palette.secondary.withAlphaComponent(row.active ? 0.9 : 0.45))

        let textLeft = TrafficListView.textLeft
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
        // "via", because this badge is the cable, not the thing on the end of it. A
        // reader's card badge and its link badge sat side by side reading as two facts
        // about one object - so a card that manages 90 MB/s appeared to be a 625 MB/s
        // card. The link is what carries the card's bytes; it is not their source.
        var badgeText = row.badge.isEmpty ? "" : (row.removable ? "via " : "") + row.badge
        var alternate = ""
        if row.linkTrusted, row.linkBits > 0 {
            // The practical figure, not the signalling rate divided by eight. On a row
            // this number sits inches from the device's actual rate and invites
            // comparison, and 625 MB/s is not a number this port will ever carry.
            let ceiling = Reference.ceiling(forLinkBits: row.linkBits,
                                            family: row.compareFamilies.contains(.network)
                                                 ? .network : .usb)
            let primary = ceiling.map { Palette.mark + Fmt.rate($0.bytes, unit: .bytes) }
                ?? Fmt.speed(bitsPerSec: row.linkBits, unit: unit)
            badgeText = badgeText.isEmpty ? primary : badgeText + " · " + primary
            // The signalling rate, restated where there is room for it.
            if verbose { alternate = "= " + Fmt.linkSpeed(bitsPerSec: row.linkBits) }
        }
        // The card leads. When you look at a reader the question is what is in it, not
        // what it is plugged into - so its type, capacity and name come first, in their
        // own colour and at full strength.
        let card = Row.cardLabel(class: row.mediumClass, volumes: row.volumes)
        if !card.isEmpty {
            // Marked, because the leading word is a deduction: a reader presents
            // itself as USB mass storage and never reports which standard the card in
            // it follows, so "SDXC" is read off the capacity. The mark rides inside
            // the badge rather than being drawn beside it in violet - the badge
            // already owns a colour, which means "this is the card, not the port", and
            // two colour codes in one pill would collide. The mark alone carries it.
            cursorX += Text.drawBadge(Text.clip(Palette.mark + card, font: cardFont,
                                                maxWidth: textLimit - 24),
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
                      font: badgeFont, color: Palette.faint)
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
                      color: Palette.secondary)
        }

        let gauge = Reference.gauge(down: row.down, up: row.up,
                                    peakDirectional: row.peakDirectional, peak: row.peak,
                                    linkBits: row.linkBits, linkTrusted: row.linkTrusted,
                                    families: row.compareFamilies.isEmpty ? nil : row.compareFamilies,
                                    roles: row.compareRoles.isEmpty ? nil : row.compareRoles,
                                    internalMedium: row.internalMedium,
                                    kinds: row.mediumKinds.isEmpty ? nil : row.mediumKinds,
                                    hasKnownClass: row.hasKnownMediumClass)

        // Third line: either why we cannot measure this, or what the rate is
        // comparable to. One statement per question, though: where the bar already
        // answers "how does this compare", naming a second standard beside it said
        // the same thing twice and in a worse way - the name came from whatever
        // catalogue entry sat nearest the rate, so a card doing 12 MB/s was announced
        // as a 12 MB/s card.
        var context = row.note
        // Whether this line is a catalogue comparison rather than something observed.
        // row.note reports a fact about the interface; "best this session" is a
        // measurement; naming a standard from a rate is neither.
        var contextInferred = false
        if context.isEmpty, combined > 0 || row.peak > 0 {
            if !row.hasKnownMediumClass {
                // Throughput cannot identify what something is. It could not name a
                // Wi-Fi generation, and it cannot name anything else either: loopback
                // and a VPN tunnel were both being announced as "10 Mbit Ethernet",
                // because that was the catalogue entry nearest the rate they happened
                // to be carrying. Say what was seen instead.
                context = row.peak > 0 ? "best this session " + Fmt.rate(row.peak, unit: unit) : ""
            } else {
                contextInferred = gauge == nil && row.hasKnownMediumClass
                context = gauge != nil ? "" : Reference.context(current: combined, peak: row.peak, unit: unit,
                                            families: row.compareFamilies.isEmpty ? nil : row.compareFamilies,
                                            roles: row.compareRoles.isEmpty ? nil : row.compareRoles,
                                            internalMedium: row.internalMedium,
                                            kinds: row.mediumKinds.isEmpty ? nil : row.mediumKinds)
            }
        }
        let contextText = contextInferred && !context.isEmpty ? Palette.marked(context) : context
        Text.draw(Text.clip(contextText, font: subtitleFont, maxWidth: textLimit - textLeft),
                  at: NSPoint(x: textLeft, y: rect.minY + 56),
                  font: subtitleFont,
                  color: contextInferred ? Palette.inferred : Palette.faint)

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
        if let gauge = gauge {
            let bar = NSRect(x: chartLeft, y: rect.minY + 56, width: chartWidth, height: 5)
            Palette.hairline.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 2.5, yRadius: 2.5).fill()

            let fraction = CGFloat(min(1.0, max(0.0, gauge.fraction)))
            // Once a transfer is near the ceiling the link is the limit, not the
            // device at either end. Colour says which regime you are in.
            //
            // Against a typical figure from the catalogue none of that applies: the
            // denominator is an estimate, so 90% of it is not a device at its limit
            // and must not be dressed as one. That bar takes the inferred colour
            // instead, the same violet as its label - the bar and the number beside
            // it are one statement and should not be able to disagree.
            let fill: NSColor
            if gauge.ofLink {
                fill = gauge.fraction >= 0.85 ? NSColor.systemOrange
                     : (gauge.fraction >= 0.40 ? Palette.down : Palette.up)
            } else {
                fill = Palette.inferredFill
            }
            fill.setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY,
                                             width: max(2, bar.width * fraction),
                                             height: bar.height),
                         xRadius: 2.5, yRadius: 2.5).fill()

            // A tick at the best this device has ever done, on the same scale as the
            // bar. It answers the question the bar raises - "is that as good as it
            // gets?" - and it is the one number here that survives a restart, since
            // it comes from the transfer log rather than from this session.
            if let mark = TrafficListView.peakMark(in: bar, peak: row.allTimePeak,
                                                   denominator: gauge.denominatorBytes,
                                                   current: gauge.fraction) {
                NSColor.labelColor.withAlphaComponent(0.55).setFill()
                mark.fill()
            } else if TrafficListView.peakIsBeyond(peak: row.allTimePeak,
                                                   denominator: gauge.denominatorBytes) {
                NSColor.labelColor.withAlphaComponent(0.55).setStroke()
                TrafficListView.beyondMark(in: bar).stroke()
            }
        }

        // How full the device is, as a level filled from the bottom rather than a
        // second horizontal bar. Two horizontal bars in one column invite the eye to
        // compare them, and they measure unrelated things: one is speed against a
        // link, this is space against a disk.
        if let full = row.fullness {
            let gauge = TrafficListView.capacityGauge(in: rect)
            let width = gauge.width
            Palette.hairline.setFill()
            NSBezierPath(roundedRect: gauge, xRadius: width / 2, yRadius: width / 2).fill()

            TrafficListView.capacityColour(fraction: full).setFill()
            NSBezierPath(roundedRect: TrafficListView.capacityFill(in: gauge, fraction: full),
                         xRadius: width / 2, yRadius: width / 2).fill()
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
        // Two bare numbers side by side said nothing about which was which, and there
        // is no room in this column for "R" and "W" without running into the chart.
        // The rates immediately above are already labelled and colour-coded, so the
        // same colours identify these without costing any width.
        let readTotal = Fmt.bytes(Double(row.totalDown))
        let writeTotal = Fmt.bytes(Double(row.totalUp))
        let separator = " / "
        let totalsWidth = Text.width(readTotal, font: totalFont)
            + Text.width(separator, font: totalFont)
            + Text.width(writeTotal, font: totalFont)
        var totalsX = rightEdge - totalsWidth
        let totalsY = rect.minY + 53
        Text.draw(readTotal, at: NSPoint(x: totalsX, y: totalsY), font: totalFont,
                  color: Palette.downQuiet)
        totalsX += Text.width(readTotal, font: totalFont)
        Text.draw(separator, at: NSPoint(x: totalsX, y: totalsY), font: totalFont,
                  color: Palette.faint)
        totalsX += Text.width(separator, font: totalFont)
        Text.draw(writeTotal, at: NSPoint(x: totalsX, y: totalsY), font: totalFont,
                  color: Palette.upQuiet)

        // Name the figure in both cases, marked when it was worked out rather than
        // measured. This line used to show the session peak whenever the bar was not
        // link-relative, from when that bar was drawn against the peak itself; the bar
        // means something else now, so the line that labels it has to say so. The peak
        // is still on the hover card.
        if let gauge = gauge, gauge.ofLink {
            Text.draw(gauge.label,
                      at: NSPoint(x: 0, y: rect.minY + 65),
                      font: totalFont,
                      color: gauge.fraction >= 0.85 ? NSColor.systemOrange
                                                    : Palette.faint,
                      alignRight: rightEdge)
        } else if let gauge = gauge {
            // The long form where it fits, the short one where it does not. Both
            // carry the figure; only the long one can afford to name it as well.
            let room = rightEdge - chartRight - 4
            let long = Palette.marked(gauge.longLabel)
            let text = Text.width(long, font: totalFont) <= room
                ? long : Palette.marked(gauge.label)
            Text.draw(text, at: NSPoint(x: 0, y: rect.minY + 65),
                      font: totalFont, color: Palette.inferred, alignRight: rightEdge)
        } else if row.allTimePeak > 0 {
            Text.draw("best ever " + Fmt.rate(row.allTimePeak, unit: unit),
                      at: NSPoint(x: 0, y: rect.minY + 65),
                      font: totalFont, color: Palette.faint, alignRight: rightEdge)
        }

        // Fourth line: the processes the kernel says are responsible, then any
        // suggestion. Kept small and grey so it informs without shouting.
        // Spotlight sits on this line rather than among the badges or beside the
        // comparison: both of those were already full, and this one is empty on most
        // rows. It is drawn separately from the rest so the warning can stay red.
        var footerX = textLeft
        // What the volume is formatted as. A measurement - statfs reports it - so it
        // is stated plainly, in the ordinary text colour, with no mark.
        let format = Fmt.fsName(row.fsType)
        if !format.isEmpty {
            Text.draw(format, at: NSPoint(x: footerX, y: rect.minY + 68), font: totalFont,
                      color: Palette.secondary)
            footerX += Text.width(format, font: totalFont) + 10
        }
        if row.indexingWorthReporting {
            let note = row.indexingDisabled ? "Spotlight off" : "Spotlight not blocked"
            Text.draw(note, at: NSPoint(x: footerX, y: rect.minY + 68), font: totalFont,
                      color: row.indexingDisabled ? Palette.faint : Palette.warning)
            footerX += Text.width(note, font: totalFont) + 10
        }

        // Calm rows keep the recommendation - it is the reason to read the row at all -
        // and drop the running commentary of processes and Apple's marketing name,
        // both of which the hover card shows in full.
        var footer = ""
        if verbose, !row.actors.isEmpty {
            footer = row.actors.map { "\($0.display) \(Fmt.rate($0.bytesPerSec, unit: unit))" }
                .joined(separator: "   ")
        }
        if verbose, !row.appleName.isEmpty {
            let apple = "Apple: " + row.appleName
            footer += footer.isEmpty ? apple : "   ·   " + apple
        }
        let footerLimit = max(0, chartRight - footerX - 8)
        if !footer.isEmpty {
            // Stop short of the rate column, which shares this baseline.
            let text = Text.clip(footer, font: totalFont, maxWidth: footerLimit)
            Text.draw(text, at: NSPoint(x: footerX, y: rect.minY + 68),
                      font: totalFont, color: Palette.faint)
            footerX += Text.width(text, font: totalFont)
            if !row.hint.isEmpty {
                Text.draw("   ·   ", at: NSPoint(x: footerX, y: rect.minY + 68),
                          font: totalFont, color: Palette.faint)
                footerX += Text.width("   ·   ", font: totalFont)
            }
        }
        // Drawn on its own rather than joined to the line above, because it is the one
        // part of it that was worked out: advice comes from what the device was seen
        // to do, matched against the catalogue. Concatenating it into a grey string
        // would have made a deduction look like the rest of the reporting.
        if !row.hint.isEmpty {
            let room = max(0, chartRight - footerX - 8)
            if room > 40 {
                Text.draw(Text.clip(Palette.marked(row.hint), font: totalFont, maxWidth: room),
                          at: NSPoint(x: footerX, y: rect.minY + 68),
                          font: totalFont, color: Palette.inferred)
            }
        }
    }
}
