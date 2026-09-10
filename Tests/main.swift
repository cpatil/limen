import Foundation

// A plain assertion harness. There is no Xcode project here, so the tests build the
// same way the app does: swiftc over Sources plus this file.
var failures = 0
var checks = 0

func check(_ what: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if !condition {
        failures += 1
        let extra = detail()
        print("  FAIL  \(what)" + (extra.isEmpty ? "" : "  [\(extra)]"))
    }
}

func near(_ a: Double, _ b: Double, _ tol: Double = 0.01) -> Bool { abs(a - b) <= tol }

// ---- full-duplex utilisation -------------------------------------------------
// A gigabit link carrying 600 Mbit/s each way is at ~60% per direction. Summing the
// directions reported 128% of a one-direction ceiling and made the link look bogus.
let gigabit: UInt64 = 1_000_000_000
let sixHundredMbit = 600_000_000.0 / 8
if let u = Reference.utilization(down: sixHundredMbit, up: sixHundredMbit, linkBits: gigabit) {
    check("duplex: 600+600 Mbit on gigabit stays under 100%", u < 1.0, String(format: "%.2f", u))
    check("duplex: matches one direction", near(u, sixHundredMbit / (Reference.ceiling(forLinkBits: gigabit)!.bytes), 0.02))
} else {
    check("duplex: gigabit has a ceiling", false)
}
if let one = Reference.utilization(down: sixHundredMbit, up: 0, linkBits: gigabit),
   let two = Reference.utilization(down: sixHundredMbit, up: sixHundredMbit, linkBits: gigabit) {
    check("duplex: adding upload does not inflate utilisation", near(one, two, 0.001))
}

// ---- path boundaries ---------------------------------------------------------
check("path: exact match", ProcessSampler.isUnder(path: "/Volumes/card", root: "/Volumes/card"))
check("path: child", ProcessSampler.isUnder(path: "/Volumes/card/DCIM/a.raw", root: "/Volumes/card"))
check("path: sibling with shared prefix is NOT inside",
      !ProcessSampler.isUnder(path: "/Volumes/card-old/a.raw", root: "/Volumes/card"))
check("path: trailing slash on root", ProcessSampler.isUnder(path: "/Volumes/card/a", root: "/Volumes/card/"))
check("path: unrelated", !ProcessSampler.isUnder(path: "/Users/x", root: "/Volumes/card"))
check("path: empty root", !ProcessSampler.isUnder(path: "/Volumes/card", root: ""))

// ---- catalogue ---------------------------------------------------------------
// The binary ships one copy and the repo another; they must not drift.
let bundled = Catalogue.builtIn
check("catalogue: built-in parses", !bundled.entries.isEmpty)
if let data = try? Data(contentsOf: URL(fileURLWithPath: "Resources/speeds.json")),
   let onDisk = try? JSONDecoder().decode(SpeedCatalogue.self, from: data) {
    check("catalogue: versions match", bundled.version == onDisk.version,
          "built-in \(bundled.version) vs file \(onDisk.version)")
    check("catalogue: entry counts match", bundled.entries.count == onDisk.entries.count,
          "\(bundled.entries.count) vs \(onDisk.entries.count)")
    check("catalogue: names match",
          bundled.entries.map { $0.name } == onDisk.entries.map { $0.name })
} else {
    check("catalogue: Resources/speeds.json readable", false)
}
for e in bundled.entries {
    check("catalogue: \(e.name) payload <= line", e.payload <= e.line + 1)
    check("catalogue: \(e.name) has a positive payload", e.payload > 0)
    if let up = e.upgrade {
        check("catalogue: \(e.name) upgrade '\(up)' exists",
              bundled.entries.contains { $0.name == up })
    }
}
// Aliases must be other names for the same thing, not merely equal line rates.
for e in bundled.entries where e.alias != nil {
    let a = e.alias!
    check("catalogue: alias '\(a)' is not a different protocol family",
          !a.contains("Thunderbolt 1") && !a.contains("Thunderbolt 2") && a != "UHS-I U3")
}

// ---- comparisons stay inside the right kind of medium ------------------------
let ssdRate = 500_000_000.0
let internalPick = Reference.nearest(bytesPerSec: ssdRate, families: [.storage],
                                     roles: ["disk"], internalMedium: true)
