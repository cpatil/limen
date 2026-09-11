import Foundation

/// A well-known transport speed, used to put a measured rate in context.
///
/// `line` is the signalling rate the standard advertises. `payload` is what a real
/// transfer sustains once encoding and protocol overhead are paid. The gap is large
/// and it is the interesting part: 8b/10b line coding costs USB 3.0 a fifth of its
/// headline number before a single byte of framing, so a "5 Gbit/s" port tops out
/// nearer 450 MB/s. Judging a device against the advertised figure alone makes
/// every device look broken.
///
/// The names matter too. The USB-IF has renamed the same wire three times, and
/// Apple's System Information uses its own vocabulary again, so an entry carries
/// both and the UI shows how they relate.
struct SpeedRef {
    enum Family: String {
        case usb, network, storage
    }

    let name: String
    let appleName: String?
    let alias: String?
    let line: Double
    let payload: Double
    let family: Family
    /// bus, card or disk - whether this is a connection or a medium.
    let role: String?
    /// The standard that supersedes this one, by name.
    let upgrade: String?
    let upgradeNote: String?
    let mainstream: Bool?
    /// "external" when this medium only exists on the end of a cable.
    let mount: String?
    /// ssd | spinning | flash, when the catalogue says.
    let kind: String?

    var payloadBytes: Double { payload / 8 }

    /// "USB 3.2 Gen 1 (Apple: USB 3.0 SuperSpeed)" when the two differ.
    var bothNames: String {
        guard let apple = appleName, apple != name else { return name }
        return "\(name) (Apple: \(apple))"
    }
}

enum Reference {
    private static let Mb = 1_000_000.0
    private static let Gb = 1_000_000_000.0

    /// Loaded from the catalogue rather than hardcoded, so new transports arrive by
    /// updating a JSON file instead of shipping a build.
    static let all: [SpeedRef] = Catalogue.load().entries.map { e in
        SpeedRef(name: e.name, appleName: e.appleName, alias: e.alias,
                 line: e.line, payload: e.payload,
                 family: SpeedRef.Family(rawValue: e.family) ?? .usb,
                 role: e.role, upgrade: e.upgrade, upgradeNote: e.upgradeNote,
                 mainstream: e.mainstream, mount: e.mount, kind: e.kind)
    }

    static func entry(named name: String) -> SpeedRef? {
        all.first { $0.name == name }
    }

    /// The yardstick for a kind of device: what a buyer would get today.
    ///
    /// Fixed on purpose. Picking the catalogue entry nearest the observed rate - the
    /// obvious thing, and what this used to do - produces a denominator chosen by the
    /// number it is meant to judge, so the answer is always "about 100% of itself" and
    /// the name it reports is whatever the device happened to be doing at the time.
    static func modern(roles: [String]?, families: [SpeedRef.Family]?,
                       kinds: [String]? = nil, internalMedium: Bool = false) -> SpeedRef? {
        guard let role = roles?.first, let family = families?.first else { return nil }
        // A drive inside the machine is judged against what is inside machines today.
        // "A modern drive" meant a mainstream SATA SSD at 550 MB/s, so an internal
        // NVMe read 0% of a yardstick it passes eight times over, and its best-ever
        // mark sat pinned to the end of the bar as though it had only just reached it.
        //
        // Narrowed only for internal media, and only by what the system reported the
        // medium to be. A portable drive on a cable is limited by the cable, and
        // measuring it against an internal NVMe would be the same category error in
        // the other direction.
        if internalMedium, let kinds = kinds, !kinds.isEmpty {
            let inside = ladder(role: role, family: family).filter {
                kinds.contains($0.kind ?? "") && $0.mount != "external"
            }
            // The fastest of the entries flagged mainstream, not the slowest: the
            // ladder is ordered slowest-first, and inside a machine the slowest thing
            // still called mainstream is a decade old.
            if let best = inside.last(where: { $0.mainstream == true }) { return best }
        }
        return mainstream(role: role, family: family)
    }

    /// True when this row is judged against what is inside machines rather than what
    /// is sold to plug into them.
    static func modernIsInternal(kinds: [String]?, internalMedium: Bool) -> Bool {
        internalMedium && !(kinds ?? []).isEmpty
    }

    /// What to call that yardstick in a sentence.
    static func modernNoun(role: String?, internal isInternal: Bool = false) -> String {
        switch role {
        case "card": return "a modern card"
        case "disk": return isInternal ? "a modern internal drive" : "a modern drive"
        default: return "a modern device of this kind"
        }
    }

