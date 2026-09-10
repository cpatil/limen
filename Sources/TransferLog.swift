import Foundation

/// One period during which a device was actually moving data.
///
/// Recorded as sessions rather than a continuous sample stream: a log line per
/// second would be unreadable and enormous, while "this drive moved 42 GB over
/// eleven minutes, peaking at 96 MB/s, driven by Finder" is the thing you actually
/// want to look back at.
struct TransferSession: Codable {
    var id: String
    var device: String
    var section: String
    var started: Date
    var ended: Date
    var bytesRead: UInt64
    var bytesWritten: UInt64
    var peakRate: Double
    var linkBits: UInt64
    /// Whether linkBits was a real capacity. Wi-Fi reports a PHY rate, and
    /// recomputing credibility later cannot know that, which produced "107% of link".
    var linkTrusted: Bool?
    var removable: Bool?
    /// Real hardware, as opposed to a tunnel, bridge or loopback.
    var physical: Bool?
    var wireless: Bool?
    var processes: [String]
    var volumes: [String]
    /// What the volume did to itself while being read, captured when the session ran -
    /// the card may be long ejected by the time the log is read. Optional so logs
    /// written before this existed still decode.
    var fsType: String?
    var journalWrites: Bool?
    var spotlight: Bool?

    /// Storage is read and written; a network carries traffic in and out.
    var isStorageLike: Bool { section != "Network" }

    var duration: TimeInterval { max(1, ended.timeIntervalSince(started)) }
    var total: UInt64 { bytesRead + bytesWritten }
    var averageRate: Double { Double(total) / duration }
}

/// Keeps the sessions, on disk, capped.
final class TransferLog {
    static let shared = TransferLog()

    /// Below this a device is considered idle; a session ends after this much quiet.
    static let activeThreshold: Double = 256 * 1024
    static let idleGrace: TimeInterval = 6
    static let maxEntries = 500

    /// Smallest transfer worth remembering. Background chatter - a VPN keeping itself
    /// alive, a sync agent polling - easily clears a few megabytes, and dozens of such
    /// entries bury the copies you actually care about.
    static let sizeOptions: [(title: String, bytes: UInt64)] = [
        ("10 MB", 10_000_000), ("50 MB", 50_000_000),
        ("250 MB", 250_000_000), ("1 GB", 1_000_000_000),
    ]
    static var minimumSize: UInt64 {
        let stored = UserDefaults.standard.object(forKey: "MinLoggedTransfer") as? Int
        return UInt64(stored ?? 50_000_000)
    }

    private(set) var sessions: [TransferSession] = []
    private var open: [String: TransferSession] = [:]
    private var lastActive: [String: Date] = [:]

