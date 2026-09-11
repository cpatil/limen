import Cocoa

/// Two panels sharing one layout: what the colours mean, and how Limen reaches the
/// conclusions it draws.
///
/// Panels rather than alerts. The alert these replaced was six paragraphs in one
/// block, which is the shape of a licence agreement - the eye slides off it, and the
/// sentence that matters is indistinguishable from the five that do not.
final class LegendView: NSView {

    enum Mode { case colors, inference }

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
                  detail: "Compared against a catalogue of what hardware normally does"),
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

    /// Every statement Limen makes that is not a direct reading, with what it rests on
    /// and - where there is one - what it cannot rule out. Written out in full because
    /// "trust me" is not an answer to "how do you know?".
    struct Statement {
        let inferred: Bool
        let claim: String
        let basis: String
    }

    static var statements: [Statement] {
        [
            Statement(inferred: false, claim: "\u{201C}R 86 MB/s\u{201D}, \u{201C}2.36 TB used\u{201D}",
                      basis: "Read straight from the kernel's byte counters and the "
                           + "filesystem. Limen only divides by the interval."),
            Statement(inferred: false, claim: "\u{201C}0% link utilization\u{201D}",
                      basis: "The rate divided by the link speed the system reported "
                           + "for that port. Both numbers are given to Limen."),
            Statement(inferred: true, claim: "\u{201C}SDXC 128 GB\u{201D}",
                      basis: "The SD family follows from the capacity once the reader "
                           + "says the medium is removable. The card's bus interface "
                           + "and speed class \u{2014} UHS-I, V30 \u{2014} are not "
                           + "exposed through a normal reader at all."),
            Statement(inferred: true, claim: "\u{201C}13% of a modern card\u{201D}",
                      basis: "Measured against a fixed catalogue entry for that kind "
                           + "of device \u{2014} a mainstream card is around 90 MB/s, "
                           + "a mainstream drive 550 MB/s. Deliberately not the entry "
                           + "nearest this device's own rate: a yardstick chosen by "
                           + "the measurement always reports about 100%."),
            Statement(inferred: true, claim: "\u{201C}slower than a modern card manages\u{201D}",
                      basis: "Only after half a gigabyte has actually moved, and it "
                           + "names the peak and the volume it saw. A fast card "
                           + "reading a tree of small files looks exactly like a slow "
                           + "card reading one large one."),
            Statement(inferred: true, claim: "\u{201C}peak is consistent with X's ceiling\u{201D}",
                      basis: "A rate that lands near a known medium's limit. Equally "
                           + "consistent with a slow reader, a busy machine at the far "
                           + "end, small files, or a device that has got hot."),
            Statement(inferred: false, claim: "\u{201C}Spotlight off\u{201D}",
                      basis: "A .metadata_never_index file is present on the volume. "
                           + "Whether macOS is indexing right now is not checked."),
        ]
    }

    static let width: CGFloat = 430
    private static let rowHeight: CGFloat = 36
    private static let pad: CGFloat = 22

    private let headingFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private let bodyFont = NSFont.systemFont(ofSize: 11.5)
    private let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private let detailFont = NSFont.systemFont(ofSize: 11)
    private let markFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private let sectionFont = NSFont.systemFont(ofSize: 10, weight: .semibold)

    let mode: Mode

    init(mode: Mode) {
        self.mode = mode
        super.init(frame: NSRect(x: 0, y: 0, width: LegendView.width, height: 10))
        frame.size.height = fittingHeight
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private var textWidth: CGFloat { LegendView.width - LegendView.pad * 2 }
    /// The claim's column; the basis wraps under it.
    private var basisLeft: CGFloat { LegendView.pad + 26 }
    private var basisWidth: CGFloat { LegendView.width - basisLeft - LegendView.pad }

    /// Measured exactly the way it is drawn, so the panel is never a few points short.
    var fittingHeight: CGFloat {
        var y = LegendView.pad
        switch mode {
        case .colors:
            y += 18 + CGFloat(LegendView.entries.count) * LegendView.rowHeight
        case .inference:
            let intro = LegendView.introText
            y += Text.wrappedHeight(intro, font: bodyFont, width: textWidth) + 18
            for statement in LegendView.statements {
                y += Text.wrappedHeight(statement.claim, font: titleFont, width: basisWidth) + 2
                y += Text.wrappedHeight(statement.basis, font: detailFont, width: basisWidth) + 14
            }
        }
        return y + LegendView.pad
    }

    static let introText =
        "Most of this window is measured: bytes moved, how full a volume is, the rate "
        + "a link negotiated. The rest is worked out by comparing those measurements "
        + "against a catalogue of what hardware normally does, and is marked \u{2248}. "
        + "A match is not a proof, so here is what each conclusion actually rests on."

    override func draw(_ dirtyRect: NSRect) {
        Palette.canvas.setFill()
        Palette.paintable(dirty: dirtyRect, bounds: bounds).fill()
        switch mode {
        case .colors: drawColors()
        case .inference: drawInference()
        }
    }

    private func drawColors() {
        let left = LegendView.pad
        var y = LegendView.pad
        Text.draw("THE COLORS", at: NSPoint(x: left, y: y),
                  font: sectionFont, color: Palette.faint, tracking: 0.8)
        y += 18

        for entry in LegendView.entries {
            var x = left
            for colour in entry.swatches {
                colour.setFill()
                let width: CGFloat = entry.swatches.count > 1 ? 8 : 24
                NSBezierPath(roundedRect: NSRect(x: x, y: y + 7, width: width, height: 16),
                             xRadius: 3, yRadius: 3).fill()
                x += width + 2
            }
            if !entry.mark.isEmpty {
                Text.draw(entry.mark, at: NSPoint(x: left + 32, y: y + 7),
                          font: markFont, color: Palette.inferred)
            }
            Text.draw(entry.title, at: NSPoint(x: left + 54, y: y + 3),
                      font: titleFont, color: NSColor.labelColor)
            Text.draw(entry.detail, at: NSPoint(x: left + 54, y: y + 19),
                      font: detailFont, color: Palette.faint)
            y += LegendView.rowHeight
        }
    }

    private func drawInference() {
        let left = LegendView.pad
        var y = LegendView.pad
        let introHeight = Text.wrappedHeight(LegendView.introText, font: bodyFont,
                                             width: textWidth)
        Text.drawWrapped(LegendView.introText,
                         in: NSRect(x: left, y: y, width: textWidth, height: introHeight),
                         font: bodyFont, color: Palette.faint)
        y += introHeight + 18

        for statement in LegendView.statements {
            // The mark in the margin, so the two kinds can be told apart down the
            // left edge without reading a word of it.
            if statement.inferred {
                Text.draw("\u{2248}", at: NSPoint(x: left, y: y),
                          font: markFont, color: Palette.inferred)
            } else {
                Palette.down.setFill()
                NSBezierPath(ovalIn: NSRect(x: left + 3, y: y + 5, width: 7, height: 7)).fill()
            }
            let claimHeight = Text.wrappedHeight(statement.claim, font: titleFont,
                                                 width: basisWidth)
            Text.drawWrapped(statement.claim,
                             in: NSRect(x: basisLeft, y: y, width: basisWidth, height: claimHeight),
                             font: titleFont,
                             color: statement.inferred ? Palette.inferred : NSColor.labelColor)
            y += claimHeight + 2
            let basisHeight = Text.wrappedHeight(statement.basis, font: detailFont,
                                                 width: basisWidth)
            Text.drawWrapped(statement.basis,
                             in: NSRect(x: basisLeft, y: y, width: basisWidth, height: basisHeight),
                             font: detailFont, color: Palette.faint)
            y += basisHeight + 14
        }
    }
}