    /// What a buyer would sensibly choose today for this kind of medium.
    static func mainstream(role: String, family: SpeedRef.Family) -> SpeedRef? {
        ladder(role: role, family: family).first { $0.mainstream == true }
    }

    /// Every standard of one role, slowest first - the ladder advice walks.
    static func ladder(role: String, family: SpeedRef.Family) -> [SpeedRef] {
        all.filter { $0.role == role && $0.family == family }
            .sorted { $0.payload < $1.payload }
    }

    /// The standard matching a negotiated link rate, for naming a port.
    static func standard(forLinkBits linkBits: UInt64, family: SpeedRef.Family? = nil) -> SpeedRef? {
        guard linkBits > 0 else { return nil }
        let line = Double(linkBits)
        // Scoped by family because line rates collide across them: 5 Gbit/s is USB 3.2
        // Gen 1 on a port and 5G Ethernet on a wire, and 10 Gbit/s is likewise both.
        let pool = all.filter { $0.role == "bus" && (family == nil || $0.family == family!) }
        return pool.first { abs($0.line - line) / max($0.line, line) < 0.02 }
            ?? all.first { $0.role == "bus" && abs($0.line - line) / max($0.line, line) < 0.02 }
    }

    /// The reference closest to a measured rate, compared in log space so "half of"
    /// and "twice" count as equally near.
    /// The nearest reference speed, optionally narrowed to a family and a role.
    ///
    /// Role matters as much as family. "Storage" covers both a card in a reader and a
    /// drive on a cable, and they are not each other's yardstick: telling someone their
    /// portable disk is running at "52% of an SD card" compares it to a medium it will
    /// never be. A card is measured against cards, a disk against disks.
    static func nearest(bytesPerSec: Double, families: [SpeedRef.Family]? = nil,
                        roles: [String]? = nil, internalMedium: Bool = false,
                        kinds: [String]? = nil) -> SpeedRef? {
        guard bytesPerSec > 1024 else { return nil }
        let bits = bytesPerSec * 8
        var pool = families.map { fams in all.filter { fams.contains($0.family) } } ?? all
        if let roles = roles, !roles.isEmpty {
            let narrowed = pool.filter { roles.contains($0.role ?? "") }
            // Never narrow to nothing: a catalogue that lacks the role still has to
            // produce some comparison rather than falling silent.
            if !narrowed.isEmpty { pool = narrowed }
        }
        if let kinds = kinds, !kinds.isEmpty {
            // What the drive is, when the system already told us. Throughput cannot
            // establish this and should not be asked to: an idle SSD was being matched
            // against a spinning disk purely because it was idle.
            let matching = pool.filter { kinds.contains($0.kind ?? "") }
            if !matching.isEmpty { pool = matching }
        }
        if internalMedium {
            // A drive inside the machine is not a USB stick or a bus-powered portable,
            // however similar the numbers happen to look.
            let inside = pool.filter { $0.mount != "external" }
            if !inside.isEmpty { pool = inside }
        }
        return pool.min { a, b in
            abs(log(bits / a.payload)) < abs(log(bits / b.payload))
        }
    }

    /// What a rate means, in one short phrase.
    ///
    /// The kind of device is named from the best it has been seen to do, not from
    /// whatever it happens to be doing now. Anchoring on the momentary rate meant an
    /// idle SSD was matched against a spinning disk and reported as "7% of desktop
    /// hard disk" - a class decided by how busy the device was, which is backwards.
    ///
    /// Once the class is settled, a rate near that class's ceiling is worth saying
    /// outright; anything else is more usefully expressed as what this kind of device
    /// is expected to do, so a low number reads as "idle" rather than as "bad".
    static func context(current: Double, peak: Double, unit: RateUnit,
                        families: [SpeedRef.Family]? = nil,
                        roles: [String]? = nil, internalMedium: Bool = false,
                        kinds: [String]? = nil) -> String {
        let anchor = max(current, peak)
        guard let ref = nearest(bytesPerSec: anchor, families: families,
                                roles: roles, internalMedium: internalMedium, kinds: kinds)
        else { return "" }

        if current > 0 {
            let ratio = (current * 8) / ref.payload
            if ratio > 0.85 && ratio < 1.18 { return "≈ " + ref.name }
            if ratio >= 1.18 { return String(format: "%.1f× %@", ratio, ref.name) }
        }
        return ref.name + " · typically " + Fmt.rate(ref.payloadBytes, unit: unit)
    }