    private var fileURL: URL {
        if let override = overrideDirectory {
            return override.appendingPathComponent("history.json")
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Limen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    /// An isolated log for the checks in Tests/, so they never read or write the
    /// real history file.
    /// Writes to a directory of its own, so the checks exercise the real saving and
    /// restoring rather than a path that skips them - an undo that is never actually
    /// run is not an undo.
    static func makeForTesting(minimumSize: UInt64) -> TransferLog {
        let log = TransferLog(persist: true)
        log.overrideDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("limen-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: log.overrideDirectory!,
                                                 withIntermediateDirectories: true)
        log.testMinimumSize = minimumSize
        return log
    }

    private var testMinimumSize: UInt64?
    private var overrideDirectory: URL?
    private let persist: Bool

    private var effectiveMinimumSize: UInt64 { testMinimumSize ?? TransferLog.minimumSize }

    private init(persist: Bool) {
        self.persist = persist
    }

    private convenience init() {
        self.init(persist: true)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let parsed = try? JSONDecoder().decode([TransferSession].self, from: data) else { return }
        sessions = parsed
    }

    private func save() {
        // A log made for the checks never touches the real history file.
        guard persist else { return }
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Folds one sample of every row into the log, and closes anything that has gone.
    ///
    /// Closing vanished devices matters: a session is only ever finished by a later
    /// quiet sample for the same row, so pulling a card mid-copy used to leave its
    /// session open forever and it was never written to the log at all.
    func record(rows: [Row], now: Date = Date()) {
        for row in rows { record(row: row, now: now) }
        let present = Set(rows.map { $0.id })
        for key in open.keys where !present.contains(key) {
            if let session = open[key] { finish(key: key, session: session) }
        }
    }

    /// Writes out anything still running, so quitting mid-copy does not lose it.
    func flush() {
        for (key, session) in open { finish(key: key, session: session) }
    }

    /// Folds one sample of one row into the log.
    func record(row: Row, now: Date = Date()) {
        let key = row.id
        let rate = row.down + row.up
        // Captured before anything else, so the next sample's baseline is the totals
        // as they stood *before* that sample's traffic.
        defer { previousTotals[key] = (row.totalDown, row.totalUp) }

        if rate >= TransferLog.activeThreshold {
            // Cumulative counters only ever climb. A drop means the device was
            // unplugged and replugged, or the driver reloaded, and the open session's
            // baseline now refers to counters that no longer exist. Close it and start
            // again rather than reporting a negative or absurd total.
            if let start = startTotals[key], row.totalDown < start.0 || row.totalUp < start.1 {
                if let stale = open[key] { finish(key: key, session: stale) }
            }
            lastActive[key] = now
            if var session = open[key] {
                session.ended = now
                session.bytesRead = row.totalDown >= session.bytesRead ? row.totalDown : session.bytesRead
                session.bytesWritten = row.totalUp >= session.bytesWritten ? row.totalUp : session.bytesWritten
                session.peakRate = max(session.peakRate, rate)
                for actor in row.actors where !session.processes.contains(actor.display) {
                    session.processes.append(actor.display)
                }
                open[key] = session
            } else {
                // Counters are cumulative; remember where the session started so the
                // total can be a difference rather than a lifetime figure.
                open[key] = TransferSession(id: UUID().uuidString,
                                            device: row.title,
                                            section: row.section,
                                            started: now,
                                            ended: now,
                                            bytesRead: row.totalDown,
                                            bytesWritten: row.totalUp,
                                            peakRate: rate,
                                            linkBits: row.linkBits,
                                            linkTrusted: row.linkTrusted,
                                            removable: row.removable,
                                            physical: row.isPhysical,
                                            wireless: row.wireless,
                                            processes: row.actors.map { $0.display },
                                            volumes: row.volumes,
                                            fsType: row.fsType,
                                            journalWrites: row.journalWrites,
                                            spotlight: row.spotlight)
                // The first active sample already includes the bytes moved during
                // that interval, so using it as the baseline discarded them. The
                // previous sample's totals are the true starting point.
                startTotals[key] = previousTotals[key] ?? (row.totalDown, row.totalUp)
            }
            return
        }

        // Quiet: close the session once it has been quiet long enough to be over.
        guard let session = open[key], let last = lastActive[key] else { return }
        guard now.timeIntervalSince(last) >= TransferLog.idleGrace else { return }
        finish(key: key, session: session)
    }

    private var startTotals: [String: (UInt64, UInt64)] = [:]
    /// Totals seen at the previous sample, whether the device was busy or not.
    private var previousTotals: [String: (UInt64, UInt64)] = [:]

    /// Turns the lifetime counters held while a session is open into the amount moved
    /// during it. Without this an open session divides a device's whole-life total by
    /// a few seconds and reports an average far above its own peak.
    private func normalised(_ session: TransferSession, key: String) -> TransferSession {
        guard let start = startTotals[key] else { return session }
        var out = session
        out.bytesRead = session.bytesRead >= start.0 ? session.bytesRead - start.0 : 0
        out.bytesWritten = session.bytesWritten >= start.1 ? session.bytesWritten - start.1 : 0
        return out
    }

    private func finish(key: String, session: TransferSession) {
        let closed = normalised(session, key: key)
        open.removeValue(forKey: key)
        startTotals.removeValue(forKey: key)
        lastActive.removeValue(forKey: key)

        guard closed.total >= effectiveMinimumSize else { return }
        sessions.insert(closed, at: 0)
        if sessions.count > TransferLog.maxEntries {
            sessions.removeLast(sessions.count - TransferLog.maxEntries)
        }
        save()
    }

    /// Sessions still running, newest first, so the log is useful while a copy is
    /// happening. Byte counts are reduced to what has moved during the session.
    var inFlight: [TransferSession] {
        open.map { normalised($0.value, key: $0.key) }
            .sorted { $0.started > $1.started }
    }

    /// Where the last clear went. Clearing is otherwise unrecoverable, and a log that
    /// took weeks to accumulate is worth more than the keystroke that emptied it.
    private var recycleURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("cleared.json")
    }

    /// True when the last clear can still be put back.
    var canRestoreCleared: Bool {
        guard persist, let data = try? Data(contentsOf: recycleURL),
              let parsed = try? JSONDecoder().decode([TransferSession].self, from: data)
        else { return false }
        return !parsed.isEmpty
    }

    private func setAside(_ removed: [TransferSession]) {
        guard persist, !removed.isEmpty,
              let data = try? JSONEncoder().encode(removed) else { return }
        try? data.write(to: recycleURL, options: .atomic)
    }

    /// Puts back whatever the last clear removed, keeping anything recorded since.
    @discardableResult
    func restoreCleared() -> Int {
        guard let data = try? Data(contentsOf: recycleURL),
              let parsed = try? JSONDecoder().decode([TransferSession].self, from: data),
              !parsed.isEmpty else { return 0 }
        let known = Set(sessions.map { $0.id })
        let returning = parsed.filter { !known.contains($0.id) }
        sessions.append(contentsOf: returning)
        sessions.sort { $0.started > $1.started }
        if sessions.count > TransferLog.maxEntries {
            sessions.removeLast(sessions.count - TransferLog.maxEntries)
        }
        try? FileManager.default.removeItem(at: recycleURL)
        save()
        return returning.count
    }

    func clear() {
        setAside(sessions)
        sessions.removeAll()
        save()
    }

    /// Forgets one device's history without touching anything else.
    func clear(device: String, volumes: [String]) {
        setAside(sessions.filter { $0.device == device && $0.volumes == volumes })
        sessions.removeAll { $0.device == device && $0.volumes == volumes }
        save()
    }
}
