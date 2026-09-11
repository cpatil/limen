import Cocoa

/// An enlarged card for whatever the pointer is over.
///
/// The rows clip text to fit their columns, so this is where the full value has to be
/// readable - which means it sizes itself to its content and wraps rather than
/// truncating. A panel that also cut its text off would defeat its own purpose.
final class MagnifierView: NSView {
    enum Zone {
        case rate, chart, info
    }

    var row: Row?
    var zone: Zone = .rate
    var unit: RateUnit = .bytes
    var details: String = ""
    var sampleInterval: TimeInterval = 1

    static let width: CGFloat = 400
    private static let pad: CGFloat = 14
    private static let fullChartHeight: CGFloat = 58
    private static let compactChartHeight: CGFloat = 34

    /// Set when the card cannot fit in the window at its natural size.
    ///
    /// It tightens; it does not shed. An earlier version dropped the explanations to
    /// make room, which threw away the part that answers "how do you know?" - the
    /// reason the card is worth hovering at all. Only the chart gives ground, and the
    /// rest is reached by clicking the row, which pins the card and lets it scroll.
    var compact = false

    private var chartHeight: CGFloat {
        compact ? MagnifierView.compactChartHeight : MagnifierView.fullChartHeight
    }

    private let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private let bodyFont = NSFont.systemFont(ofSize: 12.5)
    private let smallFont = NSFont.systemFont(ofSize: 12)
    private let badgeFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// A touch larger and heavier than the link badge: on a storage row the card is
    /// the subject, and the link is context.
    private let cardBadgeFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private let tickFont = NSFont.systemFont(ofSize: 10)
    private let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .medium)
    private let tagFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)

    /// Text-only in a flipped space, so blocks can be laid out top-down and measured
    /// with the same code that draws them.
    /// Held open by a click rather than following the pointer.
    var isPinned = false
    var onClose: (() -> Void)?

    /// Whether the compact note applies - it does not while scrolling, since nothing
    /// has been dropped.
    var droppedContent: Bool { compact }

    /// The dismiss target, top-right in this view's own (flipped) space.
    ///
    /// Geometry in one place because two things have to agree about it: what is drawn
    /// and what is clickable. They were the same expression written twice in the first
    /// attempt, which is how a close button ends up one pixel out of reach.
    static func closeRect(in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.maxX - 30, y: 10, width: 20, height: 20)
    }

    override var isFlipped: Bool { true }

    /// Transparent to the mouse except for the dismiss button, and only while pinned.
    /// A card that swallowed clicks would put a 400-point hole over the rows it is
    /// describing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isPinned, !isHidden else { return nil }
        // Inside a scroller the whole card has to be reachable, or there is nothing
        // for the wheel to act on. Loose on the window it stays transparent except
        // for the cross, so it does not put a hole over the rows it describes.
        if enclosingScrollView != nil { return super.hitTest(point) }
        let local = convert(point, from: superview)
        return MagnifierView.closeRect(in: bounds).contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if MagnifierView.closeRect(in: bounds).contains(local) { onClose?() }
    }

    override func resetCursorRects() {
        guard isPinned else { return }
        addCursorRect(MagnifierView.closeRect(in: bounds), cursor: .pointingHand)
    }

    private var contentWidth: CGFloat { MagnifierView.width - MagnifierView.pad * 2 }

    // The variable-length blocks, in the order they appear.
    /// What belongs under "what is in the reader": the evidence for the card badge.
    private func cardBlocks(for row: Row) -> [(text: String, font: NSFont, color: NSColor)] {
        var out: [(String, NSFont, NSColor)] = []
        // The card badge above carries the mark. This is what the mark stands for -
        // the evidence, so it can be disagreed with.
        if !row.mediumClass.isEmpty {
            // Deliberately hedged twice over. The family follows from the capacity
            // only once the medium is known to be an SD card, which Bottleneck takes from
            // the reader's own description rather than from the capacity; and the
            // reason the rest is unavailable is what readers usually do, not a law -
            // a vendor-specific reader and driver can expose more.
            let capacity = row.capacityBytes > 0
                ? "the card's " + Fmt.bytes(Double(row.capacityBytes)) + " capacity"
                : "the card's capacity"
            let family = row.mediumClass.split(separator: " ").first.map(String.init) ?? ""
            out.append((Palette.marked("Likely \(family), based on \(capacity). Most USB "
                        + "card readers expose the card to macOS as generic storage, "
                        + "without its SD-specific metadata, so Bottleneck cannot tell which "
                        + "bus interface (UHS-I, say) or rated speed class (V30) the "
                        + "card supports from what is available here."),
                        smallFont, Palette.inferred))
        }
        return out
    }

    /// Everything that belongs to neither panel: what this device is doing and what
    /// that is worth saying about.
    private func blocks(for row: Row) -> [(text: String, font: NSFont, color: NSColor)] {
        var out: [(String, NSFont, NSColor)] = []

        // Same rule as the row: where the bar already answers "how does this compare",
        // a second comparison beside it is noise, and the one this produced named a
        // standard picked by the very rate it was describing.
        let context = usage(row) == nil ? contextText(row) : ""
        if !context.isEmpty {
            // row.note is a fact about the interface and "best this session" is a
            // measurement; anything else on this line names a standard from a rate,
            // which is a comparison against the catalogue.
            let inferred = row.note.isEmpty && row.hasKnownMediumClass
            out.append((inferred ? Palette.marked(context) : context, bodyFont,
                        inferred ? Palette.inferred : Palette.secondary))
        }
        if row.indexingWorthReporting, !row.indexingDisabled {
            out.append(("No .metadata_never_index marker here, so nothing is stopping "
                        + "Spotlight indexing this volume. Whether it is doing so now is "
                        + "not checked. On something you only read from, indexing is "
                        + "wear and contention for nothing - right-click the row to "
                        + "stop it, and again to allow it.", smallFont, Palette.warning))
        }
        // The other names this link goes by used to sit here, in the middle of the
        // block about the card, above the heading that says the connection starts
        // below - so the one line naming the port was filed under the card. It is
        // drawn inside the connection section now.
        return out
    }

    private func footerBlocks(for row: Row) -> [(text: String, font: NSFont, color: NSColor)] {
        var out: [(String, NSFont, NSColor)] = []


        if !row.actors.isEmpty {
            // Not "the processes causing this traffic". proc_pid_rusage reports a
            // process's disk I/O as a whole; the open-descriptor check says the
            // process is working on this volume, not that every byte went here.
            out.append(("processes with disk activity and an open file here:",
                        smallFont, Palette.faint))
        }
        for actor in row.actors {
            out.append((actor.display + "   " + Fmt.rate(actor.bytesPerSec, unit: unit),
                        smallFont, NSColor.labelColor))
        }
        // What the bar was measured against, when it was not measured against a link.
        // The percentage on its own says nothing about how good the yardstick is.
        if let gauge = usage(row), let basis = gauge.basis {
            out.append((Palette.marked("The bar runs to " + basis
                        + " - what that class of device typically manages today, not a "
                        + "ceiling this one reported. Its scale is logarithmic, marked "
                        + "at each tenfold step, because storage rates span four "
                        + "decades and a linear bar gives three of them one pixel."),
                        smallFont, Palette.inferred))
        }
        if !row.hint.isEmpty {
            // Was blue, which is this app's colour for the outbound direction. Advice
            // is drawn from what the device was seen to do, so it belongs in the
            // inferred colour and nowhere near a rate.
            out.append((Palette.marked(row.hint), smallFont, Palette.inferred))
        }
        return out
    }

    /// One figure with its name above it. Six of these used to be a single grey
    /// sentence joined by middle dots - every number the same size and colour as the
    /// words around it, so finding "best ever" meant reading the whole line.
    struct Stat {
        let label: String
        let value: String
        let colour: NSColor
    }

    /// The facts about a volume that nothing else on a Mac puts in front of you: its
    /// own identity, the allocation unit it was formatted with, whether it is locked,
    /// and the device node underneath it.
    func volumeFacts(_ row: Row) -> String {
        var parts: [String] = []
        if row.blockSize > 0 {
            parts.append(Fmt.bytes(Double(row.blockSize)) + " allocation unit")
        }
        if row.readOnly { parts.append("write-protected") }
        if !row.deviceNode.isEmpty { parts.append(row.deviceNode) }
        return parts.joined(separator: "  ·  ")
    }

    /// What this thing is: vendor, identifier, the volumes it presents. Drawn on its
    /// own rather than as the first of the wrapped blocks, because how full it is
    /// belongs directly underneath it - a device's capacity is part of what it is,
    /// not one more figure among its rates.
    func identityLine(_ row: Row) -> String {
        var identity: [String] = []
        // A card's panel is about the card. The reader's maker and USB id describe the
        // holder, and they belong with the holder, under the connection.
        let aboutACard = !row.mediumClass.isEmpty
        if !aboutACard, !row.vendor.isEmpty, row.vendor != row.title { identity.append(row.vendor) }
        if !aboutACard, !row.deviceID.isEmpty { identity.append(row.deviceID) }
        if !row.volumes.isEmpty, row.mediumClass.isEmpty {
            identity.append(row.volumes.joined(separator: ", "))
        }
        // The subtitle is the reader's own description - "Generic" - which is the
        // holder again. Only useful when the row is about the device itself.
        if !aboutACard, identity.isEmpty, !row.subtitle.isEmpty { identity.append(row.subtitle) }
        // What it is formatted as belongs with what it is, not among its rates.
        let format = Fmt.fsName(row.fsType)
        if !format.isEmpty { identity.append(format) }
        return identity.joined(separator: "  ·  ")
    }

    /// How full the device is, as the pair that used to sit at the bottom of the grid.
    func capacityStats(for row: Row) -> [Stat] {
        guard row.capacityBytes > 0 else { return [] }
        // Counted once per container: several volumes of one disk share its space,
        // and each of them reports the whole disk's figures as its own.
        let used = Double(row.usedBytes)
        return [
            Stat(label: "USED", value: Fmt.bytes(used),
                 colour: TrafficListView.capacityColour(fraction: row.fullness ?? 0)),
            Stat(label: "FREE", value: Fmt.bytes(Double(row.capacityBytes) - used),
                 colour: NSColor.labelColor),
        ]
    }

    func stats(for row: Row) -> [Stat] {
        var out: [Stat] = []
        // The device's own counters, not this session's - said once, under the grid,
        // rather than folded into each figure's name.
        // "TOTAL READ", not "READ": the live rate above the grid is already labelled
        // READ, and two figures under the same word meaning different things is the
        // sort of thing you only notice after misreading it once.
        out.append(Stat(label: "TOTAL " + row.inLong.uppercased(),
                        value: Fmt.bytes(Double(row.totalDown)), colour: Palette.down))
        out.append(Stat(label: "TOTAL " + row.outLong.uppercased(),
                        value: Fmt.bytes(Double(row.totalUp)), colour: Palette.up))
        if row.peak > 0 {
            out.append(Stat(label: "PEAK THIS RUN", value: Fmt.rate(row.peak, unit: unit),
                            colour: NSColor.labelColor))
        }
        // From the transfer log, so it outlives the run - and outlives the device
        // being idle all afternoon, which is what made "peak" alone misleading.
        if row.allTimePeak > row.peak {
            // How far past the bar's own scale that sits, when it does. The chevron on
            // the bar says "further than this goes"; the label says how much further.
            var label = "BEST EVER"
            if let gauge = usage(row),
               TrafficListView.peakIsBeyond(peak: row.allTimePeak,
                                            denominator: gauge.denominatorBytes) {
                label += String(format: " \u{00B7} %.1f\u{00D7} THE SCALE",
                                row.allTimePeak / gauge.denominatorBytes)
            }
            out.append(Stat(label: label, value: Fmt.rate(row.allTimePeak, unit: unit),
                            colour: NSColor.labelColor))
        }
        return out
    }

    /// Two to a line, so the height follows from the count in one place rather than
    /// being guessed at in two.
    static func statRows(_ count: Int) -> Int { (count + 1) / 2 }

    private static let statRowHeight: CGFloat = 34

    private func drawStats(_ stats: [Stat], at origin: NSPoint, width: CGFloat) -> CGFloat {
        let labelFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        let column = width / 2
        var y = origin.y
        for (index, stat) in stats.enumerated() {
            let x = origin.x + (index % 2 == 0 ? 0 : column)
            Text.draw(stat.label, at: NSPoint(x: x, y: y), font: labelFont,
                      color: Palette.faint, tracking: 0.7)
            Text.draw(stat.value, at: NSPoint(x: x, y: y + 12), font: valueFont,
                      color: stat.colour)
            if index % 2 == 1 { y += MagnifierView.statRowHeight }
        }
        if stats.count % 2 == 1 { y += MagnifierView.statRowHeight }
        return y
    }

    /// The bar's label, in the form this card has room for.
    private func gaugeLabel(_ gauge: Reference.Gauge) -> String {
        gauge.isInferred ? Palette.marked(gauge.longLabel) : gauge.label
    }

    /// Whether that label has to go under the bar rather than beside it. Asked by both
    /// the height calculation and the drawing, so the card cannot be sized for one
    /// layout and drawn in the other.
    private func gaugeLabelWraps(_ gauge: Reference.Gauge) -> Bool {
        contentWidth - Text.width(gaugeLabel(gauge), font: smallFont) - 12 < 120
    }

    /// What the bar measures: the link where that can be judged, the device's own
    /// best where it cannot. Same rule as the rows, so the card never disagrees with
    /// what is behind it.
    private func usage(_ row: Row) -> Reference.Gauge? {
        Reference.gauge(down: row.down, up: row.up,
                        peakDirectional: row.peakDirectional, peak: row.peak,
                        linkBits: row.linkBits, linkTrusted: row.linkTrusted,
                        families: row.compareFamilies.isEmpty ? nil : row.compareFamilies,
                        roles: row.compareRoles.isEmpty ? nil : row.compareRoles,
                        internalMedium: row.internalMedium,
                        kinds: row.mediumKinds.isEmpty ? nil : row.mediumKinds,
                        hasKnownClass: row.hasKnownMediumClass)
    }

    /// Type, capacity and name of the card in this reader, if there is one.
    /// What the row's third line says, repeated here in full.
    ///
    /// It is the one line the row shortens that the card did not carry, which made it
    /// the only text in the interface with no way to read it whole.
    private func contextText(_ row: Row) -> String {
        if !row.note.isEmpty { return row.note }
        // Same rule as the row: a rate cannot say what something is. Without a class
        // to compare against, report what was seen.
        if !row.hasKnownMediumClass {
            return row.peak > 0 ? "best this session " + Fmt.rate(row.peak, unit: unit) : ""
        }
        return Reference.context(current: row.down + row.up, peak: row.peak, unit: unit,
                                 families: row.compareFamilies.isEmpty ? nil : row.compareFamilies,
                                 roles: row.compareRoles.isEmpty ? nil : row.compareRoles,
                                 internalMedium: row.internalMedium,
                                 kinds: row.mediumKinds.isEmpty ? nil : row.mediumKinds)
    }

    private func cardText(_ row: Row) -> String {
        // Nothing at all when the headline is already the card's description, and
        // without the volume name when that is the headline: a badge repeating the
        // title tells you nothing twice.
        if headline(row) == row.mediumClass { return "" }
        guard headline(row) != row.volumes.first else { return row.mediumClass }
        return Row.cardLabel(class: row.mediumClass, volumes: row.volumes)
    }

    static let rawTag = "raw signalling"

    // ---- the two panels ---------------------------------------------------
    //
    // A panel has to be painted before the things inside it, so its height has to be
    // known before any of them are drawn. That is the same arithmetic the card's own
    // fitting height does, and keeping two copies of it is exactly how text ended up
    // under a rounded corner twice today - so each panel measures itself here, and
    // both the sizing pass and the drawing pass ask.

    static let panelPad: CGFloat = 10
    static let captionHeight: CGFloat = 14

    private var panelWidth: CGFloat { contentWidth - panelInset * 2 }
    private let panelInset: CGFloat = 10

    /// What this row is about.
    ///
    /// For a reader, the card - "sd-21", or "SD card" before it is named. The reader
    /// itself is how the card is attached, which is what the connection panel is for;
    /// leading with "USB3.0 Card Reader" put the holder where the contents belong and
    /// left the card as a footnote to its own row.
    func headline(_ row: Row) -> String { row.headline }

    /// What to call the first panel. A reader is a holder for something else, so its
    /// panel is about the card; everything else is about itself.
    /// The live half: history, the rates now, the bar, and the running totals.
    ///
    /// Measured here so it can be given a panel like the other two, and so the card
    /// reads as three grouped blocks rather than two boxes and a loose tail.
    func livePanelHeight(_ row: Row) -> CGFloat {
        var h: CGFloat = 8 + 12 + chartHeight + 8 + 36
        if let gauge = usage(row) { h += gaugeLabelWraps(gauge) ? 46 : 28 }
        let statCount = stats(for: row).count
        if statCount > 0 {
            h += CGFloat(MagnifierView.statRows(statCount)) * MagnifierView.statRowHeight + 24
        }
        return h + MagnifierView.panelPad * 2
    }

    /// The stripe beside it: the card's own green where there is a card, and a quiet
    /// grey where there is not. A drive has no badge to borrow a colour from, and
    /// green and blue already mean read and write on this card.
    func devicePanelStripe(_ row: Row) -> NSColor {
        cardText(row).isEmpty ? NSColor.labelColor.withAlphaComponent(0.35)
                              : NSColor.systemGreen
    }

    /// How wide the used/free pair is when drawn as a block beside something.
    var capacityBlockWidth: CGFloat { 190 }

    /// Whether used and free fit beside the badge rather than under it.
    ///
    /// The panel had a badge on one line, a word like "exFAT" on the next, and
    /// two-thirds of both lines empty - then spent a third line on the figures. They
    /// go in that gap when it is big enough, which for a card it is and for a drive
    /// listing five device names it is not.
    func capacityFitsBeside(_ row: Row) -> Bool {
        guard !capacityStats(for: row).isEmpty else { return false }
        let badge = cardText(row).isEmpty ? 0
            : Text.badgeWidth(Palette.mark + cardText(row), font: cardBadgeFont)
        let identity = Text.width(identityLine(row), font: bodyFont)
        return max(badge, identity) + capacityBlockWidth + 12 <= panelWidth
    }

    /// What this device is: the badge where there is one, then identity, capacity and
    /// any evidence for what the badge claims.
    /// The lines under the identity: the volume's facts, then its UUID.
    func volumeLines(_ row: Row) -> [String] {
        var lines: [String] = []
        let facts = volumeFacts(row)
        if !facts.isEmpty { lines.append(facts) }
        if !row.volumeID.isEmpty { lines.append(row.volumeID) }
        return lines
    }

    func cardPanelHeight(_ row: Row) -> CGFloat {
        let hasCard = !cardText(row).isEmpty
        // A panel earns its place by grouping more than one thing. A box round a
        // single badge is a box round the row's own title restated - it takes a
        // caption, a border and twenty points of padding to say nothing. So: a card
        // with something known about it, or a volume with space to report.
        let parts = (hasCard ? 1 : 0) + (identityLine(row).isEmpty ? 0 : 1)
            + (capacityStats(for: row).isEmpty ? 0 : 1) + cardBlocks(for: row).count
        guard parts > 1 else { return 0 }
        // No caption: the title above it already names the subject, and the panel's
        // contents - a card badge, a capacity - say what they are without a heading.
        // "HOW IT IS CONNECTED" keeps its own, because a reader and a link are not
        // implied by the name of the card.
        var h = hasCard ? CGFloat(28) : 0
        let identity = identityLine(row)
        if !identity.isEmpty {
            h += Text.wrappedHeight(identity, font: bodyFont, width: panelWidth) + 5
        }
        for line in volumeLines(row) {
            h += Text.wrappedHeight(line, font: smallFont, width: panelWidth) + 3
        }
        let capacity = capacityStats(for: row)
        if !capacity.isEmpty, !capacityFitsBeside(row) {
            h += CGFloat(MagnifierView.statRows(capacity.count))
                * MagnifierView.statRowHeight + 4
        }
        for block in cardBlocks(for: row) {
            h += Text.wrappedHeight(block.text, font: block.font, width: panelWidth) + 5
        }
        return h + MagnifierView.panelPad * 2
    }

    /// "How it is connected": badge, rates, the other names for the same wire.
    func linkPanelHeight(_ row: Row) -> CGFloat {
        guard hasLinkRow(row) else { return 0 }
        var h = MagnifierView.captionHeight + (linkRowWraps(row) ? 44 : 26)
        let names = alsoKnownText(row)
        if !names.isEmpty {
            h += Text.wrappedHeight(names, font: smallFont, width: panelWidth) + 4
        }
        return h + MagnifierView.panelPad * 2
    }

    /// The panel itself: a quiet ground with a stripe in the colour of the badge it
    /// contains, so two subjects that were one wall of text are two objects.
    private func drawPanel(_ rect: NSRect, stripe: NSColor) {
        NSColor.labelColor.withAlphaComponent(Palette.isLight ? 0.05 : 0.06).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        stripe.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY + 6,
                                         width: 3, height: rect.height - 12),
                     xRadius: 1.5, yRadius: 1.5).fill()
    }

    /// The other names for this link, or empty when there are none.
    private func alsoKnownText(_ row: Row) -> String {
        let names = [row.alsoKnown, row.appleName].filter { !$0.isEmpty }
        guard !names.isEmpty else { return "" }
        // Why one port has four names, which otherwise reads as a contradiction: the
        // USB-IF renamed this same signalling mode every time a faster one arrived,
        // and Apple uses its own vocabulary again.
        return "Also known as " + names.joined(separator: "  \u{00B7}  ")
            + " \u{2014} one link, renamed each time a faster mode arrived."
    }

    /// The practical ceiling for this row's link, marked, or nil when there is none.
    private func practicalText(_ row: Row) -> String? {
        guard row.linkTrusted, row.linkBits > 0,
              let ceiling = Reference.ceiling(forLinkBits: row.linkBits,
                                              family: row.compareFamilies.contains(.network)
                                                   ? .network : .usb),
              ceiling.bytes > 0
        else { return nil }
        return Palette.marked(Fmt.rate(ceiling.bytes, unit: .bytes) + " in practice")
    }

    /// Whether the link row needs a second line. Asked by both the height calculation
    /// and the drawing, so the card cannot be sized for one layout and drawn in the
    /// other - which is how text ends up under the rounded corner.
    private func linkRowWraps(_ row: Row) -> Bool {
        guard let practical = practicalText(row) else { return false }
        var x: CGFloat = 0
        if !row.badge.isEmpty {
            x += Text.badgeWidth((row.removable ? "via " : "") + row.badge,
                                 font: badgeFont) + 8
        }
        x += Text.width(Fmt.linkSpeed(bitsPerSec: row.linkBits), font: bodyFont) + 6
        x += Text.width(MagnifierView.rawTag, font: smallFont) + 8
        return x + Text.width(practical, font: smallFont) > contentWidth
    }

    private func hasLinkRow(_ row: Row) -> Bool {
        !row.badge.isEmpty || (row.linkTrusted && row.linkBits > 0) || !row.appleName.isEmpty
    }

    /// Exactly as tall as its content needs, so nothing is ever cut off.
    var fittingHeight: CGFloat {
        guard let row = row else { return 120 }
        let pad = MagnifierView.pad
        var height = pad + 24                                    // icon + title
        let cardHeight = cardPanelHeight(row)
        if cardHeight > 0 {
            height += cardHeight + 8
        } else {
            if !cardText(row).isEmpty { height += 28 }
            if !identityLine(row).isEmpty {
                height += Text.wrappedHeight(identityLine(row), font: bodyFont,
                                             width: contentWidth) + 5
            }
            for block in cardBlocks(for: row) {
                height += Text.wrappedHeight(block.text, font: block.font,
                                             width: contentWidth) + 5
            }
        }
        for block in blocks(for: row) {
            height += Text.wrappedHeight(block.text, font: block.font, width: contentWidth) + 5
        }
        let linkHeight = linkPanelHeight(row)
        if linkHeight > 0 { height += linkHeight + 8 }
        // The bar belongs to the live panel and is measured there. Counting it here as
        // well reserved 28 points the drawing never used, which is the empty strip at
        // the bottom of every card.
        height += livePanelHeight(row) + 8

        for block in footerBlocks(for: row) {
            height += Text.wrappedHeight(block.text, font: block.font, width: contentWidth) + 4
        }
        return height + pad
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row = row else { return }

        let card = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
        // Concrete components with full alpha, so the fill cannot be translucent
        // whatever the appearance resolves to.
        let base = (NSColor.controlBackgroundColor.usingColorSpace(.sRGB)
                    ?? NSColor.white).withAlphaComponent(1.0)
        base.setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1
        path.stroke()

        if isPinned {
            let box = MagnifierView.closeRect(in: bounds)
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(ovalIn: box).fill()
            let cross = NSBezierPath()
            let inset = box.insetBy(dx: 6, dy: 6)
            cross.move(to: NSPoint(x: inset.minX, y: inset.minY))
            cross.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
            cross.move(to: NSPoint(x: inset.maxX, y: inset.minY))
            cross.line(to: NSPoint(x: inset.minX, y: inset.maxY))
            cross.lineWidth = 1.5
            cross.lineCapStyle = .round
            NSColor.labelColor.withAlphaComponent(0.55).setStroke()
            cross.stroke()
        }

        let pad = MagnifierView.pad
        let left = card.minX + pad
        let width = contentWidth
        var y = card.minY + pad

        Icons.draw(row.icon, in: NSRect(x: left, y: y, width: 20, height: 20),
                   color: Palette.secondary)
        Text.draw(headline(row), at: NSPoint(x: left + 28, y: y + 1),
                  font: titleFont, color: NSColor.labelColor)
        y += 24

        // The card gets a badge of its own, directly under the device it is sitting in
        // and above everything else - it is what the row is actually about.
        // ---- panel: what is in the reader ---------------------------------
        let cardHeight = cardPanelHeight(row)
        if cardHeight > 0 {
            drawPanel(NSRect(x: left, y: y, width: width, height: cardHeight),
                      stripe: devicePanelStripe(row))
            let inner = left + panelInset
            let innerWidth = panelWidth
            var py = y + MagnifierView.panelPad


            // Used and free go in the empty half of the badge line when there is one.
            let besideCapacity = capacityFitsBeside(row)
            if besideCapacity {
                _ = drawStats(capacityStats(for: row),
                              at: NSPoint(x: inner + innerWidth - capacityBlockWidth, y: py),
                              width: capacityBlockWidth)
            }
            if !cardText(row).isEmpty {
                _ = Text.drawBadge(Palette.mark + cardText(row),
                                   at: NSPoint(x: inner, y: py + 2),
                                   font: cardBadgeFont,
                                   fill: Palette.cardBadge,
                                   textColor: NSColor.labelColor)
                py += 28
            }

            let identity = identityLine(row)
            if !identity.isEmpty {
                let h = Text.wrappedHeight(identity, font: bodyFont, width: innerWidth)
                Text.drawWrapped(identity,
                                 in: NSRect(x: inner, y: py, width: innerWidth, height: h),
                                 font: bodyFont, color: NSColor.labelColor)
                py += h + 5
            }
            for line in volumeLines(row) {
                let h = Text.wrappedHeight(line, font: smallFont, width: innerWidth)
                Text.drawWrapped(line, in: NSRect(x: inner, y: py, width: innerWidth, height: h),
                                 font: smallFont, color: Palette.faint)
                py += h + 3
            }

            // Directly under what the device is, because that is what it answers.
            let capacity = capacityStats(for: row)
            if !capacity.isEmpty, !besideCapacity {
                py = drawStats(capacity, at: NSPoint(x: inner, y: py + 2), width: innerWidth)
                py += 2
            }
            for block in cardBlocks(for: row) {
                let h = Text.wrappedHeight(block.text, font: block.font, width: innerWidth)
                Text.drawWrapped(block.text,
                                 in: NSRect(x: inner, y: py, width: innerWidth, height: h),
                                 font: block.font, color: block.color)
                py += h + 5
            }
            y += cardHeight + 8
        } else {
            // No panel: whatever little there is goes on the line under the title.
            if !cardText(row).isEmpty {
                _ = Text.drawBadge(Palette.mark + cardText(row),
                                   at: NSPoint(x: left, y: y + 2),
                                   font: cardBadgeFont, fill: Palette.cardBadge,
                                   textColor: NSColor.labelColor)
                y += 28
            }
            let identity = identityLine(row)
            if !identity.isEmpty {
                let h = Text.wrappedHeight(identity, font: bodyFont, width: width)
                Text.drawWrapped(identity, in: NSRect(x: left, y: y, width: width, height: h),
                                 font: bodyFont, color: NSColor.labelColor)
                y += h + 5
            }
            // The evidence survives the panel. Losing the paragraph that says how the
            // card was identified, because there was too little else to box, would
            // throw away the only part that answers "how do you know?".
            for block in cardBlocks(for: row) {
                let h = Text.wrappedHeight(block.text, font: block.font, width: width)
                Text.drawWrapped(block.text,
                                 in: NSRect(x: left, y: y, width: width, height: h),
                                 font: block.font, color: block.color)
                y += h + 5
            }
        }

        for block in blocks(for: row) {
            let h = Text.wrappedHeight(block.text, font: block.font, width: width)
            Text.drawWrapped(block.text, in: NSRect(x: left, y: y, width: width, height: h),
                             font: block.font, color: block.color)
            y += h + 5
        }

        // ---- the link, given the weight it deserves -------------------------
        // The standard is what a row is most often read for, so it gets a badge and
        // full-strength text rather than being the faintest thing on the card.
        let linkHeight = linkPanelHeight(row)
        if linkHeight > 0 {
            drawPanel(NSRect(x: left, y: y, width: width, height: linkHeight),
                      stripe: NSColor.systemBlue)
            let inner = left + panelInset
            y += MagnifierView.panelPad
            // Named, because this line is about the connection and the badge above it
            // is about the card - and side by side, unlabelled, they read as two facts
            // about one device.
            Text.draw(row.removable ? "HOW IT IS CONNECTED" : "CONNECTION",
                      at: NSPoint(x: inner, y: y),
                      font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                      color: Palette.faint, tracking: 0.7)
            // The reader is part of the answer to "how is this attached", which is why
            // it is here rather than at the top: a card in a reader on a cable is
            // three things, and only the first of them is the subject.
            if !row.mediumClass.isEmpty {
                let holder = [row.title, row.vendor].filter { !$0.isEmpty && $0 != row.vendor }
                Text.draw(holder.first ?? row.title,
                          at: NSPoint(x: inner + 150, y: y - 1),
                          font: smallFont, color: Palette.secondary)
            }
            // Advance past it rather than drawing above the cursor: written above, it
            // landed on top of whatever block ended there.
            y += MagnifierView.captionHeight
            var x = inner
            if !row.badge.isEmpty {
                x += Text.drawBadge((row.removable ? "via " : "") + row.badge,
                                    at: NSPoint(x: x, y: y + 2),
                                    font: badgeFont, prominent: true) + 8
            }
            if row.linkTrusted, row.linkBits > 0 {
                // The negotiated figure, named as what it is. Dividing it by eight and
                // calling the result MB/s is arithmetically right and practically
                // misleading: line coding and protocol overhead are paid before any
                // file moves, so a 5 Gbit/s port does not carry 625 MB/s of payload.
                let primary = Fmt.linkSpeed(bitsPerSec: row.linkBits)
                Text.draw(primary, at: NSPoint(x: x, y: y + 4), font: bodyFont,
                          color: NSColor.labelColor)
                x += Text.width(primary, font: bodyFont) + 6
                Text.draw(MagnifierView.rawTag, at: NSPoint(x: x, y: y + 5),
                          font: smallFont, color: Palette.faint)
                x += Text.width(MagnifierView.rawTag, font: smallFont) + 8
                // What the catalogue says that standard actually sustains. An estimate,
                // so it is marked like every other estimate - and moved to its own line
                // when what is left of the card cannot hold it, rather than being drawn
                // over the edge and clipped by the corner radius.
                if let practical = practicalText(row).map({
                    row.removable ? $0 + " \u{2014} the reader's link, not the card" : $0
                }) {
                    if x + Text.width(practical, font: smallFont) > inner + panelWidth {
                        y += 18
                        x = inner
                    }
                    Text.draw(practical, at: NSPoint(x: x, y: y + 5), font: smallFont,
                              color: Palette.inferred)
                }
            }
            y += 26
            // The other names this same wire goes by - the USB-IF has renamed it
            // twice, and Apple uses a third vocabulary. A fact about the connection,
            // so it lives in the connection's section.
            let names = alsoKnownText(row)
            if !names.isEmpty {
                let h = Text.wrappedHeight(names, font: smallFont, width: panelWidth)
                Text.drawWrapped(names, in: NSRect(x: inner, y: y, width: panelWidth, height: h),
                                 font: smallFont, color: Palette.secondary)
                y += h + 4
            }
            y += MagnifierView.panelPad + 8
        }

        // ---- the live half, grouped like the other two ----------------------
        let liveHeight = livePanelHeight(row)
        drawPanel(NSRect(x: left, y: y, width: width, height: liveHeight),
                  stripe: NSColor.labelColor.withAlphaComponent(0.35))
        // Shadowed rather than rewritten at fifteen call sites: everything below draws
        // inside the panel, and the names it draws with should mean the panel.
        do {
            let left = left + panelInset
            let width = panelWidth
            y += MagnifierView.panelPad

        // ---- history, labelled with its own scale ---------------------------
        y += 8
        let scale = Chart.peak(down: row.downHist, up: row.upHist)
        let span = Double(Monitor.historyLength) * sampleInterval
        Text.draw(span >= 120 ? String(format: "last %.0f min", span / 60)
                              : String(format: "last %.0f s", span),
                  at: NSPoint(x: left, y: y), font: tickFont, color: Palette.faint)
        Text.draw(Fmt.rate(scale, unit: unit) + " full scale",
                  at: NSPoint(x: 0, y: y), font: tickFont,
                  color: Palette.secondary, alignRight: left + width)
        y += 12
        Palette.faint.setFill()
        NSRect(x: left, y: y, width: width, height: 1).fill()

        let chart = NSRect(x: left, y: y, width: width, height: chartHeight)
        NSGraphicsContext.saveGraphicsState()
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: chart.maxY + chart.minY)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        Chart.draw(down: row.downHist, up: row.upHist, in: chart, lineWidth: 1.8)
        NSGraphicsContext.restoreGraphicsState()
        y += chartHeight + 8

        // ---- live rates -----------------------------------------------------
        let mid = left + width / 2
        Text.draw(row.inLong, at: NSPoint(x: left, y: y), font: tagFont, color: Palette.down)
        Text.draw(row.outLong, at: NSPoint(x: mid, y: y), font: tagFont, color: Palette.up)
        Text.draw(Fmt.rate(row.down, unit: unit), at: NSPoint(x: left, y: y + 13),
                  font: rateFont, color: Palette.down)
        Text.draw(Fmt.rate(row.up, unit: unit), at: NSPoint(x: mid, y: y + 13),
                  font: rateFont, color: Palette.up)
        y += 36

        // A bar as well as a number: the share of a link is a proportion, and a
        // proportion is read faster as a length than as text.
        if let gauge = usage(row) {
            let used = gauge.fraction
            // The bar takes what the label leaves, and the label goes underneath when
            // what is left is too narrow to be a bar. The width used to be a constant
            // measured against "0% link utilization"; the label then grew to name its
            // yardstick and ran off the side of the card.
            let text = gaugeLabel(gauge)
            let wraps = gaugeLabelWraps(gauge)
            let barWidth = wraps ? width : width - Text.width(text, font: smallFont) - 12
            let bar = NSRect(x: left, y: y + 5, width: barWidth, height: 7)
            Palette.hairline.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 3.5, yRadius: 3.5).fill()
            let fraction = CGFloat(min(1, max(0, used)))
            // Orange says "the link is the limit". Against a device's own best that is
            // no limit at all - a full bar only means it is doing what it usually does -
            // so the peak-relative bar stays neutral however full it looks.
            let fill: NSColor
            if gauge.ofLink {
                fill = used >= 0.85 ? NSColor.systemOrange
                     : (used >= 0.40 ? Palette.down : Palette.up)
            } else {
                fill = Palette.inferredFill
                NSColor.labelColor.withAlphaComponent(0.18).setFill()
                for mark in Reference.logDecades(ceiling: gauge.denominatorBytes) {
                    let x = bar.minX + barWidth * CGFloat(mark)
                    NSRect(x: x, y: bar.minY, width: 1, height: bar.height).fill()
                }
            }
            fill.setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY,
                                             width: max(3, barWidth * fraction), height: bar.height),
                         xRadius: 3.5, yRadius: 3.5).fill()
            if let mark = TrafficListView.peakMark(in: bar, peak: row.allTimePeak,
                                                   denominator: gauge.denominatorBytes,
                                                   current: used) {
                NSColor.labelColor.withAlphaComponent(0.6).setFill()
                mark.fill()
            }
            Text.draw(text,
                      at: NSPoint(x: wraps ? left : bar.maxX + 10,
                                  y: wraps ? y + 18 : y),
                      font: smallFont,
                      color: gauge.isInferred ? Palette.inferred
                           : (used >= 0.85 ? NSColor.systemOrange
                                           : Palette.secondary))
            y += wraps ? 46 : 28
        }

        // ---- the figures, as a grid ----------------------------------------
        let grid = stats(for: row)
        if !grid.isEmpty {
            Palette.hairline.setFill()
            NSRect(x: left, y: y - 6, width: width, height: 1).fill()
            y = drawStats(grid, at: NSPoint(x: left, y: y + 4), width: width)
            Text.draw("Totals are the device's own counters, since it was attached.",
                      at: NSPoint(x: left, y: y), font: tickFont, color: Palette.faint)
            y += 20
        }

        }
        y += MagnifierView.panelPad + 8

        for block in footerBlocks(for: row) {
            let h = Text.wrappedHeight(block.text, font: block.font, width: width)
            Text.drawWrapped(block.text, in: NSRect(x: left, y: y, width: width, height: h),
                             font: block.font, color: block.color)
            y += h + 4
        }
    }
}
