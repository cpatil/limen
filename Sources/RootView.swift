import Cocoa

/// The panel above the list: network and USB reported side by side.
///
/// Deliberately not one combined figure. Copying from a card to an SMB share is
/// both USB and network traffic at once, and the useful thing is seeing the two
/// move together - a single total would hide exactly the relationship you want.
final class SummaryView: NSView {
    var netDown: Double = 0
    var netUp: Double = 0
    var netDownHist: [Double] = []
    var netUpHist: [Double] = []
    var usbDown: Double = 0
    var usbUp: Double = 0
    var usbDownHist: [Double] = []
    var usbUpHist: [Double] = []
    var unit: RateUnit = .bytes

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 18
        let width = (bounds.width - 32 - gap) / 2
        // USB first, matching the columns beneath.
        drawPanel(title: "USB", tint: Palette.down, families: [.storage],
                  down: usbDown, up: usbUp, downHist: usbDownHist, upHist: usbUpHist,
                  in: NSRect(x: 16, y: bounds.minY, width: width, height: bounds.height))
        drawPanel(title: "NETWORK", tint: Palette.up, families: [.network],
                  down: netDown, up: netUp, downHist: netDownHist, upHist: netUpHist,
                  in: NSRect(x: 16 + width + gap, y: bounds.minY, width: width, height: bounds.height))

        // A hairline between the two so they read as separate measurements.
        Palette.hairline.setFill()
        NSRect(x: 16 + width + gap / 2, y: bounds.minY + 14,
               width: 1, height: bounds.height - 28).fill()
    }

    private func drawPanel(title: String, tint: NSColor, families: [SpeedRef.Family],
                           down: Double, up: Double,
                           downHist: [Double], upHist: [Double], in rect: NSRect) {
        let labelFont = NSFont.systemFont(ofSize: 9.5, weight: .bold)
        let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .medium)
        let smallFont = NSFont.systemFont(ofSize: 10.5)
        let top = rect.maxY - 16

        Text.draw(title, at: NSPoint(x: rect.minX, y: top - 11), font: labelFont, color: tint)

        // Down and up on one line, side by side: easier to compare at a glance and
        // it frees the vertical space to set them larger.
        let downText = "\u{25BE} " + Fmt.rate(down, unit: unit)
        let upText = "\u{25B4} " + Fmt.rate(up, unit: unit)
        let rateY = top - 48
        Text.draw(downText, at: NSPoint(x: rect.minX, y: rateY), font: rateFont, color: Palette.down)
        let gapAfterDown = max(Text.width(downText, font: rateFont) + 26, 168)
        Text.draw(upText, at: NSPoint(x: rect.minX + gapAfterDown, y: rateY),
                  font: rateFont, color: Palette.up)

        let combined = down + up
        if combined > 0 {
            var bits: [String] = []
            let near = Reference.comparison(bytesPerSec: combined, families: families)
            if !near.isEmpty { bits.append(near) }
            let oneGB = Reference.timeToMove(bytes: Reference.oneGigabyte, atBytesPerSec: combined)
            if !oneGB.isEmpty { bits.append("1 GB in " + oneGB) }
            Text.draw(Text.clip(bits.joined(separator: "   ·   "), font: smallFont, maxWidth: rect.width - 8),
                      at: NSPoint(x: rect.minX, y: rect.minY + 8),
                      font: smallFont, color: NSColor.tertiaryLabelColor)
        }

        let chartRect = NSRect(x: rect.minX, y: rect.minY + 26,
                               width: rect.width, height: max(0, rect.height - 78))
        if chartRect.width > 30 {
            Chart.draw(down: downHist, up: upHist, in: chartRect, lineWidth: 1.4)
        }
    }
}

final class RootView: NSView, NSSplitViewDelegate {
    let usbList = TrafficListView()
    let netList = TrafficListView()
    private lazy var usbColumn = ColumnView(title: "USB", tint: Palette.down, list: usbList)
    private lazy var netColumn = ColumnView(title: "NETWORK", tint: Palette.up, list: netList)
    let splitView = NSSplitView()
    private let magnifier = MagnifierView()

    let sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let unitControl = NSSegmentedControl(labels: ["B/s", "bit/s"],
                                         trackingMode: .selectOne,
                                         target: nil,
                                         action: nil)
    let intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let inactiveToggle = NSButton(checkboxWithTitle: "Show all", target: nil, action: nil)
    let summary = SummaryView()

    private let headerHeight: CGFloat = 46
    private let summaryHeight: CGFloat = 116

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
        static let sort = "SortOrder"
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

