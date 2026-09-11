import Cocoa

/// The scrollable log of past transfers.
/// One line in the log: either a group heading with its recommendation, or a session.
enum HistoryItem {
    case group(Analysis.Group, collapsed: Bool)
    case session(TransferSession)

    struct Advice {
        let text: String
        let colour: NSColor
    }

    /// The heading strip: the device's name and totals, and nothing else.
    ///
    /// The raised tone used to cover the whole group - heading and every note under
    /// it - so a device with three paragraphs of advice became a large pale block and
    /// a device with none stayed a thin line. The shading then looked like a state
    /// (open? closed? selected?) rather than what it is, which is "this line names a
    /// device". Only the strip is raised now; the notes sit on the ground with the
    /// sessions they belong to.
    static let headingHeight: CGFloat = 34

    /// A readable measure, not the width of the window.
    ///
    /// These paragraphs were being wrapped to whatever the window happened to be -
    /// 1200 points of 11.5pt text, which is about 170 characters a line. Typography
    /// puts the comfortable range nearer 60 to 90; past that the eye loses the start
    /// of the next line, which is the actual reason the block was unreadable.
    static func adviceWidth(_ width: CGFloat) -> CGFloat {
        min(max(80, width - 64), 660)
    }

    /// What a group has to say about itself, in the app's own two meanings: violet
    /// for a conclusion drawn from measurements, red for something that is costing
    /// you. The four arbitrary system colours this replaced - blue, teal, yellow,
    /// orange - meant nothing, agreed with nothing else in the app, and two of them
    /// were barely visible on the log's own background.
    static func advice(for group: Analysis.Group) -> [Advice] {
        var out: [Advice] = []
        for text in [Analysis.recommendation(for: group),
                     Analysis.hostNote(for: group),
                     Analysis.pattern(for: group)] where !text.isEmpty {
            out.append(Advice(text: Palette.marked(text), colour: Palette.inferred))
        }
        // What the format is costing, where the card said what it was formatted with.
        if let block = group.sessions.compactMap({ $0.blockSize }).max() {
            let note = Analysis.allocationNote(blockSize: block, group: group)
            if !note.isEmpty {
                out.append(Advice(text: Palette.marked(note), colour: Palette.inferred))
            }
        }
        let housekeeping = Analysis.housekeeping(for: group)
        if !housekeeping.isEmpty {
            // Not marked: it opens with a measurement - so many bytes written while
            // so many were read - and only then reads it. Red is the app's colour for
            // something you are paying for and can stop.
            out.append(Advice(text: housekeeping, colour: Palette.warning))
        }
        return out
    }

    /// Tall enough for whatever advice it carries. Fixed heights truncated the
    /// longer recommendations, which are exactly the ones worth reading.
    func height(width: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11.5)
        let textWidth = HistoryItem.adviceWidth(width)
        switch self {
        case .group(let g, let collapsed):
            // Folded, a group is one line: its name and its totals. The advice folds
            // away with the sessions, because the point of folding is to get a dozen
            // devices onto one screen.
            if collapsed { return 44 }
            var h = HistoryItem.headingHeight
            let advice = HistoryItem.advice(for: g)
            if !advice.isEmpty { h += 6 }
            for note in advice {
                h += Text.wrappedHeight(note.text, font: font, width: textWidth) + 8
            }
            return max(60, h + 8)
        case .session(let s):
            // One more line when this session has a counterpart, so the route can be
            // stated on the row rather than left to be worked out by comparing
            // timestamps between two sections of the log.
            return HistoryView.routes[s.id] == nil ? 66 : 84
        }
    }
}

/// The scrollable log of past transfers, grouped by device and volume.
final class HistoryView: NSView {
    /// Which sessions are two ends of one transfer. Computed once when the log is
    /// rebuilt rather than per row: it is a pass over every session, and both the
    /// height calculation and the drawing need the same answer.
    static var routes: [String: Analysis.Route] = [:]
    /// Which groups contain sessions from more than one device, so a session can say
    /// which reader it came through only where that varies.
    static var spanningGroups: [String: Bool] = [:]

    static let rowHeight: CGFloat = 66
    /// Most recent sessions shown per device; the header states the true total.
    static let sessionsPerGroup = 5

    var sessions: [TransferSession] = [] {
        didSet { rebuild() }
    }

