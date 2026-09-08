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

    // ---- deriving advice from the catalogue ----------------------------
    //
    // None of this names a protocol. The catalogue says what supersedes what and how
    // fast each thing really is, so recommending a newer standard is a lookup and a
    // division. Adding SD Express 9.0 or USB4 v3 to the JSON makes it recommendable
    // without touching this file.

    /// How close a measurement must sit to a standard's payload to count as "at its
    /// limit". A judgement about reading measurements, not a fact about any protocol,
    /// which is why it belongs in code.
    private static let atLimitBand = 0.15
    private static let saturated = 0.85

    private static func times(_ factor: Double) -> String {
        factor >= 10 ? String(format: "%.0f×", factor) : String(format: "%.1f×", factor)
    }

    /// "X would be about 3.1× faster", derived from the graph.
    private static func step(from current: SpeedRef) -> String? {
        guard let name = current.upgrade, let next = Reference.entry(named: name),
              current.payloadBytes > 0 else { return nil }
        var text = "\(next.name) would be about \(times(next.payloadBytes / current.payloadBytes)) faster"
        if let note = current.upgradeNote { text += ", " + note }
        return text
    }

    private static func atLimit(of candidates: [SpeedRef], peak: Double) -> SpeedRef? {
        candidates.first { ref in
            let ratio = peak / ref.payloadBytes
            return ratio > 1 - atLimitBand && ratio < 1 + atLimitBand
        }
    }

    /// One recommendation for a group: what to change, and what it would buy.
    static func recommendation(for group: Group) -> String {
        let peak = group.bestPeak
        guard peak > 0 else { return "" }
        let family: SpeedRef.Family = group.section == "USB" ? .storage : .network

        if group.section != "USB" {
            // Tunnels and bridges are software: their speed follows the link beneath.
            if !group.physical {
                return "A software interface — its speed follows the physical link "
                    + "underneath it, less the cost of encryption or bridging. "
                    + "Look at the interface it rides over to find the real limit."
            }
            let wired = Reference.ladder(role: "bus", family: .network)
                .first { $0.name.contains("Gigabit") }
            if group.wireless, let wired = wired, wired.payloadBytes > peak * 1.5 {
                return "Wi-Fi peaks at \(Fmt.rate(peak, unit: .bytes)) here. "
                    + "\(wired.name) would be about \(times(wired.payloadBytes / peak)) faster "
                    + "for bulk copies."
            }
        }

        // 1. Is the connection itself the limit?
        if group.linkTrusted, let link = Reference.standard(forLinkBits: group.linkBits),
           link.payloadBytes > 0, peak / link.payloadBytes >= saturated {
            if let next = step(from: link) {
                return "Saturating \(link.name) at \(Fmt.rate(peak, unit: .bytes)). \(next)."
            }
            return "Saturating \(link.name) at \(Fmt.rate(peak, unit: .bytes)) — "
                + "nothing faster exists in this family."
        }

        // 2. Otherwise the medium is. Place it on the ladder for its kind.
        let role = group.section == "USB" ? (group.removable ? "card" : "disk") : "bus"
        let ladder = Reference.ladder(role: role, family: family)
        guard !ladder.isEmpty else { return "The device, not the link, is setting the pace." }

        if let here = atLimit(of: ladder, peak: peak) {
            if let next = step(from: here) {
                return "Peaks at \(Fmt.rate(peak, unit: .bytes)), right at \(here.name)'s limit. \(next)."
            }
            return "Peaks at \(here.name)'s limit, and nothing faster exists in this family."
        }

        // Below the slowest rung. A long way below means the item is simply poor for
        // its class and meeting that rung is the advice; only a little below means the
        // rung is the floor for this kind of device - a slow hard disk is still a hard
        // disk - so the next rung up is what actually helps.
        if let slowest = ladder.first, peak < slowest.payloadBytes * (1 - atLimitBand) {
            if slowest.payloadBytes / peak >= 2 {
                return "Peaks at only \(Fmt.rate(peak, unit: .bytes)) — below even \(slowest.name), "
                    + "which would be about \(times(slowest.payloadBytes / peak)) faster."
            }
            if let next = slowest.upgrade.flatMap({ Reference.entry(named: $0) }) {
                return "Peaks at \(Fmt.rate(peak, unit: .bytes)), about what \(slowest.name) does. "
                    + "\(next.name) would be about \(times(next.payloadBytes / peak)) faster."
            }
        }

        // Between two rungs: name the next one up.
        if let next = ladder.first(where: { $0.payloadBytes > peak * (1 + atLimitBand) }) {
            return "Peaks at \(Fmt.rate(peak, unit: .bytes)). "
                + "\(next.name) would be about \(times(next.payloadBytes / peak)) faster."
        }
        return "Running at the top of what this class of device does."
    }

    /// A short note on how the copies themselves behaved, when that is the real story.
    static func pattern(for group: Group) -> String {
        let steady = group.sessions.filter { $0.peakRate > 0 }
            .map { $0.averageRate / $0.peakRate }
        guard !steady.isEmpty else { return "" }
        let mean = steady.reduce(0, +) / Double(steady.count)
        if mean < 0.45 {
            let n = group.sessions.count
            return String(format: "Averaging %.0f%% of peak across %d session%@ — lots of small files. "
                          + "Copying an archive or disk image instead moves the same bytes far faster.",
                          mean * 100, n, n == 1 ? "" : "s")
        }
        return ""
    }
}
