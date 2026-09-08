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
        drawPanel(title: "NETWORK", tint: Palette.up,
                  down: netDown, up: netUp, downHist: netDownHist, upHist: netUpHist,
                  in: NSRect(x: 16, y: bounds.minY, width: width, height: bounds.height))
        drawPanel(title: "USB", tint: Palette.down,
                  down: usbDown, up: usbUp, downHist: usbDownHist, upHist: usbUpHist,
                  in: NSRect(x: 16 + width + gap, y: bounds.minY, width: width, height: bounds.height))

        // A hairline between the two so they read as separate measurements.
        Palette.hairline.setFill()
        NSRect(x: 16 + width + gap / 2, y: bounds.minY + 14,
               width: 1, height: bounds.height - 28).fill()
    }

    private func drawPanel(title: String, tint: NSColor, down: Double, up: Double,
                           downHist: [Double], upHist: [Double], in rect: NSRect) {
        let labelFont = NSFont.systemFont(ofSize: 9.5, weight: .bold)
        let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 21, weight: .medium)
        let smallFont = NSFont.systemFont(ofSize: 10.5)
        let top = rect.maxY - 16

        Text.draw(title, at: NSPoint(x: rect.minX, y: top - 11), font: labelFont, color: tint)

        Text.draw("\u{25BE} " + Fmt.rate(down, unit: unit),
                  at: NSPoint(x: rect.minX, y: top - 40), font: rateFont, color: Palette.down)
        Text.draw("\u{25B4} " + Fmt.rate(up, unit: unit),
                  at: NSPoint(x: rect.minX, y: top - 66), font: rateFont, color: Palette.up)

        let combined = down + up
        if combined > 0 {
            var bits: [String] = []
            let near = Reference.comparison(bytesPerSec: combined)
            if !near.isEmpty { bits.append(near) }
            let oneGB = Reference.timeToMove(bytes: Reference.oneGigabyte, atBytesPerSec: combined)
            if !oneGB.isEmpty { bits.append("1 GB in " + oneGB) }
            Text.draw(Text.clip(bits.joined(separator: "   ·   "), font: smallFont, maxWidth: rect.width - 8),
                      at: NSPoint(x: rect.minX, y: rect.minY + 8),
                      font: smallFont, color: NSColor.tertiaryLabelColor)
        }

        let chartLeft = rect.minX + 168
        let chartRect = NSRect(x: chartLeft, y: rect.minY + 26,
                               width: max(0, rect.maxX - chartLeft), height: rect.height - 46)
        if chartRect.width > 30 {
            Chart.draw(down: downHist, up: upHist, in: chartRect, lineWidth: 1.4)
        }
    }
}

final class RootView: NSView {
    let modeControl = NSSegmentedControl(labels: ["All", "Network", "USB"],
                                         trackingMode: .selectOne,
                                         target: nil,
                                         action: nil)
    let unitControl = NSSegmentedControl(labels: ["B/s", "bit/s"],
                                         trackingMode: .selectOne,
                                         target: nil,
                                         action: nil)
    let intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let inactiveToggle = NSButton(checkboxWithTitle: "Show all", target: nil, action: nil)
    let summary = SummaryView()
    let scrollView = NSScrollView()
    let list = TrafficListView()

    private let headerHeight: CGFloat = 46
    private let summaryHeight: CGFloat = 120

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true

        modeControl.selectedSegment = 0
        unitControl.selectedSegment = 0
        intervalPopup.addItems(withTitles: ["0.5 s", "1 s", "2 s", "5 s"])
        intervalPopup.selectItem(at: 1)
        intervalPopup.bezelStyle = .rounded

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = list

