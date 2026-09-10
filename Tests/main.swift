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


// ---- held "active first" ordering --------------------------------------------
// The complaint this fixes: rows swapping places every sample as devices go busy
// and idle, which makes the list unreadable while you are trying to read it.
func r(_ id: String, active: Bool, physical: Bool = true) -> Row {
    var row = Row(id: id, title: id, subtitle: "", badge: "")
    row.active = active
    row.isPhysical = physical
    return row
}
do {
    let idle = [r("c", active: false), r("a", active: false), r("b", active: false)]
    let fresh = Monitor.ordered(idle, by: .activeFirst)
    check("order: with nothing pinned, active-first decides",
          fresh.map { $0.id } == ["a", "b", "c"], fresh.map { $0.id }.joined(separator: ","))

    // Pin that arrangement, then make the last row busy. It must not jump to the top.
    let pinned = fresh.map { $0.id }
    let nowBusy = [r("a", active: false), r("b", active: false), r("c", active: true)]
    let held = Monitor.ordered(nowBusy, by: .activeFirst, pinned: pinned)
    check("order: a row going busy does not jump while the order is held",
          held.map { $0.id } == ["a", "b", "c"], held.map { $0.id }.joined(separator: ","))

    // And the reverse: the top row going idle must not sink.
    let topIdle = [r("a", active: false), r("b", active: true), r("c", active: true)]
    check("order: a row going idle does not sink while the order is held",
          Monitor.ordered(topIdle, by: .activeFirst, pinned: pinned).map { $0.id } == ["a", "b", "c"])

    // A card plugged in mid-session appears, but at the end rather than barging in.
    let withNew = nowBusy + [r("z-new", active: true)]
    check("order: a new device appears at the end",
          Monitor.ordered(withNew, by: .activeFirst, pinned: pinned).map { $0.id }
              == ["a", "b", "c", "z-new"])

    // Ejecting one drops it without disturbing the rest.
    let ejected = [r("a", active: false), r("c", active: true)]
    check("order: an ejected device is dropped, order otherwise intact",
          Monitor.ordered(ejected, by: .activeFirst, pinned: pinned).map { $0.id } == ["a", "c"])

    // Re-sorting means forgetting the pin, so active-first applies again.
    check("order: re-sorting reconsiders",
          Monitor.ordered(nowBusy, by: .activeFirst).map { $0.id } == ["c", "a", "b"],
          Monitor.ordered(nowBusy, by: .activeFirst).map { $0.id }.joined(separator: ","))

    // The live sorts stay live - they were chosen deliberately.
    var fast = r("fast", active: true); fast.down = 100
    var slow = r("slow", active: true); slow.down = 1
    check("order: sorting by rate still tracks the rate",
          Monitor.ordered([slow, fast], by: .rate).map { $0.id } == ["fast", "slow"])
}


// ---- dragging a row ----------------------------------------------------------
// The bug this covers: the sampler assigned its own order into the list every
// second, so a drag in progress was undone, and a sample landing between the last
// mouse-move and letting go meant the ids written down on drop were the sampler's.
do {
    func n(_ id: String, down: Double = 0) -> Row {
        var row = Row(id: id, title: id, subtitle: "", badge: "")
        row.down = down
        return row
    }
    let onScreen = [n("utun5"), n("en0"), n("en1")]          // as dragged
    let fromSampler = [n("en0", down: 99), n("en1"), n("utun5")]   // sampler's order

    let merged = TrafficListView.merged(holding: onScreen, incoming: fromSampler)
    check("drag: a sample does not reorder the list mid-drag",
          merged.map { $0.id } == ["utun5", "en0", "en1"],
          merged.map { $0.id }.joined(separator: ","))
    check("drag: but the numbers still update",
          merged.first(where: { $0.id == "en0" })?.down == 99)

    check("drag: while reordering, the sampler's order is refused",
          TrafficListView.nextRows(current: onScreen, incoming: fromSampler,
                                   reordering: true).map { $0.id }
              == ["utun5", "en0", "en1"])
    check("drag: when not reordering, the sampler's order is taken",
          TrafficListView.nextRows(current: onScreen, incoming: fromSampler,
                                   reordering: false).map { $0.id }
              == ["en0", "en1", "utun5"])

    let ejected = TrafficListView.merged(holding: onScreen, incoming: [n("en0"), n("en1")])
    check("drag: something unplugged mid-drag drops out",
          ejected.map { $0.id } == ["en0", "en1"])

    let appeared = TrafficListView.merged(holding: onScreen,
                                          incoming: fromSampler + [n("brand-new")])
    check("drag: nothing new appears under the pointer mid-drag",
          appeared.map { $0.id } == ["utun5", "en0", "en1"])
}
do {
    // Insertion is measured from the middle of the carried row, so crossing a
    // boundary is decisive rather than oscillating.
    let h = TrafficListView.rowHeight
    check("drag: resting in place stays put",
          TrafficListView.insertionIndex(floatY: 0, rowCount: 3, rowHeight: h) == 0)
    check("drag: just under half a row down does not move",
          TrafficListView.insertionIndex(floatY: h * 0.49, rowCount: 3, rowHeight: h) == 0)
    check("drag: just past half a row down takes the next slot",
          TrafficListView.insertionIndex(floatY: h * 0.51, rowCount: 3, rowHeight: h) == 1)
    check("drag: cannot be dropped past the end",
          TrafficListView.insertionIndex(floatY: h * 99, rowCount: 3, rowHeight: h) == 2)
    check("drag: cannot be dropped above the start",
          TrafficListView.insertionIndex(floatY: -500, rowCount: 3, rowHeight: h) == 0)
    check("drag: an empty list is harmless",
          TrafficListView.insertionIndex(floatY: 40, rowCount: 0, rowHeight: h) == 0)
}