    /// "≈ Gigabit Ethernet" when it is close, "2.1× USB 2.0" when it is not.
    static func comparison(bytesPerSec: Double, families: [SpeedRef.Family]? = nil,
                           roles: [String]? = nil, internalMedium: Bool = false) -> String {
        guard let ref = nearest(bytesPerSec: bytesPerSec, families: families,
                                roles: roles, internalMedium: internalMedium)
        else { return "" }
        let ratio = (bytesPerSec * 8) / ref.payload
        if ratio > 0.85 && ratio < 1.18 { return "≈ " + ref.name }
        if ratio >= 1 { return String(format: "%.1f× %@", ratio, ref.name) }
        return String(format: "%.0f%% of %@", ratio * 100, ref.name)
    }

    /// The realistic ceiling for a link advertising `linkBits`, and the standard's name.
    static func ceiling(forLinkBits linkBits: UInt64,
                        family: SpeedRef.Family? = nil) -> (bytes: Double, name: String)? {
        guard linkBits > 0 else { return nil }
        if let ref = standard(forLinkBits: linkBits, family: family) {
            return (ref.payloadBytes, ref.name)
        }
        // Unknown standard: assume the usual ~15% of a link goes to overhead rather
        // than pretending the advertised rate is reachable.
        return (Double(linkBits) * 0.85 / 8, "")
    }

    /// Whether the advertised link rate can be trusted as a ceiling.
    ///
    /// macOS reports `ifi_baudrate` for Wi-Fi as whatever PHY rate it last latched
    /// onto - often a basic or stale rate far below real throughput - and reports
    /// absurd values (100 bit/s) for adapters with no carrier. Measuring traffic
    /// above the supposed ceiling proves the figure is not one, and a wrong
    /// denominator is worse than no denominator: it produced "270% of link".
    static func linkRateIsCredible(observedBytesPerSec: Double, linkBits: UInt64) -> Bool {
        // No real interface runs below 1 Mbit/s. macOS reports 100 bit/s for adapters
        // with no carrier, which is constant and never contradicted by traffic, so
        // the other checks would happily accept it.
        guard linkBits >= 1_000_000 else { return false }
        guard let cap = ceiling(forLinkBits: linkBits), cap.bytes > 0 else { return false }
        return observedBytesPerSec <= cap.bytes * 1.1
    }

    /// How much of the link's realistic ceiling is in use, 0...1+.
    ///
    /// Takes the busier direction rather than the sum. Ethernet and USB 3 are full
    /// duplex: a gigabit link carrying 600 Mbit/s each way is at 60% in each
    /// direction, not 128% of one ceiling. Summing produced utilisation above 100%
    /// on a perfectly healthy link, and made credible link rates look like nonsense.
    static func utilization(down: Double, up: Double, linkBits: UInt64) -> Double? {
        guard let cap = ceiling(forLinkBits: linkBits), cap.bytes > 0 else { return nil }
        return max(down, up) / cap.bytes
    }

    /// Which SD family a card belongs to, named from the capacity of the medium.
    ///
    /// The reader presents the card as generic USB mass storage, so the card's own CID
    /// and CSD registers - which would state this outright - are out of reach. But the
    /// SD specification draws the family boundaries strictly by capacity, so the size
    /// of the medium settles it: over 32 GiB is SDXC and nothing else.
    ///
    /// Speed class is a different question and deliberately not answered here. Nothing
    /// about UHS-I, UHS-II, U3 or V30 crosses a USB mass-storage bridge, so the only
    /// honest source for it is what the card actually sustains - which is what the
    /// advice below infers from measurement.
    static func mediumClass(bytes: UInt64, deviceName: String, removable: Bool) -> String {
        // Only for media that is genuinely removable and sits in something that reads
        // cards. A 64 GB USB stick is also removable-ish, and calling it "SDXC" would
        // be a confident falsehood.
        guard removable, bytes > 0 else { return "" }
        let name = deviceName.lowercased()
        guard name.contains("card") || name.contains("reader") || name.contains("sd") else {
            return ""
        }
        // The SD Association states these boundaries in decimal GB, and the card's
        // capacity is quoted the same way. Using GiB moved every boundary up by 7%,
        // which misfiled anything between 32.0 GB and 32 GiB - a 32 GB card, which is
        // SDHC by the standard, was reported as SDXC. Closed ranges because each
        // boundary belongs to the family below it: 32 GB is the largest SDHC.
        let GB = 1_000_000_000.0
        let size = Double(bytes)
        let family: String
        switch size {
        case ...(2 * GB):    family = "SDSC"
        case ...(32 * GB):   family = "SDHC"
        case ...(2000 * GB): family = "SDXC"
        default:             family = "SDUC"
        }
        return family + " " + Fmt.bytes(size)
    }

