import Cocoa

/// What a row is, well enough to draw it.
enum IconKind {
    case hardDisk, memoryCard, hub, wifi, ethernet, loopback, tunnel

    /// Chosen from what the device reports, not from its name: removable media means
    /// a card in a reader, a fixed medium behind a USB bridge means a drive.
    static func forUSB(hasDisks: Bool, removableMedia: Bool, hasInterfaces: Bool) -> IconKind {
        if hasInterfaces { return .ethernet }
        if hasDisks { return removableMedia ? .memoryCard : .hardDisk }
        return .hub
    }

    static func forInterface(name: String, wireless: Bool) -> IconKind {
        if wireless { return .wifi }
        if name.hasPrefix("lo") { return .loopback }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { return .tunnel }
        return .ethernet
    }
}

enum Icons {
    /// Draws the glyph inside `rect`, in a single colour so it sits quietly beside the
    /// text rather than competing with the charts.
    static func draw(_ kind: IconKind, in rect: NSRect, color: NSColor) {
        color.setStroke()
        color.setFill()
        let line: CGFloat = 1.4

        switch kind {
        case .hardDisk:
            // A drive: rounded body with a platter spindle and an activity notch.
            let body = rect.insetBy(dx: 1, dy: 3.5)
            let path = NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3)
            path.lineWidth = line
            path.stroke()
            let spindle = NSRect(x: body.midX - 2.6, y: body.midY - 2.6, width: 5.2, height: 5.2)
            NSBezierPath(ovalIn: spindle).stroke()
            NSBezierPath(ovalIn: spindle.insetBy(dx: 1.7, dy: 1.7)).fill()

        case .memoryCard:
            // An SD/microSD card: body with the clipped corner and contact pins.
            let body = rect.insetBy(dx: 3, dy: 1.5)
            let notch: CGFloat = 4
            let card = NSBezierPath()
            card.move(to: NSPoint(x: body.minX, y: body.minY))
            card.line(to: NSPoint(x: body.maxX, y: body.minY))
            card.line(to: NSPoint(x: body.maxX, y: body.maxY))
            card.line(to: NSPoint(x: body.minX + notch, y: body.maxY))
            card.line(to: NSPoint(x: body.minX, y: body.maxY - notch))
            card.close()
            card.lineWidth = line
            card.stroke()
            for i in 0..<3 {
                let x = body.minX + 3 + CGFloat(i) * 3.2
                NSRect(x: x, y: body.maxY - 6, width: 1.6, height: 3.4).fill()
            }

        case .hub:
            // A chip: body with legs down each side.
            let body = rect.insetBy(dx: 3.5, dy: 3.5)
            let path = NSBezierPath(roundedRect: body, xRadius: 2, yRadius: 2)
            path.lineWidth = line
            path.stroke()
            for i in 0..<3 {
                let y = body.minY + 2 + CGFloat(i) * 4
                NSRect(x: rect.minX + 0.5, y: y, width: 3, height: 1.3).fill()
                NSRect(x: body.maxX, y: y, width: 3, height: 1.3).fill()
            }

        case .wifi:
            // Three arcs over a dot.
            let centre = NSPoint(x: rect.midX, y: rect.minY + 3)
            for (index, radius) in [4.0, 7.5, 11.0].enumerated() {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: centre, radius: CGFloat(radius),
                              startAngle: 35, endAngle: 145)
                arc.lineWidth = index == 0 ? line + 0.3 : line
                arc.stroke()
            }
            NSBezierPath(ovalIn: NSRect(x: centre.x - 1.5, y: centre.y - 1.5,
                                        width: 3, height: 3)).fill()

        case .ethernet:
            // An RJ45 plug: body with a latch on top and pins below.
            let body = NSRect(x: rect.minX + 2.5, y: rect.minY + 3,
                              width: rect.width - 5, height: rect.height - 8)
            let path = NSBezierPath(roundedRect: body, xRadius: 1.5, yRadius: 1.5)
            path.lineWidth = line
            path.stroke()
            NSRect(x: body.midX - 2, y: body.maxY, width: 4, height: 3).fill()
            for i in 0..<4 {
                NSRect(x: body.minX + 2 + CGFloat(i) * 2.6, y: body.minY - 2.5,
                       width: 1.2, height: 2.5).fill()
            }

        case .loopback:
            // A closed loop: it goes nowhere.
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
            circle.lineWidth = line
            circle.stroke()
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: rect.midX + 1, y: rect.maxY - 3.5))
            arrow.line(to: NSPoint(x: rect.midX + 4.5, y: rect.maxY - 3.5))
            arrow.line(to: NSPoint(x: rect.midX + 3, y: rect.maxY - 6))
            arrow.lineWidth = line
            arrow.stroke()

        case .tunnel:
            // An arch with a line through it.
            let arch = NSBezierPath()
            arch.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.minY + 4),
                           radius: rect.width / 2 - 2.5, startAngle: 0, endAngle: 180)
            arch.line(to: NSPoint(x: rect.minX + 2.5, y: rect.minY + 4))
            arch.lineWidth = line
            arch.stroke()
            NSRect(x: rect.minX + 1, y: rect.minY + 3.4, width: rect.width - 2, height: 1.3).fill()
        }
    }
}
