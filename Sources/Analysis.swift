import Foundation

/// Reads a finished transfer and says whether it went as fast as it could have,
/// and if not, what held it back.
enum Analysis {

    /// What limited one session.
    struct Verdict {
        var summary: String
        /// True when nothing more was available - worth saying plainly.
        var maximised: Bool
        /// True when this reading was worked out rather than measured. A link
        /// utilisation is arithmetic on two reported numbers; "consistent with an
        /// SDXC card's ceiling" is a match against a catalogue that cannot rule out a
        /// slow reader, the far end, the workload, or a hot device.
        var inferred: Bool = false
    }

    /// How steady a transfer was. A long run of large files sits near its peak the
    /// whole way; a tree of small files spends most of its time not transferring, so
    /// the average falls far below the peak even though the hardware is fine.
    private static func steadiness(_ s: TransferSession) -> Double {
        guard s.peakRate > 0 else { return 1 }
        return s.averageRate / s.peakRate
    }

    static func verdict(for s: TransferSession) -> Verdict {
        let ceiling = (s.linkTrusted == true)
            ? Reference.ceiling(forLinkBits: s.linkBits,
                                family: s.section == "Network" ? .network : .usb) : nil
        let used = ceiling.map { s.peakRate / $0.bytes } ?? 0

        if let ceiling = ceiling, used >= 0.85 {
            return Verdict(summary: String(format: "reached %.0f%% of the %@ link — nothing left to give",
                                           used * 100, ceiling.name.isEmpty ? "" : ceiling.name),
                           maximised: true)
        }

        // Near a known medium's ceiling: the card or disk was the limit, not the port.
        // Only meaningful for real hardware - a tunnel has no medium of its own.
        let families: [SpeedRef.Family] = s.section == "Network" ? [.network] : [.storage]
        // Same rule as the rows: a card is judged against cards, a drive against
        // drives. Without this a copy to the internal SSD was reported as having
        // "peaked at about SD card (UHS-I SDR50)'s limit", which it never touched.
        let roles: [String]? = s.section == "Network" ? nil
                                                     : (s.removable == true ? ["card"] : ["disk"])
        if s.physical != false,
           let near = Reference.nearest(bytesPerSec: s.peakRate, families: families, roles: roles,
                                        internalMedium: s.section == "Internal") {
            let ratio = (s.peakRate * 8) / near.payload
            if ratio > 0.85, ratio < 1.15 {
                // Consistency, not proof. A rate near a medium's ceiling is also
                // consistent with a slower reader, the other endpoint, the workload,
                // or thermal throttling; this cannot isolate those.
                return Verdict(summary: "peak is consistent with \(near.name)'s ceiling",
                               maximised: true, inferred: true)
            }
        }

        if steadiness(s) < 0.45 {
            // The ratio is measured; "many small files" is one explanation among
            // several - a busy far end and a device that throttles look the same here.
            return Verdict(summary: String(format: "stop-start: averaged only %.0f%% of its own peak, "
                                           + "which is what many small files look like",
                                           steadiness(s) * 100),
                           maximised: false, inferred: true)
        }

        if ceiling != nil {
            // The percentage is measured; which end was the slow one is not.
            return Verdict(summary: String(format: "used %.0f%% of the link — the device at one end was slower",
                                           used * 100),
                           maximised: false, inferred: true)
        }
        if s.physical == false {
            return Verdict(summary: "software interface — the link beneath it sets the pace",
                           maximised: false)
        }
        return Verdict(summary: "no link rate to judge this against", maximised: false)
    }

    /// Everything recorded for one device and one volume.
    final class Group: NSObject {
        let key: String
        let device: String
        let section: String
        let volumes: [String]
        var sessions: [TransferSession]

        init(key: String, device: String, section: String,
             volumes: [String], sessions: [TransferSession]) {
            self.key = key
            self.device = device
            self.section = section
            self.volumes = volumes
            self.sessions = sessions
        }

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

    /// What to recommend from a given standard, and the gain it would actually
    /// deliver here.
    ///
    /// Two corrections to stepping one rung. Anything below the mainstream choice is
    /// legacy, and telling someone with a default-speed card to buy a high-speed one
    /// is useless when a common UHS-I card is ten times quicker. And the gain is
    /// bounded by the connection: a SATA SSD behind USB 3 delivers the bus's 450 MB/s,
    /// not its own 550, which is still a large win worth recommending.
    private static func target(from here: SpeedRef, role: String, family: SpeedRef.Family,
                               ceiling: Double?) -> (ref: SpeedRef, factor: Double)? {
        func realised(_ ref: SpeedRef) -> Double {
            guard let cap = ceiling else { return ref.payloadBytes }
            return min(ref.payloadBytes, cap)
        }
        let base = realised(here)
        guard base > 0 else { return nil }

        if let common = Reference.mainstream(role: role, family: family),
           common.payloadBytes > here.payloadBytes * 1.2 {
            let gain = realised(common) / base
            if gain > 1.2 { return (common, gain) }
        }
        guard let name = here.upgrade, let next = Reference.entry(named: name) else { return nil }
        let gain = realised(next) / base
        return gain > 1.05 ? (next, gain) : nil
    }

    private static func atLimit(of candidates: [SpeedRef], peak: Double) -> SpeedRef? {
        candidates.first { ref in
            let ratio = peak / ref.payloadBytes
            return ratio > 1 - atLimitBand && ratio < 1 + atLimitBand
        }
    }

