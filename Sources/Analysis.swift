import Foundation

/// Reads a finished transfer and says whether it went as fast as it could have,
/// and if not, what held it back.
enum Analysis {

    /// What limited one session.
    struct Verdict {
        var summary: String
        /// True when nothing more was available - worth saying plainly.
        var maximised: Bool
    }

    /// How steady a transfer was. A long run of large files sits near its peak the
    /// whole way; a tree of small files spends most of its time not transferring, so
    /// the average falls far below the peak even though the hardware is fine.
    private static func steadiness(_ s: TransferSession) -> Double {
        guard s.peakRate > 0 else { return 1 }
        return s.averageRate / s.peakRate
    }

    static func verdict(for s: TransferSession) -> Verdict {
        let ceiling = (s.linkTrusted == true) ? Reference.ceiling(forLinkBits: s.linkBits) : nil
        let used = ceiling.map { s.peakRate / $0.bytes } ?? 0

        if let ceiling = ceiling, used >= 0.85 {
            return Verdict(summary: String(format: "reached %.0f%% of the %@ link — nothing left to give",
                                           used * 100, ceiling.name.isEmpty ? "" : ceiling.name),
                           maximised: true)
        }

        // Near a known medium's ceiling: the card or disk was the limit, not the port.
        // Only meaningful for real hardware - a tunnel has no medium of its own.
        let families: [SpeedRef.Family] = s.section == "USB" ? [.storage] : [.network]
        if s.physical != false, let near = Reference.nearest(bytesPerSec: s.peakRate, families: families) {
            let ratio = (s.peakRate * 8) / near.payload
            if ratio > 0.85, ratio < 1.15 {
                return Verdict(summary: "peaked at about \(near.name)'s limit — the medium set the pace",
                               maximised: true)
            }
        }

        if steadiness(s) < 0.45 {
            return Verdict(summary: String(format: "stop-start: averaged only %.0f%% of its own peak, "
                                           + "which is what many small files look like",
                                           steadiness(s) * 100),
                           maximised: false)
        }

        if ceiling != nil {
            return Verdict(summary: String(format: "used %.0f%% of the link — the device at one end was slower",
                                           used * 100),
                           maximised: false)
        }
        if s.physical == false {
            return Verdict(summary: "software interface — the link beneath it sets the pace",
                           maximised: false)
        }
        return Verdict(summary: "no link rate to judge this against", maximised: false)
    }

    /// Everything recorded for one device and one volume.
    struct Group {
        var key: String
        var device: String
        var section: String
        var volumes: [String]
        var sessions: [TransferSession]

        var total: UInt64 { sessions.reduce(0) { $0 + $1.total } }
        var bestPeak: Double { sessions.map { $0.peakRate }.max() ?? 0 }
        var removable: Bool { sessions.contains { $0.removable == true } }
        var physical: Bool { sessions.contains { $0.physical == true } }
        var wireless: Bool { sessions.contains { $0.wireless == true } }
        var linkBits: UInt64 { sessions.map { $0.linkBits }.max() ?? 0 }
        var linkTrusted: Bool { sessions.contains { $0.linkTrusted == true } }
    }

    /// Sessions gathered per device and volume, newest group first.
    ///
    /// Grouped rather than listed flat because advice belongs to a piece of hardware,
    /// not to one copy: telling you to buy a faster card once is useful, telling you
    /// on every line is nagging.
    static func groups(from sessions: [TransferSession]) -> [Group] {
        var order: [String] = []
        var byKey: [String: Group] = [:]
        for s in sessions {
            let key = s.device + "|" + s.volumes.joined(separator: ",")
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = Group(key: key, device: s.device, section: s.section,
                                   volumes: s.volumes, sessions: [])
            }
            byKey[key]?.sessions.append(s)
        }
        return order.compactMap { byKey[$0] }
    }

    /// One recommendation for a group: what to change, and what it would buy.
    static func recommendation(for group: Group) -> String {
        let peak = group.bestPeak
        guard peak > 0 else { return "" }
        let ceiling = group.linkTrusted ? Reference.ceiling(forLinkBits: group.linkBits) : nil
        let used = ceiling.map { peak / $0.bytes } ?? 0

        if group.section != "USB" {
            // Tunnels, bridges and loopback are software. Recommending a cable for a
            // VPN interface would be nonsense: its speed follows the physical link
            // beneath it, minus encryption.
            if !group.physical {
                return "A software interface — its speed follows the physical link "
                    + "underneath it, less the cost of encryption or bridging. "
                    + "Look at the interface it rides over to find the real limit."
            }
            if group.wireless {
                return "Wi-Fi tops out well below wired Ethernet — a cable would be "
                    + "several times faster for bulk copies."
            }
            if used >= 0.85, let ceiling = ceiling {
                return "Saturating \(ceiling.name). Only a faster network gets more."
            }
            return "The far end, not this link, is setting the pace here."
        }

        // Storage.
        if used >= 0.85, let ceiling = ceiling {
            return "Saturating \(ceiling.name) at \(Fmt.rate(peak, unit: .bytes)). "
                + "Only a faster port would help — the drive is already ahead of the bus."
        }

        if group.removable {
            let peakBits = peak * 8
            if peakBits > 560_000_000, peakBits < 900_000_000 {
                return "Peaks at \(Fmt.rate(peak, unit: .bytes)), right at UHS-I's ceiling. "
                    + "A UHS-II card and a UHS-II reader would roughly triple this; nothing else here is the limit."
            }
            if peak < 45_000_000 {
                return "Peaks at only \(Fmt.rate(peak, unit: .bytes)) on a link good for "
                    + "\(Fmt.rate(ceiling?.bytes ?? 0, unit: .bytes)). This is a slow card — "
                    + "a UHS-I U3 or better would lift it several times over."
            }
            return "The card, not the reader or the port, is setting the pace."
        }

        if peak < 200_000_000 {
            return "Peaks at \(Fmt.rate(peak, unit: .bytes)), typical of a spinning disk. "
                + "An SSD in the same enclosure would be several times faster."
        }
        return "Running well within the link — the drive is the limit, and it is a fast one."
    }

    /// A short note on how the copies themselves behaved, when that is the real story.
    static func pattern(for group: Group) -> String {
        let steady = group.sessions.filter { $0.peakRate > 0 }
            .map { $0.averageRate / $0.peakRate }
        guard !steady.isEmpty else { return "" }
        let mean = steady.reduce(0, +) / Double(steady.count)
        if mean < 0.45 {
            return String(format: "Averaging %.0f%% of peak across %d sessions — lots of small files. "
                          + "Copying an archive or disk image instead moves the same bytes far faster.",
                          mean * 100, group.sessions.count)
        }
        return ""
    }
}