        addSubview(modeControl)
        addSubview(unitControl)
        addSubview(intervalPopup)
        addSubview(inactiveToggle)
        addSubview(summary)
        addSubview(scrollView)
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        Palette.hairline.setFill()
        NSRect(x: 0, y: bounds.maxY - headerHeight, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.maxY - headerHeight - summaryHeight, width: bounds.width, height: 1).fill()
    }

    override func layout() {
        super.layout()
        let top = bounds.maxY

        let modeSize = modeControl.fittingSize
        modeControl.frame = NSRect(x: 16,
                                   y: top - headerHeight + (headerHeight - modeSize.height) / 2,
                                   width: modeSize.width,
                                   height: modeSize.height)

        let unitSize = unitControl.fittingSize
        unitControl.frame = NSRect(x: bounds.maxX - 16 - unitSize.width,
                                   y: top - headerHeight + (headerHeight - unitSize.height) / 2,
                                   width: unitSize.width,
                                   height: unitSize.height)

        let popupSize = NSSize(width: 78, height: 24)
        intervalPopup.frame = NSRect(x: unitControl.frame.minX - 10 - popupSize.width,
                                     y: top - headerHeight + (headerHeight - popupSize.height) / 2,
                                     width: popupSize.width,
                                     height: popupSize.height)

        let toggleSize = inactiveToggle.fittingSize
        inactiveToggle.frame = NSRect(x: intervalPopup.frame.minX - 12 - toggleSize.width,
                                      y: top - headerHeight + (headerHeight - toggleSize.height) / 2,
                                      width: toggleSize.width,
                                      height: toggleSize.height)

        summary.frame = NSRect(x: 0,
                               y: top - headerHeight - summaryHeight,
                               width: bounds.width,
                               height: summaryHeight)

        scrollView.frame = NSRect(x: 0,
                                  y: 0,
                                  width: bounds.width,
                                  height: max(0, bounds.height - headerHeight - summaryHeight - 1))

        var listFrame = list.frame
        listFrame.size.width = scrollView.contentView.bounds.width
        listFrame.size.height = max(CGFloat(list.rows.count) * TrafficListView.rowHeight,
                                    scrollView.contentView.bounds.height)
        list.frame = listFrame
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
        window.minSize = NSSize(width: 760, height: 420)
        window.contentView = root
        window.center()
        window.setFrameAutosaveName("LimenWindow")
        window.makeKeyAndOrderFront(nil)

        root.modeControl.target = self
        root.modeControl.action = #selector(controlChanged)
        root.unitControl.target = self
        root.unitControl.action = #selector(controlChanged)
        root.intervalPopup.target = self
        root.intervalPopup.action = #selector(intervalChanged)
        root.inactiveToggle.target = self
        root.inactiveToggle.action = #selector(inactiveChanged)

        // Set the initial selection after the controls are wired up. Assigning it during view
        // construction did not stick, and the app opened on the USB tab.
        root.modeControl.selectedSegment = 0   // All
        root.unitControl.selectedSegment = 0
        root.inactiveToggle.state = .off
        monitor.showInactive = false

        monitor.onUpdate = { [weak self] in self?.refresh() }
        monitor.start()
        refresh()

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func controlChanged() {
        refresh()
    }

    @objc private func intervalChanged() {
        let intervals: [TimeInterval] = [0.5, 1, 2, 5]
        let index = min(max(0, root.intervalPopup.indexOfSelectedItem), intervals.count - 1)
        monitor.interval = intervals[index]
    }

    @objc private func inactiveChanged() {
        monitor.showInactive = root.inactiveToggle.state == .on
        refresh()
    }

    private func refresh() {
        let unit: RateUnit = root.unitControl.selectedSegment == 1 ? .bits : .bytes
        let mode = root.modeControl.selectedSegment

        root.list.unit = unit
        root.summary.unit = unit

        // The summary always reports both, whatever the list is filtered to: the
        // point is watching one against the other.
        root.summary.netDown = monitor.totalDown
        root.summary.netUp = monitor.totalUp
        root.summary.netDownHist = monitor.totalDownHist
        root.summary.netUpHist = monitor.totalUpHist
        root.summary.usbDown = monitor.usbTotalDown
        root.summary.usbUp = monitor.usbTotalUp
        root.summary.usbDownHist = monitor.usbDownHist
        root.summary.usbUpHist = monitor.usbUpHist

        switch mode {
        case 1:
            root.list.rows = monitor.networkRows
            root.list.emptyMessage = "No active interfaces"
        case 2:
            root.list.rows = monitor.usbRows
            root.list.emptyMessage = "No USB devices connected"
        default:
            root.list.rows = monitor.combinedRows
            root.list.emptyMessage = "Nothing active"
        }

        root.summary.needsDisplay = true
        root.needsLayout = true
    }
}