    /// What the machine could offer that this connection is not using.
    ///
    /// Only worth saying when the gap is large and the device is not already the
    /// limit: a card reader at its card's ceiling gains nothing from a better cable,
    /// however fast the port beside it is.
    /// Bytes written to a removable volume you were importing *from*.
    ///
    /// A card you are only reading should take no writes at all, and when it does the
    /// causes are macOS's: Spotlight builds its index onto the volume, and a journalled
    /// filesystem mounted without `noatime` commits an access-time update for every
    /// file read. On a UHS-I card writes are far slower than reads and the two contend,
    /// so this is not merely wasted card wear - it is why the import crawls. Measured
    /// on one real session: 579 MB written against 474 MB read, at 6.3 MB/s on a card
    /// that had already demonstrated 85.8 MB/s.
    ///
    /// Only raised when a genuine import happened, so copying *to* a card - which is
    /// write-dominated by design - never trips it.
    static func housekeeping(for group: Group) -> String {
        guard group.removable else { return "" }
        let read = group.sessions.reduce(UInt64(0)) { $0 + $1.bytesRead }
        let written = group.sessions.reduce(UInt64(0)) { $0 + $1.bytesWritten }
        guard read >= 50_000_000, written >= 10_000_000,
              Double(written) >= Double(read) * 0.05 else { return "" }

        var causes: [String] = []
        if group.sessions.contains(where: { $0.spotlight == true }) {
            causes.append("a Spotlight index is present on the volume")
        }
        if let s = group.sessions.first(where: { $0.journalWrites == true }) {
            let fs = (s.fsType ?? "").isEmpty ? "The volume" : s.fsType!.uppercased()
            causes.append("\(fs) is journalled and mounted without noatime, so reads "
                          + "can trigger metadata writes")
        }

        // The byte counts are measured. What caused them is not: Bottleneck sees that
        // writes happened, not who issued them. macOS also batches access-time
        // updates rather than writing one per read, so the candidates below are
        // possibilities to check, not a diagnosis.
        var note = "\(Fmt.bytes(Double(written))) written to this card while reading "
            + "\(Fmt.bytes(Double(read))) from it"
        if written > read { note += " - more written than read" }
        note += ". Writes contend with reads on a card, so this can slow an import as "
            + "well as wear the card."
        if !causes.isEmpty {
            note += " Worth checking: " + causes.joined(separator: "; ") + "."
        }
        note += " A .metadata_never_index file at the volume root stops Spotlight "
            + "indexing it."
        return note
    }

    static func hostNote(for group: Group) -> String {
        guard group.section == "USB",
              let host = HostPorts.best,
              let link = Reference.standard(forLinkBits: group.linkBits, family: .usb),
              group.linkTrusted,
              host.payloadBytes > link.payloadBytes * 1.5,
              // Only when the connection is plausibly the constraint. A card sitting
              // at its own ceiling gains nothing from a faster port, and saying so on
              // every device would be noise.
              group.bestPeak >= link.payloadBytes * 0.6 else { return "" }

        let factor = host.payloadBytes / link.payloadBytes
        return "This Mac has \(host.name) ports (\(Fmt.rate(host.payloadBytes, unit: .bytes))), "
            + "but this is connected at \(link.name) (\(Fmt.rate(link.payloadBytes, unit: .bytes))). "
            + "A \(host.name) cable and enclosure would raise the ceiling about \(times(factor)) — "
            + "worth it only if the drive itself can go faster."
    }

    /// One recommendation for a group: what to change, and what it would buy.
    static func recommendation(for group: Group) -> String {
        let peak = group.bestPeak
        guard peak > 0 else { return "" }
        let family: SpeedRef.Family = group.section == "Network" ? .network : .storage

        if group.section == "Network" {
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
        if group.linkTrusted, let link = Reference.standard(forLinkBits: group.linkBits, family: .usb),
           link.payloadBytes > 0, peak / link.payloadBytes >= saturated {
            if let next = step(from: link) {
                return "Saturating \(link.name) at \(Fmt.rate(peak, unit: .bytes)). \(next)."
            }
            return "Saturating \(link.name) at \(Fmt.rate(peak, unit: .bytes)) — "
                + "nothing faster exists in this family."
        }

        // 2. Otherwise the medium is. Place it on the ladder for its kind.
        let role = group.section == "Network" ? "bus" : (group.removable ? "card" : "disk")
        let ladder = Reference.ladder(role: role, family: family)
        guard !ladder.isEmpty else { return "The device, not the link, is setting the pace." }

        let cap = group.linkTrusted
            ? Reference.ceiling(forLinkBits: group.linkBits, family: .usb)?.bytes : nil

        if let here = atLimit(of: ladder, peak: peak) {
            if let step = target(from: here, role: role, family: family, ceiling: cap) {
                var text = "Peaks at \(Fmt.rate(peak, unit: .bytes)), right at \(here.name)'s limit. "
                    + "\(step.ref.name) would be about \(times(step.factor)) faster"
                if let note = here.upgradeNote, step.ref.name == here.upgrade { text += ", " + note }
                return text + "."
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
            if let step = target(from: slowest, role: role, family: family, ceiling: cap) {
                return "Peaks at \(Fmt.rate(peak, unit: .bytes)), about what \(slowest.name) does. "
                    + "\(step.ref.name) would be about \(times(step.ref.payloadBytes / peak)) faster."
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