    /// Groups the user has folded away, by their stable key. Remembered, so a log you
    /// have tidied stays tidy across launches.
    private static let collapsedKey = "CollapsedGroups"
    private var collapsed: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: HistoryView.collapsedKey) ?? [])

    private func rebuild() {
        // Cap the rows per group. One busy interface can accumulate dozens of
        // short sessions, and without a limit it pushes every other device off
        // the bottom - which is how a card reader's log became unreachable.
        // Hidden devices sink to the bottom rather than disappearing: their sessions
        // happened, and the point of hiding a chatty tunnel is that it stops being
        // bumped to the top every time it twitches, not that its history is lost.
        HistoryView.routes = Analysis.routes(from: sessions)
        HistoryView.spanningGroups = Dictionary(
            uniqueKeysWithValues: Analysis.groups(from: sessions).map { ($0.key, $0.spansDevices) })
        items = Hidden.sink(Analysis.groups(from: sessions,
                                            records: TransferLog.shared.bestPeaks()),
                            name: { $0.device })
            .flatMap { group -> [HistoryItem] in
            let folded = collapsed.contains(group.key)
            return [.group(group, collapsed: folded)]
                + (folded ? []
                          : group.sessions.prefix(HistoryView.sessionsPerGroup).map { HistoryItem.session($0) })
        }
        let width = enclosingScrollView?.contentView.bounds.width ?? frame.width
        let height = max(items.reduce(0) { $0 + $1.height(width: width) },
                         enclosingScrollView?.contentView.bounds.height ?? 0)
        setFrameSize(NSSize(width: frame.width, height: height))
        axRows = accessibilityRowElements()
        needsDisplay = true
    }

    /// Clicking a group heading folds it. The whole heading is the target rather than
    /// just the triangle - it is a big obvious thing to hit, which matters more here
    /// than fidelity to a disclosure control.
    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard case .group(let group, _)? = item(at: local) else { return }
        if collapsed.contains(group.key) {
            collapsed.remove(group.key)
        } else {
            collapsed.insert(group.key)
        }
        UserDefaults.standard.set(Array(collapsed), forKey: HistoryView.collapsedKey)
        rebuild()
    }

    /// Folds or unfolds every group at once, for when the log has grown long.
    func setAllCollapsed(_ folded: Bool) {
        collapsed = folded ? Set(Analysis.groups(from: sessions).map { $0.key }) : []
        UserDefaults.standard.set(Array(collapsed), forKey: HistoryView.collapsedKey)
        rebuild()
    }
    private(set) var items: [HistoryItem] = []
    var unit: RateUnit = .bytes
    /// Called after the log is edited, so the pane can rebuild itself.
    var onLogChanged: (() -> Void)?

    override var isFlipped: Bool { true }

    /// Act on the first click even when Bottleneck is not the active app. This is a window
    /// you glance at while working in something else; spending a click just to focus
    /// it before you can fold a group or drag a row is a click too many.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .table }

    /// Each group and each session as its own element, so the log can be read and the
    /// advice heard rather than only seen.
    private func accessibilityRowElements() -> [NSAccessibilityElement] {
        guard let window = window else { return [] }
        var out: [NSAccessibilityElement] = []
        var y: CGFloat = 0
        for item in items {
            let height = item.height(width: bounds.width)
            let frame = NSRect(x: 0, y: y, width: max(1, bounds.width), height: height)
            var label = ""
            var value = ""
            switch item {
            case .group(let g, let collapsed):
                label = g.device
                if !g.volumes.isEmpty { label += ", " + g.volumes.joined(separator: ", ") }
                label += ", \(g.sessions.count) session\(g.sessions.count == 1 ? "" : "s")"
                label += ", \(Fmt.bytes(Double(g.total))) total"
                value = collapsed ? "collapsed" : "expanded"
                for advice in [Analysis.recommendation(for: g), Analysis.hostNote(for: g),
                               Analysis.housekeeping(for: g), Analysis.pattern(for: g)]
                        where !advice.isEmpty {
                    value += ". " + advice
                }
            case .session(let s):
                // Spoken with both, since "17 min ago" read out of context tells you
                // nothing about when that was.
                label = (Fmt.relative(s.started).map { $0 + ", " } ?? "")
                    + HistoryView.clock.string(from: s.started) + ", "
                    + (s.volumes.first ?? s.device) + ", " + Fmt.bytes(Double(s.total))
                let verdict = Analysis.verdict(for: s)
                value = "average \(Fmt.rate(s.averageRate, unit: unit)), "
                    + "peak \(Fmt.rate(s.peakRate, unit: unit)). "
                    + (verdict.inferred ? "inferred: " : "") + verdict.summary
                if let route = HistoryView.routes[s.id] {
                    value += " Inferred: " + route.summary
                }
            }
            if let element = NSAccessibilityElement.element(
                withRole: .row, frame: window.convertToScreen(convert(frame, to: nil)),
                label: label, parent: self) as? NSAccessibilityElement {
                element.setAccessibilityValue(value)
                out.append(element)
            }
            y += height
        }
        return out
    }

    private var axRows: [NSAccessibilityElement] = []

    override func accessibilityChildren() -> [Any]? {
        if axRows.count != items.count { axRows = accessibilityRowElements() }
        return axRows
    }

    override func accessibilityRows() -> [Any]? { accessibilityChildren() }

    /// The item under a point, accounting for the variable row heights.
    private func item(at point: NSPoint) -> HistoryItem? {
        var y: CGFloat = 0
        for item in items {
            let h = item.height(width: bounds.width)
            if point.y >= y && point.y < y + h { return item }
            y += h
        }
        return nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let local = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if case .group(let group, _)? = item(at: local) {
            let title = group.volumes.isEmpty ? group.device
                                              : group.device + " · " + group.volumes.joined(separator: ", ")
            let item = NSMenuItem(title: "Forget “\(title)”",
                                  action: #selector(forgetGroup(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = group
            menu.addItem(item)
            menu.addItem(NSMenuItem.separator())
        }
        let fold = NSMenuItem(title: "Fold All Devices",
                              action: #selector(foldAll(_:)), keyEquivalent: "")
        fold.target = self
        menu.addItem(fold)
        let unfold = NSMenuItem(title: "Unfold All Devices",
                                action: #selector(unfoldAll(_:)), keyEquivalent: "")
        unfold.target = self
        menu.addItem(unfold)
        menu.addItem(NSMenuItem.separator())

        let all = NSMenuItem(title: "Clear Entire Log", action: #selector(clearAll(_:)), keyEquivalent: "")
        all.target = self
        menu.addItem(all)

        // Anything this menu removes can be put back. Emptying a log that took weeks
        // to build should not depend on the user having been careful.
        if TransferLog.shared.canRestoreCleared {
            let undo = NSMenuItem(title: "Undo Last Clear",
                                  action: #selector(undoClear(_:)), keyEquivalent: "")
            undo.target = self
            menu.addItem(NSMenuItem.separator())
            menu.addItem(undo)
        }
        return menu
    }

    @objc private func forgetGroup(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? Analysis.Group else { return }
        TransferLog.shared.clear(device: group.device, volumes: group.volumes)
        onLogChanged?()
    }

    @objc private func foldAll(_ sender: NSMenuItem) { setAllCollapsed(true) }
    @objc private func unfoldAll(_ sender: NSMenuItem) { setAllCollapsed(false) }

    @objc private func undoClear(_ sender: NSMenuItem) {
        let restored = TransferLog.shared.restoreCleared()
        onLogChanged?()
        if restored == 0 {
            let alert = NSAlert()
            alert.messageText = "Nothing left to put back"
            alert.informativeText = "Those sessions are already in the log."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func clearAll(_ sender: NSMenuItem) {
        TransferLog.shared.clear()
        onLogChanged?()
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM  HH:mm"
        return f
    }()

    private func duration(_ seconds: TimeInterval) -> String {
        if seconds < 90 { return String(format: "%.0f s", seconds) }
        if seconds < 5400 { return String(format: "%.0f min", seconds / 60) }
        return String(format: "%.1f h", seconds / 3600)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !items.isEmpty else {
            Text.draw("No transfers recorded yet.", at: NSPoint(x: 20, y: 24),
                      font: NSFont.systemFont(ofSize: 13), color: Palette.faint)
            return
        }

        var y: CGFloat = 0
        for item in items {
            let rect = NSRect(x: 0, y: y, width: bounds.width, height: item.height(width: bounds.width))
            if rect.intersects(dirtyRect) {
                switch item {
                case .group(let group, let folded):
                    draw(group: group, in: rect, collapsed: folded)
                case .session(let session): draw(session: session, in: rect)
                }
            }
            y += item.height(width: bounds.width)
        }
    }

    private func draw(group: Analysis.Group, in rect: NSRect, collapsed: Bool) {
        // The strip only, not the whole group. Flipped coordinates, so this is the top.
        let band = NSRect(x: 0, y: rect.minY, width: rect.width,
                          height: min(HistoryItem.headingHeight, rect.height))
        NSColor.textColor.withAlphaComponent(0.05).setFill()
        band.fill()
        Palette.hairline.setFill()
        NSRect(x: 0, y: rect.minY, width: rect.width, height: 1).fill()

        let nameFont = NSFont.systemFont(ofSize: 13, weight: .bold)
        let metaFont = NSFont.systemFont(ofSize: 11)
        let adviceFont = NSFont.systemFont(ofSize: 11.5)

        // A disclosure triangle in the left margin, pointing down when open. It sits
        // before the icon rather than displacing it, so folding changes nothing else
        // about where the heading's parts are.
        let mid = rect.minY + 19
        let tri = NSBezierPath()
        if collapsed {
            tri.move(to: NSPoint(x: 5, y: mid - 4.5))
            tri.line(to: NSPoint(x: 11, y: mid))
            tri.line(to: NSPoint(x: 5, y: mid + 4.5))
        } else {
            tri.move(to: NSPoint(x: 4, y: mid - 2.5))
            tri.line(to: NSPoint(x: 13, y: mid - 2.5))
            tri.line(to: NSPoint(x: 8.5, y: mid + 3))
        }
        tri.close()
        Palette.secondary.setFill()
        tri.fill()

        Icons.draw(group.section == "Network" ? .ethernet : (group.removable ? .memoryCard : .hardDisk),
                   in: NSRect(x: 16, y: rect.minY + 10, width: 18, height: 18),
                   color: Palette.secondary)

        // A card is titled by the card. The readers it came through are named on the
        // sessions themselves, where the difference between them can be read off.
        var title = group.volumes.isEmpty || !group.removable ? group.device
                                                             : group.volumes.joined(separator: ", ")
        // Named where it is known. Where it is not, say so rather than showing the
        // device alone, which reads as "the reader itself" and is indistinguishable
        // from a group whose name simply did not fit.
        if group.removable, !group.volumes.isEmpty {
            // Titled by the card already: what is worth adding is which readers it
            // came through, since that is what the sessions differ by.
            if group.spansDevices {
                title += "  ·  through \(group.devices.count) readers"
            } else if let reader = group.devices.first {
                title += "  ·  " + reader
            }
        } else if !group.volumes.isEmpty {
            title += "  ·  " + group.volumes.joined(separator: ", ")
        } else if group.removable {
            // "Recorded" pointed at the bookkeeping. Volumes are filled in throughout
            // a session now, so an empty list means what it says: nothing was mounted
            // while those bytes moved.
            title += "  ·  no volume mounted"
        }
        Text.draw(Text.clip(title, font: nameFont, maxWidth: rect.width - 300),
                  at: NSPoint(x: 44, y: rect.minY + 9), font: nameFont, color: NSColor.labelColor)

        var summary = "\(group.sessions.count) session\(group.sessions.count == 1 ? "" : "s")"
        if group.sessions.count > HistoryView.sessionsPerGroup {
            summary += " (latest \(HistoryView.sessionsPerGroup))"
        }
        summary += "  ·  " + Fmt.bytes(Double(group.total))
            + "  ·  best " + Fmt.rate(group.bestPeak, unit: unit)
        Text.draw(summary, at: NSPoint(x: 0, y: rect.minY + 11), font: metaFont,
                  color: Palette.secondary, alignRight: rect.maxX - 16)

        // The recommendation belongs to the hardware, so it is said once per group
        // rather than repeated against every copy.
        guard !collapsed else { return }

        let textWidth = HistoryItem.adviceWidth(rect.width)
        var y = rect.minY + HistoryItem.headingHeight + 6
        let top = y
        for advice in HistoryItem.advice(for: group) {
            let h = Text.wrappedHeight(advice.text, font: adviceFont, width: textWidth)
            Text.drawWrapped(advice.text,
                             in: NSRect(x: 48, y: y, width: textWidth, height: h),
                             font: adviceFont, color: advice.colour)
            y += h + 8
        }
        // A rule down the left of the block, so several paragraphs read as notes
        // about this device rather than as loose text in the middle of a list.
        if y > top {
            Palette.hairline.setFill()
            NSRect(x: 40, y: top + 1, width: 2, height: y - top - 9).fill()
        }
    }

    private func draw(session s: TransferSession, in rect: NSRect) {
        Palette.hairline.setFill()
        NSRect(x: 12, y: rect.maxY - 1, width: rect.width - 24, height: 1).fill()

        let nameFont = NSFont.systemFont(ofSize: 12)
        let metaFont = NSFont.systemFont(ofSize: 11)
        let numFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let bigFont = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        let right = rect.maxX - 16

        // Relative while it is still today's business, absolute once it is history.
        let when = Fmt.relative(s.started) ?? HistoryView.clock.string(from: s.started)
        var line = when + "  ·  " + duration(s.duration)
        // Which reader this one came through, when the card has been read through
        // more than one. That difference is the whole reason for filing by card.
        if let group = HistoryView.spanningGroups[Analysis.groupKey(for: s)], group {
            line += "  ·  " + s.device
        }
        // Repeat the volume here: the group heading scrolls away, and "which card was
        // that" is the first thing you want from a row.
        if !s.volumes.isEmpty { line += "  ·  " + s.volumes.joined(separator: ", ") }
        Text.draw(Text.clip(line, font: nameFont, maxWidth: rect.width - 330),
                  at: NSPoint(x: 44, y: rect.minY + 9), font: nameFont, color: NSColor.labelColor)

        // Did it go as fast as it could have, and if not, what stopped it.
        if let route = HistoryView.routes[s.id] {
            // Marked: two unrelated transfers that overlap and move similar amounts
            // would pair, and this cannot tell them apart from one copy seen twice.
            Text.draw(Text.clip(Palette.marked(route.summary), font: metaFont,
                                maxWidth: rect.width - 330),
                      at: NSPoint(x: 44, y: rect.minY + 62), font: metaFont,
                      color: Palette.inferred)
        }

        let verdict = Analysis.verdict(for: s)
        let summary = verdict.inferred ? Palette.marked(verdict.summary) : verdict.summary
        Text.draw(Text.clip(summary, font: metaFont, maxWidth: rect.width - 330),
                  at: NSPoint(x: 44, y: rect.minY + 28), font: metaFont,
                  color: verdict.inferred ? Palette.inferred
                       : (verdict.maximised ? NSColor.systemGreen : Palette.secondary))

        if !s.processes.isEmpty {
            Text.draw(Text.clip(s.processes.joined(separator: ", "), font: metaFont, maxWidth: rect.width - 330),
                      at: NSPoint(x: 44, y: rect.minY + 45), font: metaFont,
                      color: Palette.faint)
        }

        Text.draw(Fmt.bytes(Double(s.total)), at: NSPoint(x: 0, y: rect.minY + 9),
                  font: bigFont, color: NSColor.labelColor, alignRight: right)
        Text.draw("avg " + Fmt.rate(s.averageRate, unit: unit)
                    + "   peak " + Fmt.rate(s.peakRate, unit: unit),
                  at: NSPoint(x: 0, y: rect.minY + 29), font: numFont,
                  color: Palette.secondary, alignRight: right)

        // Same rule the rows use. Testing for "USB" alone left internal drives
        // labelled IN/OUT, as though they were network interfaces.
        let inTag = s.isStorageLike ? "R" : "IN"
        let outTag = s.isStorageLike ? "W" : "OUT"
        var tail = inTag + " " + Fmt.bytes(Double(s.bytesRead))
            + "  " + outTag + " " + Fmt.bytes(Double(s.bytesWritten))
        if s.linkTrusted == true,
           let used = Reference.utilization(down: s.peakRate, up: 0, linkBits: s.linkBits) {
            tail += String(format: "   ·   peak %.0f%% link utilization", used * 100)
        }
        Text.draw(tail, at: NSPoint(x: 0, y: rect.minY + 46), font: metaFont,
                  color: Palette.faint, alignRight: right)
    }
}