    /// What a row's usage bar should show, and what to call it.
    ///
    /// A link ceiling when there is a believable one. Otherwise the fastest this
    /// device has actually been seen to go - which is why Wi-Fi and the internal drive
    /// get a bar at all: Wi-Fi reports a negotiated rate it never achieves, and an
    /// internal drive has no cable to negotiate over, so measuring against their own
    /// best says something true where a made-up specification would not.
    /// What the bar shows, what to call it, and whether it was measured or worked out.
    struct Gauge {
        let fraction: Double
        let label: String
        /// True when the denominator is a negotiated link rate the system reported -
        /// a real ceiling, so the proportion is a measurement. False when it is what
        /// this class of device typically manages, which is a comparison against a
        /// catalogue and therefore an inference.
        let ofLink: Bool
        /// The yardstick this was measured against, as a noun phrase - "a modern
        /// drive, around 550 MB/s (SATA SSD)". A phrase rather than a sentence because
        /// the callers put it inside one; when this held a sentence of its own, the
        /// card read "compares this with a modern drive is around 550 MB/s. This
        /// device is not being identified. - what this class typically manages".
        let basis: String?
        /// The same reading with the yardstick spelled out - "13% of a modern card
        /// (90 MB/s)". `label` is the short form for a row that has about a hundred
        /// points to spend; this is what anywhere with room should show, because a
        /// percentage of an unstated number is not a fact the reader can use.
        let longLabel: String
        /// What the percentage is a percentage of, in bytes per second. Lets anything
        /// else on the bar - an all-time peak, say - be placed on the same scale.
        let denominatorBytes: Double

        var isInferred: Bool { !ofLink }
    }

    static func gauge(down: Double, up: Double, peakDirectional: Double, peak: Double,
                      linkBits: UInt64, linkTrusted: Bool,
                      families: [SpeedRef.Family]? = nil, roles: [String]? = nil,
                      internalMedium: Bool = false,
                      kinds: [String]? = nil,
                      hasKnownClass: Bool = true) -> Gauge? {
        let current = max(down, up)

        // A negotiated link is a real ceiling, so this is a real proportion.
        if linkTrusted,
           linkRateIsCredible(observedBytesPerSec: max(current, peakDirectional),
                              linkBits: linkBits),
           let used = utilization(down: down, up: up, linkBits: linkBits) {
            let text = String(format: "%.0f%% link utilization", used * 100)
            return Gauge(fraction: used, label: text, ofLink: true, basis: nil,
                         // The link's own figure is already on the row, in the badge
                         // beside the device's name, so there is nothing to add here.
                         longLabel: text,
                         denominatorBytes: ceiling(forLinkBits: linkBits)?.bytes ?? 0)
        }

        // No trustworthy ceiling. What this kind of device typically manages is the
        // nearest thing to one, and it is at least a statement about capability.
        // Measuring a device against its own past - the previous behaviour - only ever
        // answered "is it working as hard as it has before", which is not a capacity.
        //
        // Only where the kind of device is actually known. A Wi-Fi interface has no
        // medium in the catalogue, so the nearest entry to its rate was whatever wired
        // standard happened to sit near it - it read "100% of typical" at 10 Mbit/s
        // because it had been matched against 10 Mbit Ethernet, which is a category
        // error and a circular one: the yardstick was chosen by the rate it measures.
        // No "current > 0" here. Dropping the bar whenever the device went quiet made
        // it flash in and out once a second, taking the label and the row's layout
        // with it - and an idle device is a reading, not an absence of one.
        guard hasKnownClass,
              let ref = modern(roles: roles, families: families,
                               kinds: kinds, internalMedium: internalMedium),
              ref.payloadBytes > 0
        else { return nil }
        let noun = modernNoun(role: roles?.first,
                              internal: modernIsInternal(kinds: kinds,
                                                         internalMedium: internalMedium))
        let ratio = current / ref.payloadBytes
        let fraction = min(1.0, ratio)
        let yardstick = Fmt.rate(ref.payloadBytes, unit: .bytes)
        // Above the yardstick the percentage stops meaning anything useful - it is
        // pinned at full and says nothing about how far past it the device is.
        //
        // Both forms carry the figure. "13% of a modern card" reads as a fact and is
        // not one unless you already know what a modern card does; the number is the
        // part that lets someone disagree with the comparison.
        let label = ratio >= 1
            ? "at or above " + yardstick
            : String(format: "%.0f%% of %@", fraction * 100, yardstick)
        let longLabel = ratio >= 1
            ? "at or above " + noun + " (" + yardstick + ")"
            : String(format: "%.0f%% of %@ (%@)", fraction * 100, noun, yardstick)
        return Gauge(fraction: fraction, label: label, ofLink: false,
                     basis: noun + ", around " + yardstick + " (" + ref.name + ")",
                     longLabel: longLabel,
                     denominatorBytes: ref.payloadBytes)
    }

