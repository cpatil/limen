import Cocoa

enum Palette {
    static let down = NSColor.systemGreen
    static let up = NSColor.systemBlue

    /// Light and dark are not mirror images. A tint at 18% over black still reads as a
    /// colour, but over white it becomes a pastel wash, and the saturated text drawn on
    /// it loses most of its contrast. Anything tuned by eye in one appearance has to be
    /// checked in the other, which is what these exist for.
    /// Set by the tests, which have no running application to ask. nil in the app.
    static var forcedAppearance: Bool?

    static var isLight: Bool {
        if let forced = forcedAppearance { return forced }
        return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
    }

    /// A section colour as heading text. Darkened on light backgrounds, where the
    /// stock system green and blue sit at roughly 2:1 against a pale band.
    static func headingText(_ tint: NSColor) -> NSColor {
        guard isLight else { return tint }
        // Darkening only helps a colour. The session log's heading is grey, and
        // darkening grey against a grey band just makes both muddy - it wants the
        // ordinary text colour instead.
        guard let rgb = tint.usingColorSpace(.sRGB), rgb.saturationComponent > 0.15 else {
            return NSColor.labelColor
        }
        return tint.blended(withFraction: 0.45, of: .black) ?? tint
    }

    /// The band behind a section heading.
    static func headingBand(_ tint: NSColor) -> NSColor {
        guard let rgb = tint.usingColorSpace(.sRGB), rgb.saturationComponent > 0.15 else {
            // A grey band has to be much lighter than a tinted one to weigh the same.
            return NSColor.labelColor.withAlphaComponent(isLight ? 0.10 : 0.14)
        }
        return tint.withAlphaComponent(isLight ? 0.24 : 0.18)
    }

    /// The dimmest text the interface uses - comparisons, totals, footnotes. On a
    /// light ground tertiaryLabelColor is about 26% black, which is legible for a
    /// disabled menu item and not for a line you are meant to read.
    static var faint: NSColor {
        NSColor.labelColor.withAlphaComponent(isLight ? 0.55 : 0.42)
    }

    /// The ground everything sits on.
    ///
    /// Nothing used to paint this: the scroll views draw no background and the lists
    /// are transparent, so the whole app inherited the window's default, which in the
    /// light appearance is very close to white. Naming it makes the tone a decision
    /// rather than something inherited, and a soft grey is easier to sit in front of
    /// for a window that stays open all day.
    static var canvas: NSColor {
        isLight ? NSColor(srgbRed: 0.902, green: 0.902, blue: 0.914, alpha: 1)
                : NSColor.windowBackgroundColor
    }

    /// A row's alternating stripe. On a grey ground it has to be a touch stronger than
    /// it needed to be on white, or the alternation disappears.
    static var rowAlt: NSColor {
        NSColor.textColor.withAlphaComponent(isLight ? 0.045 : 0.03)
    }
    static var hairline: NSColor {
        NSColor.textColor.withAlphaComponent(0.10)
    }
    /// Behind a standard's name. Enough contrast to be read at a glance, since it is
    /// the fact people look for.
    static var badge: NSColor {
        NSColor.textColor.withAlphaComponent(0.10)
    }
    static var badgeStrong: NSColor {
        NSColor.controlAccentColor.withAlphaComponent(0.22)
    }
    /// Behind the figures of a row that is actually transferring.
    static var emphasis: NSColor {
        NSColor.systemGreen.withAlphaComponent(0.13)
    }
    /// Behind the card sitting in a reader. Its own colour, because a row can carry
    /// two badges - what is being read, and the link it is read over - and they are
    /// different kinds of fact that should never be mistaken for one another.
    static var cardBadge: NSColor {
        NSColor.systemGreen.withAlphaComponent(0.30)
    }
    /// Behind a warning pill - something is costing you and can be turned off.
    static var alertBadge: NSColor {
        NSColor.systemRed.withAlphaComponent(0.22)
    }
    /// Behind a section heading. The headings divide the window, so they carry a
    /// band of their own rather than floating in the same field as the rows - which
    /// is what made them easy to miss.
    static var headerBand: NSColor {
        NSColor.textColor.withAlphaComponent(0.07)
    }
    /// A figure Limen worked out rather than read from the system.
    ///
    /// Every other colour in this app is already spoken for by something measured:
    /// green and blue are the two directions, orange is a link at its ceiling, red is
    /// a warning, and the capacity level runs green through amber to red. Violet is
    /// the one hue left, and that is exactly what makes it usable as a code - it can
    /// never be mistaken for a rate.
    ///
    /// Colour on its own is not a code. It is gone for anyone who cannot separate
    /// these hues, gone in a greyscale screenshot, and gone in the accessibility
    /// description. `mark` travels with it everywhere and carries the meaning by
    /// itself; the colour only makes it findable at a glance.
    static var inferred: NSColor {
        isLight ? NSColor(srgbRed: 0.42, green: 0.23, blue: 0.66, alpha: 1)
                : NSColor(srgbRed: 0.84, green: 0.75, blue: 1.00, alpha: 1)
    }
    /// The same colour as a fill, where it sits under text rather than being text.
    static var inferredFill: NSColor {
        inferred.withAlphaComponent(isLight ? 0.80 : 0.70)
    }
    static var inferredBadge: NSColor {
        inferred.withAlphaComponent(isLight ? 0.20 : 0.18)
    }
    /// Prefixed to anything drawn in that colour. Read aloud as "about".
    static let mark = "\u{2248} "
    /// Marks a string as inferred, so the mark and the colour are always applied
    /// together and one can never be shipped without the other.
    /// Idempotent, because some of these strings arrive already carrying the sign -
    /// "\u{2248} Gigabit Ethernet" is how a near match has always been written - and
    /// marking one twice would look like a bug rather than a code.
    static func marked(_ text: String) -> String {
        text.hasPrefix("\u{2248}") ? text : mark + text
    }