check("compare: internal SSD is not measured against a card",
      !(internalPick?.role == "card"), internalPick?.name ?? "nil")
check("compare: internal drive is not measured against cable-only media",
      internalPick?.mount != "external", internalPick?.name ?? "nil")
let cardPick = Reference.nearest(bytesPerSec: 86_000_000, families: [.storage], roles: ["card"])
check("compare: a card is measured against cards", cardPick?.role == "card", cardPick?.name ?? "nil")

// ---- SD capacity classes -----------------------------------------------------
func family(_ bytes: UInt64) -> String {
    Reference.mediumClass(bytes: bytes, deviceName: "USB3.0 Card Reader", removable: true)
}
check("sd: 1.9 GB is SDSC", family(1_900_000_000).hasPrefix("SDSC"), family(1_900_000_000))
check("sd: 31 GB is SDHC", family(31_000_000_000).hasPrefix("SDHC"), family(31_000_000_000))
check("sd: 64 GB is SDXC", family(64_088_965_120).hasPrefix("SDXC"), family(64_088_965_120))
check("sd: 4 TB is SDUC", family(4_000_000_000_000).hasPrefix("SDUC"), family(4_000_000_000_000))
check("sd: a fixed disk gets no card label",
      Reference.mediumClass(bytes: 64_000_000_000, deviceName: "Elements 2621", removable: false).isEmpty)
check("sd: a non-reader removable gets no card label",
      Reference.mediumClass(bytes: 64_000_000_000, deviceName: "Generic Flash Disk", removable: true).isEmpty)

// ---- the usage gauge ---------------------------------------------------------
check("gauge: a device that never moved data has no bar",
      Reference.gauge(down: 0, up: 0, peakDirectional: 0, peak: 0,
                      linkBits: 0, linkTrusted: false) == nil)
if let g = Reference.gauge(down: 10_000_000, up: 0, peakDirectional: 20_000_000,
                           peak: 20_000_000, linkBits: 0, linkTrusted: false) {
    check("gauge: no link means peak-relative", !g.ofLink)
    check("gauge: peak-relative is capped at 1", g.fraction <= 1.0)
}
if let g = Reference.gauge(down: 400_000_000, up: 0, peakDirectional: 400_000_000,
                           peak: 400_000_000, linkBits: 5_000_000_000, linkTrusted: true) {
    check("gauge: a credible link is measured against the link", g.ofLink)
}

// ---- session verdicts and housekeeping ---------------------------------------
func session(read: UInt64, written: UInt64, removable: Bool,
             spotlight: Bool = true, journal: Bool = true) -> TransferSession {
    TransferSession(id: "t", device: "Reader", section: "USB",
                    started: Date(), ended: Date().addingTimeInterval(60),
                    bytesRead: read, bytesWritten: written, peakRate: 20e6,
                    linkBits: 5_000_000_000, linkTrusted: true, removable: removable,
                    physical: true, wireless: false, processes: [], volumes: ["sd"],
                    fsType: "hfs", journalWrites: journal, spotlight: spotlight)
}
func housekeeping(_ s: TransferSession) -> String {
    Analysis.housekeeping(for: Analysis.Group(key: "k", device: "Reader", section: "USB",
                                              volumes: ["sd"], sessions: [s]))
}
check("housekeeping: flags a read-dominant import taking writes",
      !housekeeping(session(read: 474_000_000, written: 579_000_000, removable: true)).isEmpty)
check("housekeeping: silent when copying TO a card",
      housekeeping(session(read: 2_000_000, written: 8_000_000_000, removable: true)).isEmpty)
check("housekeeping: silent on a clean import",
      housekeeping(session(read: 6_000_000_000, written: 4_000_000, removable: true,
                           spotlight: false, journal: false)).isEmpty)
check("housekeeping: silent for a fixed drive",
      housekeeping(session(read: 474_000_000, written: 579_000_000, removable: false)).isEmpty)
check("housekeeping: does not assert a cause it cannot observe",
      !housekeeping(session(read: 474_000_000, written: 579_000_000, removable: true))
          .contains("Spotlight indexing the volume"))

