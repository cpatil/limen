import Cocoa

/// The scrollable log of past transfers.
/// One line in the log: either a group heading with its recommendation, or a session.
enum HistoryItem {
    case group(Analysis.Group)
    case session(TransferSession)

    /// Tall enough for whatever advice it carries. Fixed heights truncated the
    /// longer recommendations, which are exactly the ones worth reading.
    func height(width: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11.5)
        let textWidth = max(80, width - 60)
        switch self {
        case .group(let g):
            var h: CGFloat = 34
            let advice = Analysis.recommendation(for: g)
            if !advice.isEmpty {
                h += Text.wrappedHeight("→ " + advice, font: font, width: textWidth) + 6
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
        didSet {
            // Cap the rows per group. One busy interface can accumulate dozens of
            // short sessions, and without a limit it pushes every other device off
            // the bottom - which is how a card reader's log became unreachable.
            items = Analysis.groups(from: sessions).flatMap { group -> [HistoryItem] in
                [.group(group)]
                    + group.sessions.prefix(HistoryView.sessionsPerGroup).map { HistoryItem.session($0) }
            }
            let width = enclosingScrollView?.contentView.bounds.width ?? frame.width
            let height = max(items.reduce(0) { $0 + $1.height(width: width) },
                             enclosingScrollView?.contentView.bounds.height ?? 0)
            setFrameSize(NSSize(width: frame.width, height: height))
            needsDisplay = true
        }
    }
    private(set) var items: [HistoryItem] = []
    var unit: RateUnit = .bytes

    override var isFlipped: Bool { true }

    private static let clock: DateFormatter = {
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
                      font: NSFont.systemFont(ofSize: 13), color: NSColor.tertiaryLabelColor)
            return
        }

        var y: CGFloat = 0
        for item in items {
            let rect = NSRect(x: 0, y: y, width: bounds.width, height: item.height(width: bounds.width))
            if rect.intersects(dirtyRect) {
                switch item {
                case .group(let group): draw(group: group, in: rect)
                case .session(let session): draw(session: session, in: rect)
                }
            }
            y += item.height(width: bounds.width)
        }
    }

    private func draw(group: Analysis.Group, in rect: NSRect) {
        NSColor.textColor.withAlphaComponent(0.05).setFill()
        rect.fill()
        Palette.hairline.setFill()
        NSRect(x: 0, y: rect.minY, width: rect.width, height: 1).fill()

        let nameFont = NSFont.systemFont(ofSize: 13, weight: .bold)
        let metaFont = NSFont.systemFont(ofSize: 11)
        let adviceFont = NSFont.systemFont(ofSize: 11.5)

        Icons.draw(group.section == "USB" ? (group.removable ? .memoryCard : .hardDisk) : .ethernet,
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
        let textWidth = max(80, rect.width - 60)
        var y = rect.minY + 30
        for (text, colour) in [(Analysis.recommendation(for: group), NSColor.systemBlue),
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
                      color: NSColor.tertiaryLabelColor)
        }

        Text.draw(Fmt.bytes(Double(s.total)), at: NSPoint(x: 0, y: rect.minY + 9),
                  font: bigFont, color: NSColor.labelColor, alignRight: right)
        Text.draw("avg " + Fmt.rate(s.averageRate, unit: unit)
                    + "   peak " + Fmt.rate(s.peakRate, unit: unit),
                  at: NSPoint(x: 0, y: rect.minY + 29), font: numFont,
                  color: NSColor.secondaryLabelColor, alignRight: right)

        let inTag = s.section == "USB" ? "R" : "IN"
        let outTag = s.section == "USB" ? "W" : "OUT"
        var tail = inTag + " " + Fmt.bytes(Double(s.bytesRead))
            + "  " + outTag + " " + Fmt.bytes(Double(s.bytesWritten))
        if s.linkTrusted == true,
           let used = Reference.utilization(bytesPerSec: s.peakRate, linkBits: s.linkBits) {
            tail += String(format: "   ·   peak %.0f%% of link", used * 100)
        }
        Text.draw(tail, at: NSPoint(x: 0, y: rect.minY + 46), font: metaFont,
                  color: NSColor.tertiaryLabelColor, alignRight: right)
    }
}