/// One window per panel, reused, so pressing a button twice does not stack copies.
enum LegendWindow {
    private static var windows: [LegendView.Mode: NSWindowController] = [:]

    static func show(_ mode: LegendView.Mode) {
        if let existing = windows[mode] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = LegendView(mode: mode)
        let window = NSWindow(contentRect: view.frame,
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = mode == .colors ? "Color Key" : "How Limen Infers"
        window.contentView = view
        // Over the window it explains rather than the middle of the display: a panel
        // that opens on another screen is a panel you have to go and find.
        if let main = NSApp.mainWindow {
            let frame = main.frame
            window.setFrameOrigin(NSPoint(x: frame.midX - LegendView.width / 2,
                                          y: frame.midY - view.frame.height / 2))
        } else {
            window.center()
        }
        window.isReleasedWhenClosed = false
        let holder = NSWindowController(window: window)
        windows[mode] = holder
        holder.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
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
    /// Two questions, two buttons. The key answers "what does this color mean"; the
    /// information button answers "how does Limen know that", which is a different
    /// question and the one that decides whether to believe any of it.
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
        infoButton.image = Icons.infoImage()
        infoButton.imagePosition = .imageOnly
        infoButton.title = ""
        infoButton.toolTip = "How Limen infers: every conclusion it draws, and what "
            + "each one is based on."


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

    @objc func showLegend(_ sender: Any?) { LegendWindow.show(.colors) }

    @objc func showInferenceHelp(_ sender: Any?) { LegendWindow.show(.inference) }

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
                       width: toggleSize.width, height: toggleSize.height) - 16
        // The key sits with the other controls rather than alone in the far corner,
        // and at their height: a button two points shorter than its neighbours reads
        // as misaligned even when it is perfectly centred.
        cursor = place(infoButton, rightOf: cursor, width: 30, height: 24) - 6
        _ = place(legendButton, rightOf: cursor,
                  width: max(92, legendButton.fittingSize.width + 16), height: 24)

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

    @objc func showLegend(_ sender: Any?) { LegendWindow.show(.colors) }

    @objc func showInferenceHelp(_ sender: Any?) { LegendWindow.show(.inference) }

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
