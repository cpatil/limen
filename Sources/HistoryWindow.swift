import Cocoa

/// The scrollable log of past transfers.
final class HistoryView: NSView {
    static let rowHeight: CGFloat = 66

    var sessions: [TransferSession] = [] {
        didSet {
            let height = max(CGFloat(sessions.count) * HistoryView.rowHeight,
                             enclosingScrollView?.contentView.bounds.height ?? 0)
            setFrameSize(NSSize(width: frame.width, height: height))
            needsDisplay = true
        }
    }
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
        guard !sessions.isEmpty else {
            let font = NSFont.systemFont(ofSize: 13)
            Text.draw("No transfers recorded yet.", at: NSPoint(x: 20, y: 24),
                      font: font, color: NSColor.tertiaryLabelColor)
            return
        }

        let nameFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let metaFont = NSFont.systemFont(ofSize: 11)
        let numFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let bigFont = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)

        for (index, s) in sessions.enumerated() {
            let rect = NSRect(x: 0, y: CGFloat(index) * HistoryView.rowHeight,
                              width: bounds.width, height: HistoryView.rowHeight)
            guard rect.intersects(dirtyRect) else { continue }

            if index % 2 == 1 {
                Palette.rowAlt.setFill()
                rect.fill()
            }
            Palette.hairline.setFill()
            NSRect(x: 12, y: rect.maxY - 1, width: rect.width - 24, height: 1).fill()

            let right = rect.maxX - 16
            Icons.draw(s.section == "USB" ? .hardDisk : .ethernet,
                       in: NSRect(x: 16, y: rect.minY + 12, width: 18, height: 18),
                       color: NSColor.secondaryLabelColor)

            Text.draw(Text.clip(s.device, font: nameFont, maxWidth: 230),
                      at: NSPoint(x: 44, y: rect.minY + 10), font: nameFont, color: NSColor.labelColor)

            var meta = HistoryView.clock.string(from: s.started) + "  ·  " + duration(s.duration)
            if !s.volumes.isEmpty { meta += "  ·  " + s.volumes.joined(separator: ", ") }
            Text.draw(Text.clip(meta, font: metaFont, maxWidth: 300),
                      at: NSPoint(x: 44, y: rect.minY + 30), font: metaFont, color: NSColor.secondaryLabelColor)

            if !s.processes.isEmpty {
                Text.draw(Text.clip(s.processes.joined(separator: ", "), font: metaFont, maxWidth: 300),
                          at: NSPoint(x: 44, y: rect.minY + 46),
                          font: metaFont, color: NSColor.tertiaryLabelColor)
            }

            // Right side: how much, how fast, and how close to the link's ceiling.
            Text.draw(Fmt.bytes(Double(s.total)),
                      at: NSPoint(x: 0, y: rect.minY + 10), font: bigFont,
                      color: NSColor.labelColor, alignRight: right)
            Text.draw("avg " + Fmt.rate(s.averageRate, unit: unit)
                        + "   peak " + Fmt.rate(s.peakRate, unit: unit),
                      at: NSPoint(x: 0, y: rect.minY + 30), font: numFont,
                      color: NSColor.secondaryLabelColor, alignRight: right)

            let inTag = s.section == "USB" ? "R" : "IN"
            let outTag = s.section == "USB" ? "W" : "OUT"
            var tail = inTag + " " + Fmt.bytes(Double(s.bytesRead))
                + "  " + outTag + " " + Fmt.bytes(Double(s.bytesWritten))
            if let used = Reference.utilization(bytesPerSec: s.peakRate, linkBits: s.linkBits),
               Reference.linkRateIsCredible(observedBytesPerSec: s.peakRate, linkBits: s.linkBits) {
                tail += String(format: "   ·   peak %.0f%% of link", used * 100)
            }
            Text.draw(tail, at: NSPoint(x: 0, y: rect.minY + 47), font: metaFont,
                      color: NSColor.tertiaryLabelColor, alignRight: right)
        }
    }
}
