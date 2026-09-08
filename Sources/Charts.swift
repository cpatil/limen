import Cocoa

enum Palette {
    static let down = NSColor.systemGreen
    static let up = NSColor.systemBlue

    static var rowAlt: NSColor {
        NSColor.textColor.withAlphaComponent(0.03)
    }
    static var hairline: NSColor {
        NSColor.textColor.withAlphaComponent(0.10)
    }
    /// Behind the figures of a row that is actually transferring.
    static var emphasis: NSColor {
        NSColor.systemGreen.withAlphaComponent(0.13)
    }
    /// Behind the row under the pointer. Tinted rather than grey so it reads as
    /// deliberate at a glance, and subtle enough not to fight the text.
    static var hover: NSColor {
        NSColor.controlAccentColor.withAlphaComponent(0.14)
    }
}

enum Chart {
    /// Draws download (filled area) and upload (line) on a shared scale so the two are comparable.
    /// `floorMax` keeps an idle graph pinned flat at the bottom instead of amplifying noise.
    /// The value the top of the chart represents. Exposed so a chart can be labelled
    /// with its own scale - a shape with no numbers on it says nothing about size.
    static func peak(down: [Double], up: [Double], floorMax: Double = 8 * 1024) -> Double {
        max(down.max() ?? 0, up.max() ?? 0, floorMax)
    }

    static func draw(down: [Double],
                     up: [Double],
                     in rect: NSRect,
                     lineWidth: CGFloat = 1.5,
                     floorMax: Double = 8 * 1024) {
        guard rect.width > 2, rect.height > 2 else { return }

        let peak = peak(down: down, up: up, floorMax: floorMax)
        let count = max(down.count, up.count)
        guard count > 1 else { return }

        // Anchor to the right edge so new samples enter on the right and history scrolls left.
        let step = rect.width / CGFloat(Monitor.historyLength - 1)

        func point(_ series: [Double], _ index: Int) -> NSPoint {
            let value = series[index]
            let offset = CGFloat(Monitor.historyLength - series.count + index)
            let x = rect.minX + offset * step
            let normalized = peak > 0 ? CGFloat(value / peak) : 0
            let y = rect.minY + min(1, max(0, normalized)) * (rect.height - lineWidth) + lineWidth / 2
            return NSPoint(x: x, y: y)
        }

        if down.count > 1 {
            let area = NSBezierPath()
            area.move(to: NSPoint(x: point(down, 0).x, y: rect.minY))
            for i in 0..<down.count { area.line(to: point(down, i)) }
            area.line(to: NSPoint(x: point(down, down.count - 1).x, y: rect.minY))
            area.close()
            Palette.down.withAlphaComponent(0.22).setFill()
            area.fill()

            let line = NSBezierPath()
            line.lineWidth = lineWidth
            line.lineJoinStyle = .round
            line.move(to: point(down, 0))
            for i in 1..<down.count { line.line(to: point(down, i)) }
            Palette.down.setStroke()
            line.stroke()
        }

        if up.count > 1 {
            let line = NSBezierPath()
            line.lineWidth = lineWidth
            line.lineJoinStyle = .round
            line.move(to: point(up, 0))
            for i in 1..<up.count { line.line(to: point(up, i)) }
            Palette.up.setStroke()
            line.stroke()
        }
    }
}

enum Text {
    static func draw(_ string: String,
                     at point: NSPoint,
                     font: NSFont,
                     color: NSColor,
                     alignRight: CGFloat? = nil) {
        guard !string.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let attributed = NSAttributedString(string: string, attributes: attrs)
        var origin = point
        if let rightEdge = alignRight {
            origin.x = rightEdge - attributed.size().width
        }
        attributed.draw(at: origin)
    }

    /// Multi-line text inside a box, for the magnified detail panel.
    static func drawWrapped(_ string: String, in rect: NSRect, font: NSFont, color: NSColor) {
        guard !string.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 2
        NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style
        ]).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                context: nil)
    }

    static func width(_ string: String, font: NSFont) -> CGFloat {
        NSAttributedString(string: string, attributes: [.font: font]).size().width
    }

    /// Truncates with an ellipsis so long device names never collide with the chart column.
    static func clip(_ string: String, font: NSFont, maxWidth: CGFloat) -> String {
        guard width(string, font: font) > maxWidth, !string.isEmpty else { return string }
        var result = string
        while result.count > 1 && width(result + "…", font: font) > maxWidth {
            result.removeLast()
        }
        return result + "…"
    }

    static func drawBadge(_ string: String, at point: NSPoint, font: NSFont) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let padding: CGFloat = 5
        let textWidth = width(string, font: font)
        let rect = NSRect(x: point.x, y: point.y - 2, width: textWidth + padding * 2, height: font.pointSize + 6)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        Palette.hairline.setFill()
        path.fill()
        draw(string, at: NSPoint(x: point.x + padding, y: point.y + 1),
             font: font, color: NSColor.secondaryLabelColor)
        return rect.width
    }
}