        sortPopup.addItems(withTitles: [Monitor.SortOrder.activeFirst.title,
                                        Monitor.SortOrder.name.title,
                                        Monitor.SortOrder.rate.title,
                                        Monitor.SortOrder.total.title])
        sortPopup.selectItem(at: UserDefaults.standard.integer(forKey: Pref.sort))
        sortPopup.bezelStyle = .rounded
        sortPopup.toolTip = "How both lists are ordered.\n\n"
            + "Active first keeps whatever is moving data at the top, without "
            + "reshuffling every second the way ordering by rate does."
        inactiveToggle.state = UserDefaults.standard.bool(forKey: Pref.showAll) ? .on : .off
        inactiveToggle.toolTip = "Include things that are idle or not real hardware.\n\n"
            + "Normally the lists show physical devices plus anything currently moving "
            + "data. Turning this on also reveals loopback, VPN tunnels, bridges and "
            + "other virtual interfaces, and USB hubs with nothing attached."

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        // AppKit persists the divider position under this name, so the split you
        // choose survives relaunching.
        splitView.autosaveName = "LimenColumns"
        splitView.addArrangedSubview(usbColumn)
        splitView.addArrangedSubview(netColumn)

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
        }

        addSubview(splitView)
        addSubview(magnifier)
        addSubview(sortPopup)
        addSubview(unitControl)
        addSubview(intervalPopup)
        addSubview(inactiveToggle)
        addSubview(summary)
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        Palette.hairline.setFill()
        NSRect(x: 0, y: bounds.maxY - headerHeight, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.maxY - headerHeight - summaryHeight,
               width: bounds.width, height: 1).fill()
    }

    // Keep either column from being dragged away entirely.
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        260
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(260, splitView.bounds.width - 260)
    }

    private func showMagnifier(row: Row?, zone: MagnifierView.Zone,
                               details: String, at windowPoint: NSPoint) {
        guard let row = row else {
            magnifier.isHidden = true
            return
        }
        magnifier.row = row
        magnifier.zone = zone
        magnifier.details = details
        magnifier.unit = usbList.unit
        let local = convert(windowPoint, from: nil)
        let size = MagnifierView.size
        // Keep it beside the pointer but always fully on screen.
        var x = local.x + 24
        if x + size.width > bounds.maxX - 8 { x = local.x - size.width - 24 }
        var y = local.y - size.height / 2
        y = min(max(8, y), max(8, bounds.maxY - size.height - 8))
        magnifier.frame = NSRect(x: max(8, x), y: y, width: size.width, height: size.height)
        magnifier.isHidden = false
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
        cursor = place(inactiveToggle, rightOf: cursor, width: toggleSize.width, height: toggleSize.height) - 12
        _ = place(sortPopup, rightOf: cursor, width: 130, height: 24)

        summary.frame = NSRect(x: 0, y: top - headerHeight - summaryHeight,
                               width: bounds.width, height: summaryHeight)
        splitView.frame = NSRect(x: 0, y: 0, width: bounds.width,
                                 height: max(0, top - headerHeight - summaryHeight - 1))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let root = RootView(frame: NSRect(x: 0, y: 0, width: 980, height: 660))
    private let monitor = Monitor()

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

        root.sortPopup.target = self
        root.sortPopup.action = #selector(sortChanged)
        root.unitControl.target = self
        root.unitControl.action = #selector(controlChanged)
        root.intervalPopup.target = self
        root.intervalPopup.action = #selector(intervalChanged)
        root.inactiveToggle.target = self
        root.inactiveToggle.action = #selector(inactiveChanged)

        // Adopt the persisted preferences rather than resetting them.
        monitor.showInactive = root.inactiveToggle.state == .on
        monitor.sortOrder = Monitor.SortOrder(rawValue: root.sortPopup.indexOfSelectedItem) ?? .activeFirst
        intervalChanged()

        // Fill the catalogue from the copy inside the binary. No network: the app
        // never contacts anything unless the user explicitly asks it to.
        Catalogue.seedIfMissing()
        offerUpdateIfDue()

        monitor.onUpdate = { [weak self] in self?.refresh() }
        monitor.start()
        refresh()

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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

    @objc private func sortChanged() {
        UserDefaults.standard.set(root.sortPopup.indexOfSelectedItem, forKey: "SortOrder")
        monitor.sortOrder = Monitor.SortOrder(rawValue: root.sortPopup.indexOfSelectedItem)
            ?? .activeFirst
        refresh()
    }

    @objc private func intervalChanged() {
        UserDefaults.standard.set(root.intervalPopup.indexOfSelectedItem, forKey: "Interval")
        let intervals: [TimeInterval] = [0.5, 1, 2, 5]
        let index = min(max(0, root.intervalPopup.indexOfSelectedItem), intervals.count - 1)
        monitor.interval = intervals[index]
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
        root.summary.unit = unit

        root.summary.netDown = monitor.totalDown
        root.summary.netUp = monitor.totalUp
        root.summary.netDownHist = monitor.totalDownHist
        root.summary.netUpHist = monitor.totalUpHist
        root.summary.usbDown = monitor.usbTotalDown
        root.summary.usbUp = monitor.usbTotalUp
        root.summary.usbDownHist = monitor.usbDownHist
        root.summary.usbUpHist = monitor.usbUpHist

        root.usbList.rows = monitor.usbRows
        root.usbList.emptyMessage = "No USB devices connected"
        root.netList.rows = monitor.networkRows
        root.netList.emptyMessage = "No active interfaces"

        root.summary.needsDisplay = true
        root.needsLayout = true
    }
}