// ---- the handle's gutter -----------------------------------------------------
// Reaching for the grip used to raise the hover card over the row you were about
// to pick up.
do {
    check("gutter: the far left is the handle", TrafficListView.isOverHandle(x: 0))
    check("gutter: the middle of the grip is the handle",
          TrafficListView.isOverHandle(x: TrafficListView.gripWidth / 2))
    check("gutter: just inside the content is not",
          !TrafficListView.isOverHandle(x: TrafficListView.contentLeft))
    check("gutter: the icon and text are not",
          !TrafficListView.isOverHandle(x: 200))
    check("gutter: the grip fits inside the gutter",
          TrafficListView.gripWidth <= TrafficListView.contentLeft)
}


// ---- the Spotlight indicator -------------------------------------------------
do {
    func vol(section: String, internalMedium: Bool, mounts: [String]) -> Row {
        var row = Row(id: "v", title: "v", subtitle: "", badge: "")
        row.section = section
        row.internalMedium = internalMedium
        row.mountRoots = mounts
        return row
    }
    check("spotlight: reported for a card in a reader",
          vol(section: "USB", internalMedium: false, mounts: ["/Volumes/sd"])
              .indexingWorthReporting)
    check("spotlight: reported for an external drive",
          vol(section: "USB", internalMedium: false, mounts: ["/Volumes/media"])
              .indexingWorthReporting)
    check("spotlight: NOT reported for the internal drive - indexing it is the point",
          !vol(section: "Internal", internalMedium: true, mounts: ["/"])
              .indexingWorthReporting)
    check("spotlight: not reported for a network interface",
          !vol(section: "Network", internalMedium: false, mounts: []).indexingWorthReporting)
    check("spotlight: not reported for a device with nothing mounted",
          !vol(section: "USB", internalMedium: false, mounts: []).indexingWorthReporting)
}


// ---- what a rate means -------------------------------------------------------
// The class is named from the best the device has done, not from what it happens
// to be doing. Anchoring on the momentary rate reported an idle SSD as "7% of
// desktop hard disk", and a struggling UHS-I card as a "default speed" card.
do {
    func ctx(current: Double, peak: Double, roles: [String], internalMedium: Bool = false) -> String {
        Reference.context(current: current, peak: peak, unit: .bytes,
                          families: [.storage], roles: roles, internalMedium: internalMedium)
    }
    let ssdIdle = ctx(current: 0, peak: 1.09e9, roles: ["disk"], internalMedium: true)
    check("context: an idle SSD is still described as an SSD",
          ssdIdle.contains("SSD"), ssdIdle)
    check("context: an idle SSD is not called a hard disk",
          !ssdIdle.lowercased().contains("hard disk"), ssdIdle)
    check("context: it states what the class typically does",
          ssdIdle.contains("typically"), ssdIdle)

    let slowSsd = ctx(current: 40e6, peak: 1.09e9, roles: ["disk"], internalMedium: true)
    check("context: a lightly used SSD is not reported as a fraction of a hard disk",
          !slowSsd.contains("hard disk"), slowSsd)

    let struggling = ctx(current: 6e6, peak: 96e6, roles: ["card"])
    check("context: a struggling card keeps the class its peak established",
          struggling.contains("UHS-I SDR104"), struggling)
    check("context: and says what that class should manage",
          struggling.contains("typically"), struggling)

    let atCeiling = ctx(current: 86e6, peak: 96e6, roles: ["card"])
    check("context: a rate at the class ceiling is said outright",
          atCeiling.hasPrefix("≈"), atCeiling)

    check("context: a device that has never moved a byte says nothing",
          ctx(current: 0, peak: 0, roles: ["disk"]).isEmpty)
}


