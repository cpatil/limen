import Cocoa

/// The colour key, as a chart rather than a paragraph.
///
/// Shown from the mark in the toolbar and from the line along the bottom. A legend
/// that only exists in prose is one most people never read; the point of a code is
/// that it can be looked up in a second.
final class LegendView: NSView {

    /// The long form, shown from the information button beside the key.
    static let explanation =
        "Limen shows two kinds of statement, and they are not equally certain.\n\n"
        + "Measured. Bytes read and written, how full a volume is, the rate a link "
        + "negotiated, which processes hold a file open. These come from the kernel "
        + "and the storage stack, and Limen only does arithmetic on them.\n\n"
        + "Inferred, marked \u{2248} and drawn in violet. What kind of card is in a "
        + "reader, how a rate compares with what that class of device typically "
        + "manages, what limited a transfer, and what would help. These come from "
        + "matching a measurement against a catalogue of hardware, and a match is not "
        + "a proof: a rate near an SDXC card's ceiling is equally consistent with a "
        + "slow reader, a busy machine at the other end, a tree of small files, or a "
        + "device that has got hot.\n\n"
        + "Hovering a row brings up its card, which spells out every conclusion on that "
        + "row and what each was drawn from - so you can disagree with it. Clicking a "
        + "row keeps that card open until you dismiss it."


