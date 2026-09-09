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
                 mainstream: e.mainstream, mount: e.mount)
    }

    static func entry(named name: String) -> SpeedRef? {
        all.first { $0.name == name }
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
                        roles: [String]? = nil, internalMedium: Bool = false) -> SpeedRef? {
        guard bytesPerSec > 1024 else { return nil }
        let bits = bytesPerSec * 8
        var pool = families.map { fams in all.filter { fams.contains($0.family) } } ?? all
        if let roles = roles, !roles.isEmpty {
            let narrowed = pool.filter { roles.contains($0.role ?? "") }
            // Never narrow to nothing: a catalogue that lacks the role still has to
            // produce some comparison rather than falling silent.
            if !narrowed.isEmpty { pool = narrowed }
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

    /// "≈ Gigabit Ethernet" when it is close, "2.1× USB 2.0" when it is not.
    static func comparison(bytesPerSec: Double, families: [SpeedRef.Family]? = nil,
                           roles: [String]? = nil, internalMedium: Bool = false) -> String {
        guard let ref = nearest(bytesPerSec: bytesPerSec, families: families,
                                roles: roles, internalMedium: internalMedium)
        else { return "" }
        let ratio = (bytesPerSec * 8) / ref.payload
        if ratio > 0.85 && ratio < 1.18 {
            return "≈ " + ref.name
        }
        if ratio >= 1 {
            return String(format: "%.1f× %@", ratio, ref.name)
        }
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
    static func utilization(bytesPerSec: Double, linkBits: UInt64) -> Double? {
        guard let cap = ceiling(forLinkBits: linkBits), cap.bytes > 0 else { return nil }
        return bytesPerSec / cap.bytes
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
        let giB = 1024.0 * 1024.0 * 1024.0
        let size = Double(bytes)
        let family: String
        switch size {
        case ..<(2 * giB):    family = "SDSC"
        case ..<(32 * giB):   family = "SDHC"
        case ..<(2048 * giB): family = "SDXC"
        default:              family = "SDUC"
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
    static func gauge(current: Double, peak: Double, linkBits: UInt64,
                      linkTrusted: Bool) -> (fraction: Double, label: String, ofLink: Bool)? {
        if linkTrusted,
           linkRateIsCredible(observedBytesPerSec: max(current, peak), linkBits: linkBits),
           let used = utilization(bytesPerSec: current, linkBits: linkBits) {
            return (used, String(format: "%.0f%% link utilization", used * 100), true)
        }
        guard peak > 0 else { return nil }
        let fraction = min(1.0, current / peak)
        return (fraction, String(format: "%.0f%% of its peak", fraction * 100), false)
    }

    /// A quiet, evidence-based note about a removable device: what is limiting it and
    /// what would actually help.
    ///
    /// Deliberately inferred from measurement rather than claimed specification. A
    /// card reader does not report the card's UHS class - it presents as USB mass
    /// storage - but a transfer that plateaus near 90 MB/s on a link good for 450
    /// MB/s has told you what the card is. Hints only appear once enough traffic has
    /// been seen to mean something, so an idle device stays quiet.
    static func advice(peakBytesPerSec: Double, linkBits: UInt64,
                       isStorage: Bool, removableMedia: Bool) -> String {
        guard isStorage, peakBytesPerSec > 4_000_000 else { return "" }
        let peakBits = peakBytesPerSec * 8

        // Connected below the device's own potential: the port or cable is the fault,
        // and that is worth saying because it is trivially fixable.
        if linkBits > 0 && linkBits <= 480_000_000 {
            return "connected at USB 2.0 — a USB 3 port would lift this ceiling"
        }

        guard let cap = ceiling(forLinkBits: linkBits), cap.bytes > 0 else { return "" }
        let headroom = peakBytesPerSec / cap.bytes

        // Plateauing well under the link ceiling means the media is the limit. Around
        // 90 MB/s that is almost certainly a UHS-I card, whose bus tops out at 104.
        if headroom < 0.45 {
            // The UHS ceilings only mean anything for a card in a reader. A portable
            // hard disk sits in the same throughput band for entirely different
            // reasons, and telling someone to buy a faster card would be nonsense.
            if removableMedia, peakBits > 560 * 1_000_000, peakBits < 900 * 1_000_000 {
                return "plateauing near UHS-I's ~90 MB/s limit — a UHS-II card and reader would roughly triple it"
            }
            if removableMedia, peakBytesPerSec < 45_000_000 {
                return "slow for a modern card — a UHS-I U3 or better would lift this"
            }
            if !removableMedia, peakBytesPerSec > 60_000_000, peakBytesPerSec < 200_000_000 {
                return "typical of a portable hard disk — an SSD would be several times faster"
            }
            if peakBytesPerSec < 60_000_000 {
                return "well under the link's ceiling — the media is the limit, not the port"
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