// ---- host port advice --------------------------------------------------------
// Presence of a Thunderbolt controller must not imply USB4 on Intel Macs.
#if arch(x86_64)
check("host: no port generation claimed on Intel", HostPorts.best == nil)
#endif


// ---- session accounting ------------------------------------------------------
// Built on a fresh log each time so these do not touch the real history file.
func row(_ id: String, section: String, totalDown: UInt64, totalUp: UInt64,
         down: Double, up: Double) -> Row {
    var r = Row(id: id, title: "Dev", subtitle: "", badge: "")
    r.section = section
    r.totalDown = totalDown; r.totalUp = totalUp
    r.down = down; r.up = up
    r.isPhysical = true
    return r
}
do {
    let log = TransferLog.makeForTesting(minimumSize: 1)
    let t0 = Date()
    // A quiet sample first: 100 bytes on the clock, nothing moving.
    log.record(row: row("d", section: "USB", totalDown: 100, totalUp: 0, down: 0, up: 0), now: t0)
    // Then two busy seconds moving 1_000_000 each.
    log.record(row: row("d", section: "USB", totalDown: 1_000_100, totalUp: 0,
                        down: 1_000_000, up: 0), now: t0.addingTimeInterval(1))
    log.record(row: row("d", section: "USB", totalDown: 2_000_100, totalUp: 0,
                        down: 1_000_000, up: 0), now: t0.addingTimeInterval(2))
    // Quiet long enough to close it.
    log.record(row: row("d", section: "USB", totalDown: 2_000_100, totalUp: 0, down: 0, up: 0),
               now: t0.addingTimeInterval(2 + TransferLog.idleGrace + 1))
    check("session: closes when the device goes quiet", log.sessions.count == 1)
    if let s = log.sessions.first {
        check("session: keeps the first interval's bytes", s.bytesRead == 2_000_000,
              "got \(s.bytesRead), expected 2000000")
    }
}
do {
    // Counters reset mid-session (unplug/replug). The old baseline is meaningless.
    let log = TransferLog.makeForTesting(minimumSize: 1)
    let t0 = Date()
    log.record(row: row("d", section: "USB", totalDown: 5_000_000, totalUp: 0, down: 0, up: 0), now: t0)
    log.record(row: row("d", section: "USB", totalDown: 6_000_000, totalUp: 0,
                        down: 1_000_000, up: 0), now: t0.addingTimeInterval(1))
    log.record(row: row("d", section: "USB", totalDown: 500_000, totalUp: 0,
                        down: 500_000, up: 0), now: t0.addingTimeInterval(2))
    for s in log.sessions {
        check("session: a counter reset never yields a nonsense total",
              s.bytesRead < 100_000_000, "got \(s.bytesRead)")
    }
    check("session: reset closed the old session", log.sessions.count >= 1)
}

// ---- direction vocabulary ----------------------------------------------------
func sess(_ section: String) -> TransferSession {
    TransferSession(id: "x", device: "d", section: section, started: Date(), ended: Date(),
                    bytesRead: 1, bytesWritten: 1, peakRate: 1, linkBits: 0,
                    linkTrusted: false, removable: false, physical: true, wireless: false,
                    processes: [], volumes: [])
}
check("labels: internal storage reads and writes", sess("Internal").isStorageLike)
check("labels: USB storage reads and writes", sess("USB").isStorageLike)
check("labels: a network interface does not", !sess("Network").isStorageLike)


// ---- single instance ---------------------------------------------------------
// Two copies both write history.json and neither knows about the other's sessions,
// so whichever saves last discards the other's transfers.
do {
    let path = NSTemporaryDirectory() + "limen-test-\(UUID().uuidString).lock"
    defer { try? FileManager.default.removeItem(atPath: path) }
    check("instance: the first claim succeeds", SingleInstance.claim(at: path))
    check("instance: a second claim on the same lock is refused",
          !SingleInstance.claim(at: path))
    let other = NSTemporaryDirectory() + "limen-test-\(UUID().uuidString).lock"
    defer { try? FileManager.default.removeItem(atPath: other) }
    check("instance: a different lock file is independent", SingleInstance.claim(at: other))
    check("instance: an unwritable location does not block startup",
          SingleInstance.claim(at: "/this/path/cannot/exist/limen.lock"))
}

print(failures == 0 ? "\n\(checks) checks passed" : "\n\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
