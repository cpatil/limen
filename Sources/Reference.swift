import Foundation

/// A well-known transport speed, used to put a measured rate in context.
///
/// `line` is the signalling rate the standard advertises. `payload` is what a real
/// transfer sustains once encoding and protocol overhead are paid. The gap is large
/// and it is the interesting part: 8b/10b line coding costs USB 3.0 a fifth of its
/// headline number before a single byte of framing, so a "5 Gbit/s" port tops out
/// nearer 450 MB/s. Judging a device against the advertised figure alone makes
/// every device look broken.
struct SpeedRef {
    enum Family {
        case usb, network, storage
    }

    let name: String
    let line: Double        // bits/sec, as advertised
    let payload: Double     // bits/sec, realistically sustained
    let family: Family

    var payloadBytes: Double { payload / 8 }
}

enum Reference {
    private static let Mb = 1_000_000.0
    private static let Gb = 1_000_000_000.0

    /// Approximate but deliberately conservative: these are the numbers a healthy
    /// device actually reaches, not best-case marketing figures.
    static let all: [SpeedRef] = [
        SpeedRef(name: "USB 1.1", line: 12 * Mb, payload: 9.6 * Mb, family: .usb),
        SpeedRef(name: "USB 2.0", line: 480 * Mb, payload: 320 * Mb, family: .usb),
        SpeedRef(name: "USB 3.0", line: 5 * Gb, payload: 3.6 * Gb, family: .usb),
        SpeedRef(name: "USB 3.1 Gen 2", line: 10 * Gb, payload: 8 * Gb, family: .usb),
        SpeedRef(name: "USB 3.2 Gen 2x2", line: 20 * Gb, payload: 16 * Gb, family: .usb),
        SpeedRef(name: "Thunderbolt 3/4", line: 40 * Gb, payload: 22 * Gb, family: .usb),

        SpeedRef(name: "10 Mbit Ethernet", line: 10 * Mb, payload: 9.4 * Mb, family: .network),
        SpeedRef(name: "100 Mbit Ethernet", line: 100 * Mb, payload: 94 * Mb, family: .network),
        SpeedRef(name: "Wi-Fi 5", line: 866 * Mb, payload: 400 * Mb, family: .network),
        SpeedRef(name: "Gigabit Ethernet", line: 1 * Gb, payload: 940 * Mb, family: .network),
        SpeedRef(name: "Wi-Fi 6", line: 1.2 * Gb, payload: 700 * Mb, family: .network),
        SpeedRef(name: "2.5G Ethernet", line: 2.5 * Gb, payload: 2.35 * Gb, family: .network),
        SpeedRef(name: "10G Ethernet", line: 10 * Gb, payload: 9.4 * Gb, family: .network),

        SpeedRef(name: "SD card (UHS-I)", line: 832 * Mb, payload: 720 * Mb, family: .storage),
        SpeedRef(name: "hard disk", line: 1.2 * Gb, payload: 1.2 * Gb, family: .storage),
        SpeedRef(name: "SD card (UHS-II)", line: 2.5 * Gb, payload: 2.2 * Gb, family: .storage),
        SpeedRef(name: "SATA SSD", line: 6 * Gb, payload: 4.4 * Gb, family: .storage),
        SpeedRef(name: "NVMe (Gen 3)", line: 32 * Gb, payload: 28 * Gb, family: .storage),
        SpeedRef(name: "NVMe (Gen 4)", line: 64 * Gb, payload: 56 * Gb, family: .storage),
    ]

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
        let line = Double(linkBits)
        if let ref = all.first(where: { abs($0.line - line) / max($0.line, line) < 0.02 }) {
            return (ref.payloadBytes, ref.name)
        }
        // Unknown standard: assume the usual ~15% of a link goes to overhead rather
        // than pretending the advertised rate is reachable.
        return (line * 0.85 / 8, "")
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
        if headroom >= 0.85 {
            return "saturating the link — a faster port is the only way up"
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
