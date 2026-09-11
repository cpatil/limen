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
    private static let pad: CGFloat = 18
    private static let chartHeight: CGFloat = 76

    private let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private let bodyFont = NSFont.systemFont(ofSize: 12.5)
    private let smallFont = NSFont.systemFont(ofSize: 12)
    private let badgeFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// A touch larger and heavier than the link badge: on a storage row the card is
    /// the subject, and the link is context.
    private let cardBadgeFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private let tickFont = NSFont.systemFont(ofSize: 10)
    private let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 19, weight: .medium)
    private let tagFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)

    /// Text-only in a flipped space, so blocks can be laid out top-down and measured
    /// with the same code that draws them.
    /// Held open by a click rather than following the pointer.
    var isPinned = false
    var onClose: (() -> Void)?

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
    private func blocks(for row: Row) -> [(text: String, font: NSFont, color: NSColor)] {
        var out: [(String, NSFont, NSColor)] = []

        var identity: [String] = []
        if !row.vendor.isEmpty, row.vendor != row.title { identity.append(row.vendor) }
        if !row.deviceID.isEmpty { identity.append(row.deviceID) }
        if !row.volumes.isEmpty, row.mediumClass.isEmpty {
            identity.append(row.volumes.joined(separator: ", "))
        }
        if identity.isEmpty, !row.subtitle.isEmpty { identity.append(row.subtitle) }
        if !identity.isEmpty {
            out.append((identity.joined(separator: "  ·  "), bodyFont, NSColor.labelColor))
        }
        // The card badge above carries the mark. This is what the mark stands for -
        // the evidence, so it can be disagreed with.
        if !row.mediumClass.isEmpty {
            // Deliberately hedged twice over. The family follows from the capacity
            // only once the medium is known to be an SD card, which Limen takes from
            // the reader's own description rather than from the capacity; and the
            // reason the rest is unavailable is what readers usually do, not a law -
            // a vendor-specific reader and driver can expose more.
            let capacity = row.capacityBytes > 0
                ? "the card's " + Fmt.bytes(Double(row.capacityBytes)) + " capacity"
                : "the card's capacity"
            let family = row.mediumClass.split(separator: " ").first.map(String.init) ?? ""
            out.append((Palette.marked("Likely \(family), based on \(capacity). Most USB "
                        + "card readers expose the card to macOS as generic storage, "
                        + "without its SD-specific metadata, so Limen cannot tell which "
                        + "bus interface (UHS-I, say) or rated speed class (V30) the "
                        + "card supports from what is available here."),
                        smallFont, Palette.inferred))
        }

        // Same rule as the row: where the bar already answers "how does this compare",
        // a second comparison beside it is noise, and the one this produced named a
        // standard picked by the very rate it was describing.
        let context = usage(row) == nil ? contextText(row) : ""
        if !context.isEmpty {
            // row.note is a fact about the interface and "best this session" is a
            // measurement; anything else on this line names a standard from a rate,
            // which is a comparison against the catalogue.
            let inferred = row.note.isEmpty && !(row.wireless && !row.linkTrusted)
            out.append((inferred ? Palette.marked(context) : context, bodyFont,
                        inferred ? Palette.inferred : NSColor.secondaryLabelColor))
        }
        if row.indexingWorthReporting, !row.indexingDisabled {
            out.append(("No .metadata_never_index marker here, so nothing is stopping "
                        + "Spotlight indexing this volume. Whether it is doing so now is "
                        + "not checked. On something you only read from, indexing is "
                        + "wear and contention for nothing - right-click the row to "
                        + "stop it, and again to allow it.", smallFont, NSColor.systemRed))
        }
        if !row.appleName.isEmpty {
            // Its own line. Squeezed onto the link row beside the badge and the speed
            // it had nowhere to go and was being cut mid-word.
            // Not something Limen was told. macOS reports a numeric device-speed
            // code; this name comes from Limen's own catalogue entry for it, so it is
            // "also known as", not "Apple calls this".
            let names = [row.alsoKnown, row.appleName].filter { !$0.isEmpty }
            out.append(("Also known as " + names.joined(separator: "  ·  "),
                        smallFont, NSColor.secondaryLabelColor))
        }
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
            out.append((Palette.marked("The bar measures this against " + basis
                        + " - what that class of device typically manages today. It is "
                        + "not a reading of what this device is, and not a ceiling it "
                        + "reported."),
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
            out.append(Stat(label: "BEST EVER", value: Fmt.rate(row.allTimePeak, unit: unit),
                            colour: NSColor.labelColor))
        }
        if row.capacityBytes > 0 {
            // Counted once per container: several volumes of one disk share its space,
            // and each of them reports the whole disk's figures as its own.
            let used = Double(row.usedBytes)
            out.append(Stat(label: "USED", value: Fmt.bytes(used),
                            colour: TrafficListView.capacityColour(fraction: row.fullness ?? 0)))
            out.append(Stat(label: "FREE",
                            value: Fmt.bytes(Double(row.capacityBytes) - used),
                            colour: NSColor.labelColor))
        }
        return out
    }

    /// Two to a line, so the height follows from the count in one place rather than
    /// being guessed at in two.
    static func statRows(_ count: Int) -> Int { (count + 1) / 2 }

    private static let statRowHeight: CGFloat = 38

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
        if row.wireless && !row.linkTrusted {
            return row.peak > 0 ? "best this session " + Fmt.rate(row.peak, unit: unit) : ""
        }
        return Reference.context(current: row.down + row.up, peak: row.peak, unit: unit,
                                 families: row.compareFamilies.isEmpty ? nil : row.compareFamilies,
                                 roles: row.compareRoles.isEmpty ? nil : row.compareRoles,
                                 internalMedium: row.internalMedium,
                                 kinds: row.mediumKinds.isEmpty ? nil : row.mediumKinds)
    }

    private func cardText(_ row: Row) -> String {
        Row.cardLabel(class: row.mediumClass, volumes: row.volumes)
    }

    private func hasLinkRow(_ row: Row) -> Bool {
        !row.badge.isEmpty || (row.linkTrusted && row.linkBits > 0) || !row.appleName.isEmpty
    }

    /// Exactly as tall as its content needs, so nothing is ever cut off.
    var fittingHeight: CGFloat {
        guard let row = row else { return 120 }
        let pad = MagnifierView.pad
        var height = pad + 26                                    // icon + title
        if !cardText(row).isEmpty { height += 28 }               // the card badge
        for block in blocks(for: row) {
            height += Text.wrappedHeight(block.text, font: block.font, width: contentWidth) + 5
        }
        if hasLinkRow(row) { height += 26 }
        if usage(row) != nil { height += 28 }
        height += 10 + 14 + MagnifierView.chartHeight + 12       // scale labels + chart
        height += 46                                             // the two big rates
        // The grid, then the one line saying where its counters come from.
        let statCount = stats(for: row).count
        if statCount > 0 {
            height += CGFloat(MagnifierView.statRows(statCount)) * MagnifierView.statRowHeight
            height += 26
        }
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
                   color: NSColor.secondaryLabelColor)
        Text.draw(row.title, at: NSPoint(x: left + 28, y: y + 1),
                  font: titleFont, color: NSColor.labelColor)
        y += 24

        // The card gets a badge of its own, directly under the device it is sitting in
        // and above everything else - it is what the row is actually about.
        let cardLabel = cardText(row)
        if !cardLabel.isEmpty {
            _ = Text.drawBadge(Palette.mark + cardLabel, at: NSPoint(x: left, y: y + 2),
                               font: cardBadgeFont,
                               fill: Palette.cardBadge,
                               textColor: NSColor.labelColor)
            y += 28
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
        if hasLinkRow(row) {
            var x = left
            if !row.badge.isEmpty {
                x += Text.drawBadge(row.badge, at: NSPoint(x: x, y: y + 2),
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
                Text.draw("raw signalling", at: NSPoint(x: x, y: y + 5), font: smallFont,
                          color: Palette.faint)
                x += Text.width("raw signalling", font: smallFont) + 8
                // What the catalogue says that standard actually sustains. An estimate,
                // so it is marked like every other estimate.
                if let ceiling = Reference.ceiling(forLinkBits: row.linkBits,
                                                   family: row.compareFamilies.contains(.network)
                                                        ? .network : .usb),
                   ceiling.bytes > 0 {
                    let practical = Palette.marked(Fmt.rate(ceiling.bytes, unit: .bytes)
                                                   + " in practice")
                    Text.draw(practical, at: NSPoint(x: x, y: y + 5), font: smallFont,
                              color: Palette.inferred)
                }
            }
            y += 26
        }

        // ---- history, labelled with its own scale ---------------------------
        y += 10
        let scale = Chart.peak(down: row.downHist, up: row.upHist)
        let span = Double(Monitor.historyLength) * sampleInterval
        Text.draw(span >= 120 ? String(format: "last %.0f min", span / 60)
                              : String(format: "last %.0f s", span),
                  at: NSPoint(x: left, y: y), font: tickFont, color: Palette.faint)
        Text.draw(Fmt.rate(scale, unit: unit) + " full scale",
                  at: NSPoint(x: 0, y: y), font: tickFont,
                  color: NSColor.secondaryLabelColor, alignRight: left + width)
        y += 14
        Palette.faint.setFill()
        NSRect(x: left, y: y, width: width, height: 1).fill()

        let chart = NSRect(x: left, y: y, width: width, height: MagnifierView.chartHeight)
        NSGraphicsContext.saveGraphicsState()
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: chart.maxY + chart.minY)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        Chart.draw(down: row.downHist, up: row.upHist, in: chart, lineWidth: 1.8)
        NSGraphicsContext.restoreGraphicsState()
        y += MagnifierView.chartHeight + 12

        // ---- live rates -----------------------------------------------------
        let mid = left + width / 2
        Text.draw(row.inLong, at: NSPoint(x: left, y: y), font: tagFont, color: Palette.down)
        Text.draw(row.outLong, at: NSPoint(x: mid, y: y), font: tagFont, color: Palette.up)
        Text.draw(Fmt.rate(row.down, unit: unit), at: NSPoint(x: left, y: y + 13),
                  font: rateFont, color: Palette.down)
        Text.draw(Fmt.rate(row.up, unit: unit), at: NSPoint(x: mid, y: y + 13),
                  font: rateFont, color: Palette.up)
        y += 46

        // A bar as well as a number: the share of a link is a proportion, and a
        // proportion is read faster as a length than as text.
        if let gauge = usage(row) {
            let used = gauge.fraction
            let barWidth = width - 132
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
            Text.draw(gauge.isInferred ? Palette.marked(gauge.label) : gauge.label,
                      at: NSPoint(x: bar.maxX + 10, y: y),
                      font: smallFont,
                      color: gauge.isInferred ? Palette.inferred
                           : (used >= 0.85 ? NSColor.systemOrange
                                           : NSColor.secondaryLabelColor))
            y += 28
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

        for block in footerBlocks(for: row) {
            let h = Text.wrappedHeight(block.text, font: block.font, width: width)
            Text.drawWrapped(block.text, in: NSRect(x: left, y: y, width: width, height: h),
                             font: block.font, color: block.color)
            y += h + 4
        }
    }
}
