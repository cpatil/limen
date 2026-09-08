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
                 family: SpeedRef.Family(rawValue: e.family) ?? .usb)
    }

    /// The standard matching a negotiated link rate, for naming a port.
    static func standard(forLinkBits linkBits: UInt64) -> SpeedRef? {
        guard linkBits > 0 else { return nil }
        let line = Double(linkBits)
        return all.first { abs($0.line - line) / max($0.line, line) < 0.02 }
    }

    /// The reference closest to a measured rate, compared in log space so "half of"
    /// and "twice" count as equally near.
    static func nearest(bytesPerSec: Double, families: [SpeedRef.Family]? = nil) -> SpeedRef? {
        guard bytesPerSec > 1024 else { return nil }
        let bits = bytesPerSec * 8
        let pool = families.map { fams in all.filter { fams.contains($0.family) } } ?? all
        return pool.min { a, b in
            abs(log(bits / a.payload)) < abs(log(bits / b.payload))
        }
    }

    /// "≈ Gigabit Ethernet" when it is close, "2.1× USB 2.0" when it is not.
    static func comparison(bytesPerSec: Double, families: [SpeedRef.Family]? = nil) -> String {
        guard let ref = nearest(bytesPerSec: bytesPerSec, families: families) else { return "" }
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
    static func ceiling(forLinkBits linkBits: UInt64) -> (bytes: Double, name: String)? {
        guard linkBits > 0 else { return nil }
        if let ref = standard(forLinkBits: linkBits) {
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
        guard let cap = ceiling(forLinkBits: linkBits), cap.bytes > 0 else { return false }
        return observedBytesPerSec <= cap.bytes * 1.1
    }

    /// How much of the link's realistic ceiling is in use, 0...1+.
    static func utilization(bytesPerSec: Double, linkBits: UInt64) -> Double? {
        guard let cap = ceiling(forLinkBits: linkBits), cap.bytes > 0 else { return nil }
        return bytesPerSec / cap.bytes
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
        guard isStorage, peakBytesPerSec > 4 * 1024 * 1024 else { return "" }
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
            if removableMedia, peakBytesPerSec < 45 * 1024 * 1024 {
                return "slow for a modern card — a UHS-I U3 or better would lift this"
            }
            if !removableMedia, peakBytesPerSec > 60 * 1024 * 1024, peakBytesPerSec < 200 * 1024 * 1024 {
                return "typical of a portable hard disk — an SSD would be several times faster"
            }
            if peakBytesPerSec < 60 * 1024 * 1024 {
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

    static let oneGigabyte = 1024.0 * 1024 * 1024
}
