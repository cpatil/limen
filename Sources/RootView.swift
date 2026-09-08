import Cocoa

/// The large "current throughput" panel above the list.
final class SummaryView: NSView {
    var downRate: Double = 0
    var upRate: Double = 0
    var downHist: [Double] = []
    var upHist: [Double] = []
    var unit: RateUnit = .bytes
    var caption = ""

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let bigFont = NSFont.monospacedDigitSystemFont(ofSize: 26, weight: .medium)
        let labelFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let captionFont = NSFont.systemFont(ofSize: 11)

        let top = bounds.maxY - 16

        Text.draw("DOWNLOAD", at: NSPoint(x: 16, y: top - 12), font: labelFont, color: Palette.down)
        Text.draw(Fmt.rate(downRate, unit: unit),
                  at: NSPoint(x: 16, y: top - 44),
                  font: bigFont,
                  color: NSColor.labelColor)

        let upX: CGFloat = 190
        Text.draw("UPLOAD", at: NSPoint(x: upX, y: top - 12), font: labelFont, color: Palette.up)
        Text.draw(Fmt.rate(upRate, unit: unit),
                  at: NSPoint(x: upX, y: top - 44),
                  font: bigFont,
                  color: NSColor.labelColor)

        let chartLeft: CGFloat = 380

        // What this rate is comparable to, and a tangible sense of scale. A bare
        // "412 MB/s" is hard to judge; "= USB 3.0 ceiling, 1 GB in 2.5 s" is not.
        let combined = downRate + upRate
        if combined > 0 {
            var bits: [String] = []
            let near = Reference.comparison(bytesPerSec: combined)
            if !near.isEmpty { bits.append(near) }
            let oneGB = Reference.timeToMove(bytes: Reference.oneGigabyte, atBytesPerSec: combined)
            if !oneGB.isEmpty { bits.append("1 GB in " + oneGB) }
            Text.draw(bits.joined(separator: "   ·   "),
                      at: NSPoint(x: 16, y: top - 72),
                      font: NSFont.systemFont(ofSize: 12, weight: .medium),
                      color: NSColor.secondaryLabelColor)
        }

        if !caption.isEmpty {
            // Clip rather than let a long caption run underneath the graph.
            Text.draw(Text.clip(caption, font: captionFont, maxWidth: chartLeft - 32),
                      at: NSPoint(x: 16, y: bounds.minY + 10),
                      font: captionFont,
                      color: NSColor.tertiaryLabelColor)
        }

        let chartRect = NSRect(x: chartLeft,
                               y: bounds.minY + 12,
                               width: max(0, bounds.width - chartLeft - 16),
                               height: bounds.height - 26)
        if chartRect.width > 20 {
            Chart.draw(down: downHist, up: upHist, in: chartRect, lineWidth: 1.5)
        }
    }
}

final class RootView: NSView {
    let modeControl = NSSegmentedControl(labels: ["Network", "USB"],
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
        root.modeControl.selectedSegment = 0
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
        let isUSB = root.modeControl.selectedSegment == 1

        root.list.unit = unit
        root.summary.unit = unit

        if isUSB {
            root.list.rows = monitor.usbRows
            root.list.emptyMessage = "No USB devices connected"
            root.summary.downRate = monitor.usbTotalDown
            root.summary.upRate = monitor.usbTotalUp
            root.summary.downHist = monitor.usbDownHist
            root.summary.upHist = monitor.usbUpHist
            root.summary.caption = "Storage and network devices only"
        } else {
            root.list.rows = monitor.networkRows
            root.list.emptyMessage = "No active interfaces"
            root.summary.downRate = monitor.totalDown
            root.summary.upRate = monitor.totalUp
            root.summary.downHist = monitor.totalDownHist
            root.summary.upHist = monitor.totalUpHist
            root.summary.caption = "Hardware interfaces only; tunnels excluded"
        }

        root.summary.needsDisplay = true
        root.needsLayout = true
    }
}