    /// Red as text, rather than as a fill.
    ///
    /// The stock system red is a control tint. As small text it measures about 2.9:1
    /// on this app's pale canvas and 3.7:1 on the dark one - both under the 4.5:1 a
    /// body of text needs, which I only found by measuring rather than by looking,
    /// because red always looks emphatic whether or not it is readable. Darkened
    /// against the light ground, lightened against the dark one.
    static var warning: NSColor {
        let base = NSColor.systemRed
        return (isLight ? base.blended(withFraction: 0.34, of: .black)
                        : base.blended(withFraction: 0.35, of: .white)) ?? base
    }

    /// What a view may actually paint, given the rect AppKit asked it to refresh.
    ///
    /// AppKit hands a subview the whole invalidated region of the window rather than
    /// the part of it that overlaps this view, and inside a layer-backed hierarchy
    /// nothing clips the difference away. Filling the dirty rect directly - which is
    /// what most drawing code does, and what a full-size view gets away with because
    /// its bounds are the window - once let a strip 22 points tall paint 1280x900 of
    /// canvas over the top of the lists, leaving a window that appeared empty.
    static func paintable(dirty: NSRect, bounds: NSRect) -> NSRect {
        dirty.intersection(bounds)
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

extension NSShadow {
    /// The shadow under a row that has been picked up.
    static var lifted: NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        return shadow
    }
}

enum Text {
    static func draw(_ string: String,
                     at point: NSPoint,
                     font: NSFont,
                     color: NSColor,
                     alignRight: CGFloat? = nil,
                     tracking: CGFloat = 0) {
        guard !string.isEmpty else { return }
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        // Letter-spacing, for the short all-capitals headings: at that size it is the
        // difference between a label and a smudge.
        if tracking != 0 { attrs[.kern] = tracking }
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
        ]).draw(with: rect, options: [.usesLineFragmentOrigin], context: nil)
    }

    /// Height this string needs when wrapped to `width`. Used to size a panel to its
    /// content rather than clipping the content to the panel.
    static func wrappedHeight(_ string: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard !string.isEmpty, width > 4 else { return 0 }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 2
        let attributed = NSAttributedString(string: string, attributes: [
            .font: font, .paragraphStyle: style
        ])
        let bounds = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin])
        return ceil(bounds.height)
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

    /// How wide `drawBadge` will make that pill. Exposed so a layout can decide
    /// whether the line still has room before it starts drawing on it.
    static func badgeWidth(_ string: String, font: NSFont) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        return width(string, font: font) + 12
    }

    /// A pill for the thing a row is most often read for - which standard this is.
    /// It was drawn on a hairline fill in secondary text and was the faintest element
    /// on screen despite being the most useful.
    static func drawBadge(_ string: String, at point: NSPoint, font: NSFont,
                          prominent: Bool = false,
                          fill: NSColor? = nil, textColor: NSColor? = nil) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let padding: CGFloat = 6
        let textWidth = width(string, font: font)
        let rect = NSRect(x: point.x, y: point.y - 2,
                          width: textWidth + padding * 2, height: font.pointSize + 7)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        (fill ?? (prominent ? Palette.badgeStrong : Palette.badge)).setFill()
        path.fill()
        draw(string, at: NSPoint(x: point.x + padding, y: point.y + 1),
             font: font,
             color: textColor ?? (prominent ? NSColor.labelColor : NSColor.secondaryLabelColor))
        return rect.width
    }
}
