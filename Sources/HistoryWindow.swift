import Cocoa

/// The scrollable log of past transfers.
/// One line in the log: either a group heading with its recommendation, or a session.
enum HistoryItem {
    case group(Analysis.Group, collapsed: Bool)
    case session(TransferSession)

    /// Tall enough for whatever advice it carries. Fixed heights truncated the
    /// longer recommendations, which are exactly the ones worth reading.
    func height(width: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11.5)
        let textWidth = max(80, width - 60)
        switch self {
        case .group(let g, let collapsed):
            // Folded, a group is one line: its name and its totals. The advice folds
            // away with the sessions, because the point of folding is to get a dozen
            // devices onto one screen.
            if collapsed { return 44 }
            var h: CGFloat = 34
            for text in [Analysis.recommendation(for: g), Analysis.hostNote(for: g),
                         Analysis.housekeeping(for: g)] where !text.isEmpty {
                h += Text.wrappedHeight("→ " + text, font: font, width: textWidth) + 6
            }
            let pattern = Analysis.pattern(for: g)
            if !pattern.isEmpty {
                h += Text.wrappedHeight("→ " + pattern, font: font, width: textWidth) + 6
            }
            return max(60, h + 8)
        case .session:
            return 66
        }
    }
}

/// The scrollable log of past transfers, grouped by device and volume.
final class HistoryView: NSView {
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
        items = Analysis.groups(from: sessions).flatMap { group -> [HistoryItem] in
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

    /// Act on the first click even when Limen is not the active app. This is a window
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
                label = HistoryView.clock.string(from: s.started) + ", "
                    + (s.volumes.first ?? s.device) + ", " + Fmt.bytes(Double(s.total))
                value = "average \(Fmt.rate(s.averageRate, unit: unit)), "
                    + "peak \(Fmt.rate(s.peakRate, unit: unit)). "
                    + Analysis.verdict(for: s).summary
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
        NSColor.textColor.withAlphaComponent(0.05).setFill()
        rect.fill()
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
        NSColor.secondaryLabelColor.setFill()
        tri.fill()

        Icons.draw(group.section == "Network" ? .ethernet : (group.removable ? .memoryCard : .hardDisk),
                   in: NSRect(x: 16, y: rect.minY + 10, width: 18, height: 18),
                   color: NSColor.secondaryLabelColor)

        var title = group.device
        if !group.volumes.isEmpty { title += "  ·  " + group.volumes.joined(separator: ", ") }
        Text.draw(Text.clip(title, font: nameFont, maxWidth: rect.width - 300),
                  at: NSPoint(x: 44, y: rect.minY + 9), font: nameFont, color: NSColor.labelColor)

        var summary = "\(group.sessions.count) session\(group.sessions.count == 1 ? "" : "s")"
        if group.sessions.count > HistoryView.sessionsPerGroup {
            summary += " (latest \(HistoryView.sessionsPerGroup))"
        }
        summary += "  ·  " + Fmt.bytes(Double(group.total))
            + "  ·  best " + Fmt.rate(group.bestPeak, unit: unit)
        Text.draw(summary, at: NSPoint(x: 0, y: rect.minY + 11), font: metaFont,
                  color: NSColor.secondaryLabelColor, alignRight: rect.maxX - 16)

        // The recommendation belongs to the hardware, so it is said once per group
        // rather than repeated against every copy.
        guard !collapsed else { return }

        let textWidth = max(80, rect.width - 60)
        var y = rect.minY + 30
        for (text, colour) in [(Analysis.recommendation(for: group), NSColor.systemBlue),
                               (Analysis.hostNote(for: group), NSColor.systemTeal),
                               (Analysis.housekeeping(for: group), NSColor.systemYellow),
                               (Analysis.pattern(for: group), NSColor.systemOrange)]
                where !text.isEmpty {
            let line = "→ " + text
            let h = Text.wrappedHeight(line, font: adviceFont, width: textWidth)
            Text.drawWrapped(line, in: NSRect(x: 44, y: y, width: textWidth, height: h),
                             font: adviceFont, color: colour)
            y += h + 6
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

        var line = HistoryView.clock.string(from: s.started) + "  ·  " + duration(s.duration)
        // Repeat the volume here: the group heading scrolls away, and "which card was
        // that" is the first thing you want from a row.
        if !s.volumes.isEmpty { line += "  ·  " + s.volumes.joined(separator: ", ") }
        Text.draw(Text.clip(line, font: nameFont, maxWidth: rect.width - 330),
                  at: NSPoint(x: 44, y: rect.minY + 9), font: nameFont, color: NSColor.labelColor)

        // Did it go as fast as it could have, and if not, what stopped it.
        let verdict = Analysis.verdict(for: s)
        Text.draw(Text.clip(verdict.summary, font: metaFont, maxWidth: rect.width - 330),
                  at: NSPoint(x: 44, y: rect.minY + 28), font: metaFont,
                  color: verdict.maximised ? NSColor.systemGreen : NSColor.secondaryLabelColor)

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
                  color: NSColor.secondaryLabelColor, alignRight: right)

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