    static func explain() {
        let alert = NSAlert()
        alert.messageText = "Measured, and worked out"
        alert.informativeText = LegendView.explanation
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// The key itself: swatches and one line each.
    static func showKey() {
        let alert = NSAlert()
        alert.messageText = "What the colors mean"
        alert.informativeText = "Anything marked \u{2248} was worked out from a "
            + "measurement rather than measured. Hovering a row explains each one it "
            + "carries; clicking a row keeps that card open."
        alert.accessoryView = LegendView(frame: NSRect(origin: .zero,
                                                       size: LegendView.fittingSize))
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    struct Entry {
        let swatches: [NSColor]
        let mark: String
        let title: String
        let detail: String
    }

    static var entries: [Entry] {
        [
            Entry(swatches: [Palette.inferred], mark: "\u{2248}",
                  title: "Worked out, not measured",
                  detail: "Matched against a catalogue of what hardware normally does"),
            Entry(swatches: [Palette.down], mark: "",
                  title: "Read, and traffic in",
                  detail: "Counted by the kernel and the storage stack"),
            Entry(swatches: [Palette.up], mark: "",
                  title: "Written, and traffic out",
                  detail: "Counted the same way"),
            Entry(swatches: [NSColor.systemOrange], mark: "",
                  title: "At the link's ceiling",
                  detail: "85% or more of a rate the system itself reported"),
            Entry(swatches: [NSColor.systemRed], mark: "",
                  title: "Costing you something",
                  detail: "Nothing is stopping Spotlight indexing this volume"),
            Entry(swatches: [NSColor.systemGreen, NSColor.systemYellow, NSColor.systemRed],
                  mark: "",
                  title: "How full the device is",
                  detail: "The level beside the icon: amber past 70%, red past 90%"),
        ]
    }

    private static let rowHeight: CGFloat = 38
    static var fittingSize: NSSize {
        NSSize(width: 460, height: CGFloat(entries.count) * rowHeight + 8)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Palette.canvas.setFill()
        Palette.paintable(dirty: dirtyRect, bounds: bounds).fill()
        let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let detailFont = NSFont.systemFont(ofSize: 11.5)
        let markFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        var y: CGFloat = 4

        for entry in LegendView.entries {
            // One swatch, or three stacked left to right where the colour is a scale
            // rather than a state.
            var x: CGFloat = 4
            for colour in entry.swatches {
                colour.setFill()
                let width: CGFloat = entry.swatches.count > 1 ? 8 : 24
                NSBezierPath(roundedRect: NSRect(x: x, y: y + 8, width: width, height: 16),
                             xRadius: 3, yRadius: 3).fill()
                x += width + 2
            }
            if !entry.mark.isEmpty {
                Text.draw(entry.mark, at: NSPoint(x: 36, y: y + 8),
                          font: markFont, color: Palette.inferred)
            }
            Text.draw(entry.title, at: NSPoint(x: 58, y: y + 4),
                      font: titleFont, color: NSColor.labelColor)
            Text.draw(entry.detail, at: NSPoint(x: 58, y: y + 20),
                      font: detailFont, color: Palette.faint)
            y += LegendView.rowHeight
        }
    }
}

final class RootView: NSView, NSSplitViewDelegate {
    let usbList = TrafficListView()
    let netList = TrafficListView()
    let historyList = HistoryView()
    private lazy var usbColumn = ColumnView(title: "STORAGE", tint: Palette.down, content: usbList)
    private lazy var netColumn = ColumnView(title: "NETWORK", tint: Palette.up, content: netList)
    private lazy var historyColumn = ColumnView(title: "TRANSFER SESSIONS",
                                                tint: NSColor.secondaryLabelColor,
                                                content: historyList)
    /// USB beside network, with the session log underneath - all three draggable and
    /// all three remembered.
    let columnsSplit = NSSplitView()
    let outerSplit = NSSplitView()
    private let magnifier = MagnifierView()
    /// Mirrors the monitor's sampling interval so the chart can state its time span.
    var sampleInterval: TimeInterval = 1
    /// Which row the card is showing, so it can be refreshed on every sample rather
    /// than only when the pointer moves.
    private var magnifiedRowID: String?
    /// (row ids in their new order, whether this is the storage list).
    var onReorder: (([String], Bool) -> Void)?
    var onVolumeChanged: (() -> Void)?

    /// One sort control per section, shown in that section's heading rather than the
    /// toolbar - so it is obvious which list it orders, and each is remembered
    /// separately.
    let storageSort = NSPopUpButton(frame: .zero, pullsDown: false)
    let networkSort = NSPopUpButton(frame: .zero, pullsDown: false)
    let unitControl = NSSegmentedControl(labels: ["B/s", "bit/s"],
                                         trackingMode: .selectOne,
                                         target: nil,
                                         action: nil)
    let intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let inactiveToggle = NSButton(checkboxWithTitle: "Show all", target: nil, action: nil)
    /// The colour key, at the top-left corner where a legend is looked for, and the
    /// long explanation behind an information button beside it. Both were once a line
    /// of prose along the bottom of the window, which spent a row of the interface on
    /// something most people need to read exactly once.
    let legendButton = NSButton(title: "\u{2248} Color key", target: nil, action: nil)
    let infoButton = NSButton(title: "\u{24D8}", target: nil, action: nil)
    /// Re-applies the section orders. "Active first" is held rather than recomputed
    /// every second, so this is how you ask for it to be worked out again. There is
    /// one per section, sitting beside that section's sort control - a single button
    /// in the toolbar was six hundred points away from the thing it acts on, and went
    /// unnoticed.
    let storageResort = NSButton(title: "⟳", target: nil, action: nil)
    let networkResort = NSButton(title: "⟳", target: nil, action: nil)

    private let headerHeight: CGFloat = 46

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    /// View preferences persist, so a chosen unit stays chosen everywhere and
    /// across launches rather than resetting to bytes each time.
    private enum Pref {
        static let unit = "RateUnit"
        static let storageSort = "SortOrder.Storage"
        static let networkSort = "SortOrder.Network"
        static let interval = "Interval"
        static let showAll = "ShowInactive"
    }

    private func setup() {
        wantsLayer = true
        unitControl.selectedSegment = UserDefaults.standard.integer(forKey: Pref.unit)
        unitControl.toolTip = "Show every speed in bytes per second or bits per second.\n\n"
            + "Storage is normally quoted in bytes, networks in bits - a \"1 Gbit\" link "
            + "carries about 118 MB/s. The choice applies everywhere and is remembered."

        intervalPopup.addItems(withTitles: ["0.5 s", "1 s", "2 s", "5 s"])
        let savedInterval = UserDefaults.standard.object(forKey: Pref.interval) as? Int
        intervalPopup.selectItem(at: savedInterval ?? 1)
        intervalPopup.bezelStyle = .rounded
        intervalPopup.toolTip = "How often speeds are measured.\n\n"
            + "A shorter interval reacts faster and shows brief spikes; a longer one "
            + "averages over more time and reads more steadily."

        for (popup, key, what) in [(storageSort, Pref.storageSort, "storage list"),
                                   (networkSort, Pref.networkSort, "network list")] {
            popup.addItems(withTitles: [Monitor.SortOrder.activeFirst.title,
                                        Monitor.SortOrder.name.title,
                                        Monitor.SortOrder.rate.title,
                                        Monitor.SortOrder.total.title,
                                        Monitor.SortOrder.manual.title])
            popup.selectItem(at: UserDefaults.standard.integer(forKey: key))
            popup.bezelStyle = .rounded
            popup.controlSize = .small
            popup.font = NSFont.systemFont(ofSize: 10)
            popup.toolTip = "How the \(what) is ordered. Kept separately for each "
                + "section and remembered.\n\n"
                + "Active first keeps whatever is moving data at the top, without "
                + "reshuffling every second the way ordering by rate does.\n\n"
                + "Dragging a row up or down switches this list to a custom order and "
                + "remembers it."
        }
        for (button, what) in [(storageResort, "storage"), (networkResort, "network")] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: 13)
            button.toolTip = "Work out the \(what) order again.\n\n"
                + "\"Active first\" is decided when Limen starts and then held, so rows "
                + "do not swap places while you are reading them. This asks for it to "
                + "be reconsidered - after plugging something in, say."
        }
        usbColumn.accessory = Self.orderControls(storageResort, storageSort)
        netColumn.accessory = Self.orderControls(networkResort, networkSort)
        inactiveToggle.state = UserDefaults.standard.bool(forKey: Pref.showAll) ? .on : .off
        inactiveToggle.toolTip = "Include things that are not real hardware.\n\n"
            + "Normally the lists show physical devices only. A VPN tunnel or a bridge "
            + "carries traffic that is also counted on the interface underneath it, so "
            + "showing both puts the same bytes on screen twice.\n\n"
            + "Turning this on reveals tunnels, bridges, loopback and other virtual "
            + "interfaces, and USB hubs with nothing attached."

        legendButton.bezelStyle = .rounded
        legendButton.controlSize = .small
        // Otherwise it takes first responder on launch and wears the focus ring, which
        // makes a legend look like the thing you are being asked to press.
        legendButton.refusesFirstResponder = true
        legendButton.target = self
        legendButton.action = #selector(showLegend)
        legendButton.attributedTitle = NSAttributedString(
            string: "\u{2248} Color key",
            attributes: [.foregroundColor: Palette.inferred,
                         .font: NSFont.systemFont(ofSize: 11, weight: .medium)])
        legendButton.toolTip = "What the colors mean.\n\n"
            + "Anything marked \u{2248} was worked out from a measurement rather than "
            + "measured, and is drawn in violet."

        infoButton.bezelStyle = .rounded
        infoButton.controlSize = .small
        infoButton.refusesFirstResponder = true
        infoButton.target = self
        infoButton.action = #selector(showInferenceHelp)
        // Drawn as a glyph rather than NSImage(named: .infoName): that image is tiny
        // and pale at this size, and next to a labelled button it read as a smudge.
        infoButton.attributedTitle = NSAttributedString(
            string: "\u{24D8}",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                         .font: NSFont.systemFont(ofSize: 13, weight: .regular)])
        infoButton.toolTip = "Which readings are measured and which are worked out."