    /// A quiet, evidence-based note about a removable device: what is limiting it and
    /// what would actually help.
    ///
    /// Deliberately inferred from measurement rather than claimed specification. A
    /// card reader does not report the card's UHS class - it presents as USB mass
    /// storage - but a transfer that plateaus near 90 MB/s on a link good for 450
    /// MB/s has told you what the card is. Hints only appear once enough traffic has
    /// been seen to mean something, so an idle device stays quiet.
    /// How much has to have moved before the medium itself can be judged.
    ///
    /// A peak is only evidence of what a device can do once it has been given the
    /// chance to do it. Reading 20 MB of small files at 12 MB/s says nothing about the
    /// card: a fast card reading a directory tree looks exactly like a slow card
    /// reading a single file. Calling that "slow for a modern card" was an assertion
    /// with no measurement behind it.
    static let judgementFloor: Double = 512 * 1024 * 1024

    static func advice(peakBytesPerSec: Double, linkBits: UInt64,
                       isStorage: Bool, removableMedia: Bool,
                       bytesMoved: Double = .greatestFiniteMagnitude) -> String {
        guard isStorage, peakBytesPerSec > 4_000_000 else { return "" }
        let peakBits = peakBytesPerSec * 8
        let evidence = " (peaked at " + Fmt.rate(peakBytesPerSec, unit: .bytes)
            + " over " + Fmt.bytes(bytesMoved) + ")"
        // Judgements about the port do not need a big sample - the link rate is
        // reported, not inferred. Judgements about the medium do.
        let enoughToJudgeMedium = bytesMoved >= judgementFloor

        // Connected below the device's own potential: the port or cable is the fault,
        // and that is worth saying because it is trivially fixable.
        if linkBits > 0 && linkBits <= 480_000_000 {
            return "connected at USB 2.0 — a USB 3 port would lift this ceiling"
        }

        guard let cap = ceiling(forLinkBits: linkBits), cap.bytes > 0 else { return "" }
        let headroom = peakBytesPerSec / cap.bytes

        // Plateauing well under the link ceiling means the media is the limit. Around
        // 90 MB/s that is almost certainly a UHS-I card, whose bus tops out at 104.
        if headroom < 0.45, enoughToJudgeMedium {
            // The UHS ceilings only mean anything for a card in a reader. A portable
            // hard disk sits in the same throughput band for entirely different
            // reasons, and telling someone to buy a faster card would be nonsense.
            if removableMedia, peakBits > 560 * 1_000_000, peakBits < 900 * 1_000_000 {
                return "plateauing near UHS-I's ~90 MB/s limit" + evidence + " — a UHS-II card and reader would roughly triple it"
            }
            if removableMedia, peakBytesPerSec < 45_000_000 {
                return "slower than a modern card manages" + evidence
                    + " — though a tree of small files looks the same; a UHS-I U3 or better would lift a genuinely slow card"
            }
            if !removableMedia, peakBytesPerSec > 60_000_000, peakBytesPerSec < 200_000_000 {
                return "typical of a portable hard disk" + evidence + " — an SSD would be several times faster"
            }
            if peakBytesPerSec < 60_000_000 {
                return "well under the link's ceiling" + evidence + " — the media looks like the limit rather than the port"
            }
        }
        // Worth saying plainly when a transfer is doing as well as the wire allows -
        // that is a good result, not a problem to investigate.
        if headroom >= 0.95 {
            return "at this link's practical ceiling — you cannot do better without faster hardware"
        }
        if headroom >= 0.80 {
            return String(format: "%.0f%% of what this link can carry — about as good as it gets", headroom * 100)
        }
        return ""
    }

    /// A tangible sense of scale: how long this rate needs for a familiar payload.
    static func timeToMove(bytes: Double, atBytesPerSec rate: Double) -> String {
        guard rate > 1024 else { return "" }
        let seconds = bytes / rate
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        if seconds < 90 { return String(format: "%.1f s", seconds) }
        if seconds < 5400 { return String(format: "%.0f min", seconds / 60) }
        return String(format: "%.1f h", seconds / 3600)
    }

    static let oneGigabyte = 1_000_000_000.0
}