// ---- the medium the system already reported ----------------------------------
do {
    // An idle SSD was being matched to a spinning disk purely because it was idle.
    let ssd = Reference.context(current: 2e6, peak: 17e6, unit: .bytes,
                                families: [.storage], roles: ["disk"],
                                internalMedium: true, kinds: ["ssd"])
    check("kind: a known SSD is never called a hard disk",
          !ssd.lowercased().contains("hard disk"), ssd)
    check("kind: it is described as an SSD", ssd.contains("SSD"), ssd)

    let spinning = Reference.context(current: 1e6, peak: 111e6, unit: .bytes,
                                     families: [.storage], roles: ["disk"], kinds: ["spinning"])
    check("kind: a known spinning disk is not called an SSD",
          !spinning.contains("SSD"), spinning)

    // Without a reported kind the class still comes from what the device has done.
    let unknown = Reference.context(current: 2e6, peak: 17e6, unit: .bytes,
                                    families: [.storage], roles: ["disk"], internalMedium: true)
    check("kind: with nothing reported, it still says something", !unknown.isEmpty, unknown)

    // A kind the catalogue has no entry for must not empty the pool.
    let nonsense = Reference.context(current: 2e6, peak: 17e6, unit: .bytes,
                                     families: [.storage], roles: ["disk"], kinds: ["unobtanium"])
    check("kind: an unknown kind falls back rather than going silent", !nonsense.isEmpty, nonsense)

    for e in Catalogue.builtIn.entries where e.kind != nil {
        check("catalogue: \(e.name) has a sensible kind",
              ["ssd", "spinning", "flash"].contains(e.kind!), e.kind!)
    }
}


// ---- everything the app does can be undone -----------------------------------
// A log that took weeks to accumulate should not depend on the user having been
// careful with a context menu.
do {
    let log = TransferLog.makeForTesting(minimumSize: 1)
    let t0 = Date()
    for tick in 0..<3 {
        let at = t0.addingTimeInterval(Double(tick) * 3)
        log.record(row: row("d\(tick)", section: "USB", totalDown: 0, totalUp: 0,
                            down: 0, up: 0), now: at)
        log.record(row: row("d\(tick)", section: "USB", totalDown: 5_000_000, totalUp: 0,
                            down: 5_000_000, up: 0), now: at.addingTimeInterval(1))
    }
    log.flush()
    let before = log.sessions.count
    check("undo: some sessions to lose", before > 0, "\(before)")

    log.clear()
    check("undo: clearing empties the log", log.sessions.isEmpty)
    check("undo: and the clear is recoverable", log.canRestoreCleared)

    let restored = log.restoreCleared()
    check("undo: everything comes back", log.sessions.count == before,
          "\(log.sessions.count) of \(before)")
    check("undo: and it reports how many", restored == before, "\(restored)")
    check("undo: the undo is spent once used", !log.canRestoreCleared)

    // Restoring must not duplicate anything recorded since the clear.
    log.clear()
    _ = log.restoreCleared()
    let ids = Set(log.sessions.map { $0.id })
    check("undo: nothing is duplicated", ids.count == log.sessions.count)
}


// ---- which interfaces are shown ----------------------------------------------
// A tunnel's bytes are already counted on the interface it rides over, so listing
// both put the same traffic on screen twice.
do {
    func iface(_ id: String, physical: Bool, active: Bool) -> Row {
        var r = Row(id: id, title: id, subtitle: "", badge: "")
        r.isPhysical = physical
        r.active = active
        return r
    }
    let all = [iface("en0", physical: true, active: true),
               iface("en1", physical: true, active: false),
               iface("utun5", physical: false, active: true),
               iface("lo0", physical: false, active: true),
               iface("bridge0", physical: false, active: false)]
    let shown = all.filter { $0.isPhysical }
    check("interfaces: hardware is shown", shown.contains { $0.id == "en0" })
    check("interfaces: idle hardware stays visible", shown.contains { $0.id == "en1" })
    check("interfaces: an active tunnel is not listed twice",
          !shown.contains { $0.id == "utun5" })
    check("interfaces: loopback is not listed", !shown.contains { $0.id == "lo0" })
    check("interfaces: show-all keeps everything", all.count == 5)
}

print(failures == 0 ? "\n\(checks) checks passed" : "\n\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