        columnsSplit.dividerStyle = .thin
        columnsSplit.delegate = self
        applyPaneLayout()

        outerSplit.isVertical = false
        outerSplit.dividerStyle = .thin
        outerSplit.delegate = self
        outerSplit.autosaveName = "LimenRows"
        outerSplit.addArrangedSubview(columnsSplit)
        outerSplit.addArrangedSubview(historyColumn)

        magnifier.isHidden = true
        magnifier.wantsLayer = true
        magnifier.layer?.shadowOpacity = 0.28
        magnifier.layer?.shadowRadius = 14
        magnifier.layer?.shadowOffset = CGSize(width: 0, height: -4)

        // Hovering a rate or a chart enlarges it, so the small type in the rows does
        // not have to be squinted at.
        for list in [usbList, netList] {
            list.onHover = { [weak self] row, zone, details, windowPoint in
                self?.showMagnifier(row: row, zone: zone, details: details, at: windowPoint)
            }
            list.onPin = { [weak self] row, zone, details, windowPoint in
                self?.pinMagnifier(row: row, zone: zone, details: details, at: windowPoint)
            }
        }
        magnifier.onClose = { [weak self] in self?.unpinMagnifier() }
        // Dragging a row is only meaningful if the arrangement then survives the next
        // sample, so a drag selects custom order for that list and saves it.
        usbList.onReorder = { [weak self] ids in self?.onReorder?(ids, true) }
        netList.onReorder = { [weak self] ids in self?.onReorder?(ids, false) }
        for list in [usbList, netList] {
            list.onVolumeChanged = { [weak self] in self?.onVolumeChanged?() }
        }

        // Escape puts a pinned card away. The cross is the discoverable way; this is
        // the one people's hands already know.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.pinnedRowID != nil, event.keyCode == 53 else {
                return event
            }
            self.unpinMagnifier()
            return nil
        }

        addSubview(outerSplit)
        addSubview(legendButton)
        addSubview(infoButton)
        addSubview(unitControl)
        addSubview(intervalPopup)
        addSubview(inactiveToggle)
        // Last, so it is drawn above everything. Added earlier it sat beneath the
        // summary, which then painted its text over the panel and made it look
        // translucent when it never was.
        addSubview(magnifier)
    }

    /// Whether the two sections sit beside each other or one above the other, and
    /// which comes first. Both are choices about your own screen - a tall window wants
    /// them stacked, and which section you read first is a habit, not a rule.
    static let stackedKey = "PanesStacked"
    static let swappedKey = "PanesSwapped"

    var panesAreStacked: Bool { UserDefaults.standard.bool(forKey: RootView.stackedKey) }
    var panesAreSwapped: Bool { UserDefaults.standard.bool(forKey: RootView.swappedKey) }

    func applyPaneLayout() {
        let stacked = panesAreStacked
        let order: [ColumnView] = panesAreSwapped ? [netColumn, usbColumn] : [usbColumn, netColumn]

        for view in columnsSplit.arrangedSubviews {
            columnsSplit.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        columnsSplit.isVertical = !stacked
        // A divider position saved while side by side is a width; reusing it as a
        // height would drop the divider somewhere arbitrary. Each arrangement keeps
        // its own remembered position.
        columnsSplit.autosaveName = stacked ? "LimenColumnsStacked" : "LimenColumns"
        for view in order { columnsSplit.addArrangedSubview(view) }
        columnsSplit.adjustSubviews()
        needsLayout = true
    }

    /// The refresh button and the sort popup as one unit, so a heading can hold both.
    private static func orderControls(_ button: NSButton, _ popup: NSPopUpButton) -> NSView {
        let stack = NSStackView(views: [button, popup])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        return stack
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        Palette.canvas.setFill()
        dirtyRect.fill()
        Palette.hairline.setFill()
        NSRect(x: 0, y: bounds.maxY - headerHeight, width: bounds.width, height: 1).fill()
    }

    // Keep either column from being dragged away entirely.
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === outerSplit { return 150 }
        return splitView.isVertical ? 260 : 110
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === outerSplit { return max(150, splitView.bounds.height - 110) }
        return splitView.isVertical
            ? max(260, splitView.bounds.width - 260)
            : max(110, splitView.bounds.height - 110)
    }

    /// Whether hovering enlarges anything. On by default - it is the reason the small
    /// type in the rows is readable - but it follows the pointer everywhere, and if you
    /// are reading rather than inspecting that is a distraction. Off, the tooltips
    /// remain, so a clipped name is still recoverable.
    static let hoverKey = "HoverMagnifier"
    static var hoverEnabled: Bool {
        UserDefaults.standard.object(forKey: hoverKey) as? Bool ?? true
    }

    deinit {
        if let monitor = escapeMonitor { NSEvent.removeMonitor(monitor) }
    }

    @objc func showLegend(_ sender: Any?) { LegendView.showKey() }

    @objc func showInferenceHelp(_ sender: Any?) { LegendView.explain() }

    /// Which row's card is being held open, if any.
    ///
    /// A card that only exists while the pointer is on the row cannot be read from
    /// top to bottom without the pointer drifting off it, and cannot be copied from
    /// at all. Clicking a row pins its card until it is dismissed.
    private var pinnedRowID: String?
    private var escapeMonitor: Any?

    func pinMagnifier(row: Row, zone: MagnifierView.Zone,
                      details: String, at windowPoint: NSPoint) {
        // Clicking the pinned row again puts it away: the same gesture that opened it.
        if pinnedRowID == row.id {
            unpinMagnifier()
            return
        }
        pinnedRowID = nil
        showMagnifier(row: row, zone: zone, details: details, at: windowPoint, force: true)
        guard !magnifier.isHidden else { return }
        pinnedRowID = row.id
        magnifier.isPinned = true
        magnifier.needsDisplay = true
    }

    func unpinMagnifier() {
        pinnedRowID = nil
        magnifier.isPinned = false
        magnifier.isHidden = true
        magnifiedRowID = nil
    }

    /// `force` is a click rather than the pointer passing over: it opens the card
    /// even for someone who has turned hover off, because they asked for this one.
    private func showMagnifier(row: Row?, zone: MagnifierView.Zone,
                               details: String, at windowPoint: NSPoint,
                               force: Bool = false) {
        // A pinned card ignores the pointer entirely - that is what pinning is.
        if pinnedRowID != nil, !force { return }
        guard force || RootView.hoverEnabled else {
            magnifier.isHidden = true
            magnifiedRowID = nil
            return
        }
        guard let row = row else {
            magnifier.isHidden = true
            magnifiedRowID = nil
            return
        }
        magnifiedRowID = row.id
        magnifier.row = row
        magnifier.zone = zone
        magnifier.details = details
        magnifier.unit = usbList.unit
        magnifier.sampleInterval = sampleInterval
        let local = convert(windowPoint, from: nil)
        // Sized to its content, so long device names and hints are never cut off.
        let size = NSSize(width: MagnifierView.width, height: magnifier.fittingHeight)
        // Keep it beside the pointer but always fully on screen.
        var x = local.x + 24
        if x + size.width > bounds.maxX - 8 { x = local.x - size.width - 24 }
        var y = local.y - size.height / 2
        y = min(max(8, y), max(8, bounds.maxY - size.height - 8))
        magnifier.frame = NSRect(x: max(8, x), y: y, width: size.width, height: size.height)
        // Keep it in front even if subviews are added later.
        if subviews.last !== magnifier {
            magnifier.removeFromSuperview()
            addSubview(magnifier)
        }
        magnifier.isHidden = false
        magnifier.needsDisplay = true
    }

    func hideMagnifier() {
        magnifier.isHidden = true
        magnifiedRowID = nil
    }

    /// Feeds the open card fresh numbers each tick. Without this it froze at
    /// whatever the values were when the pointer last moved, which reads as broken
    /// when the row beside it is still counting.
    func refreshMagnifier(from rows: [Row]) {
        guard !magnifier.isHidden, let id = magnifiedRowID else { return }
        guard let updated = rows.first(where: { $0.id == id }) else {
            // The device is gone - unplugged, or a tunnel that went away. A pinned
            // card would otherwise sit there describing something that no longer
            // exists, with no pointer movement coming to correct it.
            if pinnedRowID != nil { unpinMagnifier() }
            return
        }
        magnifier.row = updated
        magnifier.unit = usbList.unit
        // Content can change height as processes and hints come and go.
        var frame = magnifier.frame
        let wanted = magnifier.fittingHeight
        if abs(frame.height - wanted) > 1 {
            frame.origin.y += frame.height - wanted
            frame.size.height = wanted
            magnifier.frame = frame
        }
        magnifier.needsDisplay = true
    }

    override func layout() {
        super.layout()
        let top = bounds.maxY

        func place(_ view: NSView, rightOf x: CGFloat, width: CGFloat, height: CGFloat) -> CGFloat {
            view.frame = NSRect(x: x - width, y: top - headerHeight + (headerHeight - height) / 2,
                                width: width, height: height)
            return x - width
        }

        var cursor = bounds.maxX - 16
        let unitSize = unitControl.fittingSize
        cursor = place(unitControl, rightOf: cursor, width: unitSize.width, height: unitSize.height) - 10
        cursor = place(intervalPopup, rightOf: cursor, width: 78, height: 24) - 10
        let toggleSize = inactiveToggle.fittingSize
        cursor = place(inactiveToggle, rightOf: cursor,
                       width: toggleSize.width, height: toggleSize.height) - 18
        // The key sits with the other controls rather than alone in the far corner.
        cursor = place(infoButton, rightOf: cursor, width: 26, height: 22) - 6
        _ = place(legendButton, rightOf: cursor,
                  width: max(88, legendButton.fittingSize.width), height: 22)

        outerSplit.frame = NSRect(x: 0, y: 0, width: bounds.width,
                                  height: max(0, top - headerHeight - 1))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    private let root = RootView(frame: NSRect(x: 0, y: 0, width: 980, height: 660))
    private let monitor = Monitor()
    /// Most rows seen so far, so the window grows when devices appear but never
    /// fights a size the user chose.
    private var tallestSeen = 0


    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered,
                          defer: false)
        window.title = "Limen"
        // Without this, mouseMoved is never delivered and hover magnification never
        // fires, however the tracking areas are configured.
        window.acceptsMouseMovedEvents = true
        window.minSize = NSSize(width: 760, height: 420)
        window.contentView = root
        window.center()
        window.setFrameAutosaveName("LimenWindow")
        window.makeKeyAndOrderFront(nil)
        AppDelegate.applyAppearance()

        root.onReorder = { [weak self] ids, isStorage in
            self?.rowsReordered(ids, isStorage: isStorage)
        }
        root.onVolumeChanged = { [weak self] in
            self?.monitor.volumeStateChanged()
            self?.refresh()
        }
        root.storageSort.target = self
        root.storageSort.action = #selector(sortChanged)
        root.networkSort.target = self
        root.networkSort.action = #selector(sortChanged)
        root.unitControl.target = self
        root.unitControl.action = #selector(controlChanged)
        root.intervalPopup.target = self
        root.intervalPopup.action = #selector(intervalChanged)
        root.inactiveToggle.target = self
        root.inactiveToggle.action = #selector(inactiveChanged)
        root.storageResort.target = self
        root.storageResort.action = #selector(resortNow)
        root.networkResort.target = self
        root.networkResort.action = #selector(resortNow)

        // Adopt the persisted preferences rather than resetting them.
        monitor.showInactive = root.inactiveToggle.state == .on
        adoptSortOrders()
        intervalChanged()

        // Fill the catalogue from the copy inside the binary. No network: the app
        // never contacts anything unless the user explicitly asks it to.
        // So a watcher installed earlier opens this copy rather than guessing.
        CardWatch.rememberAppLocation()
        Catalogue.seedIfMissing()
        offerUpdateIfDue()

        // Editing the log rebuilds the pane immediately rather than at the next tick.
        root.historyList.onLogChanged = { [weak self] in self?.refresh() }
        monitor.onUpdate = { [weak self] in self?.refresh() }
        monitor.start()
        refresh()

        NSApp.activate(ignoringOtherApps: true)

        // First run only. Reachable afterwards from the Help menu.
        if !Setup.hasBeenSeen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showSetup(nil)
            }
        }
    }

    private var setupWindow: SetupWindowController?

    /// Puts the speed catalogue back to the copy inside the app.
    @objc func revertCatalogue(_ sender: Any?) {
        let alert = NSAlert()
        if !Catalogue.usingDownloaded {
            alert.messageText = "Already using the built-in catalogue"
            alert.informativeText = "No downloaded copy is in use."
        } else {
            alert.messageText = "Go back to the built-in speed catalogue?"
            alert.informativeText = "The downloaded copy will be discarded. You can "
                + "fetch it again from this menu whenever you like."
            alert.addButton(withTitle: "Revert")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Catalogue.revertToBuiltIn()
            let done = NSAlert()
            done.messageText = "Back to the built-in catalogue"
            done.informativeText = "Restart Limen to use it."
            done.addButton(withTitle: "OK")
            done.runModal()
            return
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Everything Limen remembers about how you like it, back to how it arrived.
    /// Deliberately does not touch the transfer log or any card - those are your data,
    /// and each has its own undo.
    @objc func resetSettings(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Put Limen's settings back to their defaults?"
        alert.informativeText = "Window size, section order, sorting, units, appearance, "
            + "row detail and the Cards switches all return to how they arrived.\n\n"
            + "Your transfer log is not touched, and no card is changed."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Turning the card jobs off through CardWatch, so the watcher it installed is
        // removed rather than left behind pointing at preferences that no longer exist.
        for job in CardWatch.Job.allCases { try? CardWatch.set(job, on: false) }
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            UserDefaults.standard.synchronize()
        }
        Setup.relaunch()
    }

    @objc func toggleCardJob(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let job = CardWatch.Job(rawValue: raw) else { return }
        let turningOn = !CardWatch.isOn(job)
        do {
            try CardWatch.set(job, on: turningOn)
            sender.state = turningOn ? .on : .off
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change that"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc func showLegend(_ sender: Any?) { LegendView.showKey() }

    @objc func showSetup(_ sender: Any?) {
        if setupWindow == nil { setupWindow = SetupWindowController() }
        setupWindow?.showWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Persist any transfer still in progress rather than dropping it.
        TransferLog.shared.flush()
    }

    @objc private func controlChanged() {
        UserDefaults.standard.set(root.unitControl.selectedSegment, forKey: "RateUnit")
        refresh()
    }

    /// Once a month, offer to check - and only offer. The download happens solely
    /// because the user pressed a button.
    private func offerUpdateIfDue() {
        guard Catalogue.updateReminderDue else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            let alert = NSAlert()
            alert.messageText = "Check for an updated speed catalogue?"
            alert.informativeText = "It has been a month since the last check. Limen does not "
                + "contact the network on its own, so this only happens if you ask it to."
            alert.addButton(withTitle: "Check Now")
            alert.addButton(withTitle: "Not Now")
            if alert.runModal() == .alertFirstButtonReturn {
                self?.checkForCatalogueUpdate(nil)
            } else {
                Catalogue.noteChecked()   // ask again next month, not next launch
            }
        }
    }

    @objc func checkForCatalogueUpdate(_ sender: Any?) {
        Catalogue.checkForUpdate { version, error in
            let alert = NSAlert()
            if let error = error {
                alert.messageText = "Could not check for an update"
                alert.informativeText = error
            } else if let version = version, version > 0 {
                alert.messageText = "Speed catalogue updated"
                alert.informativeText = "Now at version \(version). Restart Limen to use it."
            } else {
                alert.messageText = "Already up to date"
                alert.informativeText = "The catalogue in use is the newest published."
            }
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Grows the window so newly appeared devices are visible without scrolling.
    ///
    /// Plugging in ten cards should not leave nine of them hidden. It only ever grows,
    /// only when the row count reaches a new high, and never past the screen - so a
    /// window you have deliberately sized is left alone.
    private func growForContent(rowCount: Int) {
        guard rowCount > tallestSeen, let window = window,
              let screen = window.screen ?? NSScreen.main else { return }
        tallestSeen = rowCount

        let needed = CGFloat(rowCount) * TrafficListView.rowHeight + 24   // + column heading
        let visible = root.columnsSplit.bounds.height
        // Before the first layout the pane reports zero height, which would make the
        // shortfall look like the entire content and snap the window to full screen.
        guard visible > 50, needed > visible else {
            tallestSeen = 0          // try again once the view has a real size
            return
        }

        var frame = window.frame
        let grow = min(needed - visible, screen.visibleFrame.maxY - frame.maxY
                        + (frame.minY - screen.visibleFrame.minY))
        guard grow > 8 else { return }
        frame.size.height += grow
        frame.origin.y -= min(grow, frame.minY - screen.visibleFrame.minY)
        frame.size.height = min(frame.size.height, screen.visibleFrame.height)
        window.setFrame(frame, display: true, animate: true)
    }

    /// Appearance is explicit rather than only following the system, so the window
    /// can be dark on a light desktop when that is easier to read.
    @objc func setAppearance(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "Appearance")
        AppDelegate.applyAppearance()
        for item in sender.menu?.items ?? [] { item.state = item === sender ? .on : .off }
        root.needsDisplay = true
    }

    static func applyAppearance() {
        switch UserDefaults.standard.integer(forKey: "Appearance") {
        case 1: NSApp.appearance = NSAppearance(named: .aqua)
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil        // follow the system
        }
    }

    /// How much each row spells out. Nothing is lost either way - the hover card
    /// always shows everything - so this is purely how dense you want the lists.
    @objc func setRowDetail(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "RowDetail")
        for item in sender.menu?.items ?? [] { item.state = item === sender ? .on : .off }
        root.usbList.needsDisplay = true
        root.netList.needsDisplay = true
    }

    @objc func toggleHover(_ sender: NSMenuItem) {
        let now = !RootView.hoverEnabled
        UserDefaults.standard.set(now, forKey: RootView.hoverKey)
        sender.state = now ? .on : .off
        root.hideMagnifier()
    }

    @objc func setPanesStacked(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag == 1, forKey: RootView.stackedKey)
        for item in sender.menu?.items ?? [] { item.state = item === sender ? .on : .off }
        root.applyPaneLayout()
    }

    @objc func swapPanes(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!root.panesAreSwapped, forKey: RootView.swappedKey)
        root.applyPaneLayout()
    }

    @objc func setMinimumLogged(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "MinLoggedTransfer")
        for item in sender.menu?.items ?? [] { item.state = item === sender ? .on : .off }
    }

    /// Each section's order is stored under its own key, so choosing "Name" for the
    /// interfaces does not also reshuffle the drives.
    /// A drag is a decision about arrangement, so it selects custom order for that
    /// list and stores it. Without this the next sample would put everything back.
    private func rowsReordered(_ ids: [String], isStorage: Bool) {
        let popup = isStorage ? root.storageSort : root.networkSort
        popup.selectItem(at: Monitor.SortOrder.manual.rawValue)
        UserDefaults.standard.set(ids, forKey: isStorage ? "RowOrder.Storage"
                                                         : "RowOrder.Network")
        if isStorage { monitor.storageOrder = ids } else { monitor.networkOrder = ids }
        sortChanged()
    }

    private func adoptSortOrders() {
        monitor.storageOrder = UserDefaults.standard.stringArray(forKey: "RowOrder.Storage") ?? []
        monitor.networkOrder = UserDefaults.standard.stringArray(forKey: "RowOrder.Network") ?? []
        monitor.storageSort = Monitor.SortOrder(rawValue: root.storageSort.indexOfSelectedItem)
            ?? .activeFirst
        monitor.networkSort = Monitor.SortOrder(rawValue: root.networkSort.indexOfSelectedItem)
            ?? .activeFirst
    }

    /// Choosing a sort, or asking for a re-sort, discards the held arrangement. The
    /// next sample then works one out - there is no second ordering path that could
    /// disagree with the ordinary one.
    @objc func resortNow(_ sender: Any? = nil) {
        monitor.resortNow()
        refresh()
    }

    @objc private func sortChanged() {
        UserDefaults.standard.set(root.storageSort.indexOfSelectedItem, forKey: "SortOrder.Storage")
        UserDefaults.standard.set(root.networkSort.indexOfSelectedItem, forKey: "SortOrder.Network")
        adoptSortOrders()
        monitor.resortNow()
        refresh()
    }

    @objc private func intervalChanged() {
        UserDefaults.standard.set(root.intervalPopup.indexOfSelectedItem, forKey: "Interval")
        let intervals: [TimeInterval] = [0.5, 1, 2, 5]
        let index = min(max(0, root.intervalPopup.indexOfSelectedItem), intervals.count - 1)
        monitor.interval = intervals[index]
        root.sampleInterval = intervals[index]
    }

    @objc private func inactiveChanged() {
        UserDefaults.standard.set(root.inactiveToggle.state == .on, forKey: "ShowInactive")
        monitor.showInactive = root.inactiveToggle.state == .on
        refresh()
    }

    private func refresh() {
        let unit: RateUnit = root.unitControl.selectedSegment == 1 ? .bits : .bytes

        root.usbList.unit = unit
        root.netList.unit = unit


        root.usbList.update(monitor.usbRows)
        root.usbList.emptyMessage = "No storage devices"
        root.netList.update(monitor.networkRows)
        root.netList.emptyMessage = "No active interfaces"

        root.historyList.unit = unit
        // Running sessions first, so the pane is useful while a copy is happening.
        root.historyList.sessions = TransferLog.shared.inFlight + TransferLog.shared.sessions
        // Sized on USB devices only. Interfaces are a fixed set that is mostly idle,
        // and counting them made a first launch grow to fill the screen; plugged-in
        // devices are the thing that actually arrives unannounced.
        growForContent(rowCount: monitor.usbRows.count)
        root.refreshMagnifier(from: monitor.usbRows + monitor.networkRows)
        root.needsLayout = true
    }
}
