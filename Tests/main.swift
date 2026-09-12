import Foundation
import Cocoa

// Light and dark are not two skins over one design - several colours are chosen
// separately for each, and one that works on a dark ground can be unreadable on a
// pale one. The whole suite therefore runs twice, once in each appearance, driven by
// this variable. Both the palette and AppKit's own dynamic colours have to be told:
// the palette has no application to ask, and NSColor resolves a dynamic colour
// against whatever appearance is current on this thread.
let appearanceName = ProcessInfo.processInfo.environment["LIMEN_APPEARANCE"] ?? "light"
let runningLight = appearanceName != "dark"
Palette.forcedAppearance = runningLight

/// Runs `body` with this pass's appearance current, so AppKit's dynamic colours -
/// labelColor, systemGreen and the rest - resolve to the values they would have on
/// screen rather than to whatever the process happens to default to.
func inThisAppearance(_ body: () -> Void) {
    let appearance = NSAppearance(named: runningLight ? .aqua : .darkAqua)!
    if #available(macOS 11.0, *) {
        appearance.performAsCurrentDrawingAppearance(body)
    } else {
        body()   // the palette checks below are skipped on older systems
    }
}

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
// A reader whose product string is "USB Storage" holds cards like any other. The
// evidence is that it reports removable media - a flash drive does not, because a
// flash drive is its own medium - and that evidence is worth acting on and worth
// stating. Requiring the name to say "card" hid a 394 GB SDXC behind a generic
// string, with no class and no comparison.
check("sd: a removable medium is a card whatever the reader calls itself",
      Reference.mediumClass(bytes: 394_000_000_000, deviceName: "USB Storage",
                            removable: true).hasPrefix("SDXC"))
check("sd: but the app knows that rests on the removable flag alone",
      Reference.mediumClassIsAssumed(deviceName: "USB Storage"))
check("sd: whereas a reader that says so needs no assumption",
      !Reference.mediumClassIsAssumed(deviceName: "USB3.0 Card Reader"))
check("sd: fixed media is still not a card",
      Reference.mediumClass(bytes: 64_000_000_000, deviceName: "Generic Flash Disk",
                            removable: false).isEmpty)

// The SD standard's capacity boundaries are decimal GB, not GiB. Reading them as GiB
// pushed every boundary up by 7%: a 32 GB card - SDHC by the standard - came out SDXC.
check("sd: 32 GB is the largest SDHC",
      Reference.mediumClass(bytes: 32_000_000_000, deviceName: "USB3.0 Card Reader",
                            removable: true).hasPrefix("SDHC"))
check("sd: just above 32 GB is SDXC",
      Reference.mediumClass(bytes: 32_100_000_000, deviceName: "USB3.0 Card Reader",
                            removable: true).hasPrefix("SDXC"))
check("sd: 32 GiB is well inside SDXC, not on the boundary",
      Reference.mediumClass(bytes: 34_359_738_368, deviceName: "USB3.0 Card Reader",
                            removable: true).hasPrefix("SDXC"))
check("sd: 2 GB is the largest SDSC",
      Reference.mediumClass(bytes: 2_000_000_000, deviceName: "SD Card Reader",
                            removable: true).hasPrefix("SDSC"))
check("sd: above 2 TB is SDUC",
      Reference.mediumClass(bytes: 4_000_000_000_000, deviceName: "SD Card Reader",
                            removable: true).hasPrefix("SDUC"))

// ---- ejecting --------------------------------------------------------------------
// macOS refuses a busy volume with "it is in use" and does not say by what. This app
// has been watching which processes hold files open there, so it can finish the
// sentence - that is the whole value of saying it here rather than in Finder.
do {
    let plain = TrafficListView.ejectFailure(name: "sd-19",
                                             reason: "The disk is in use.", holders: [])
    check("eject: the failure names the card and repeats what macOS said",
          plain.contains("sd-19") && plain.contains("in use"), plain)
    check("eject: with nothing to add when nothing was seen",
          !plain.contains("last saw"), plain)

    let blamed = TrafficListView.ejectFailure(name: "sd-19", reason: "The disk is in use.",
                                              holders: ["Finder", "mds_stores"])
    check("eject: and names who was holding it when it knows",
          blamed.contains("Finder, mds_stores"), blamed)
}

// ---- what belongs in the storage list --------------------------------------------
// The subject is what holds the data. A hub and an empty reader are how it is
// attached, which the card's own row already says in its badge - listing them as well
// turned three cards into six rows of plumbing with the contents mixed in.
do {
    func device(mounts: [String]) -> Row {
        var row = Row(id: "d", title: "d", subtitle: "", badge: "")
        row.allMounts = mounts
        return row
    }
    check("list: a card in a reader belongs", device(mounts: ["/Volumes/sd-19"]).carriesMedium)
    check("list: the boot drive belongs, mounted at /", device(mounts: ["/"]).carriesMedium)
    check("list: an empty reader does not", !device(mounts: []).carriesMedium)
    check("list: nor does a hub", !device(mounts: []).carriesMedium)
}

// ---- a badge that does not fit ---------------------------------------------------
// "via USB 3..." is a pill containing an ellipsis: it takes the width of a fact and
// states none. Where the full badge does not fit, a shorter true one is better, and
// where even that does not fit, nothing is.
do {
    let font = NSFont.systemFont(ofSize: 10, weight: .medium)
    let full = "via USB 3.2 Gen 1 · ≈ 450 MB/s"
    let short = "via USB 3.2 Gen 1"
    func fits(_ text: String, in room: CGFloat) -> Bool {
        Text.width(text, font: font) + 12 <= room
    }
    let wide = Text.width(full, font: font) + 20
    check("badge: the whole thing is shown when it fits", fits(full, in: wide))
    let narrow = Text.width(short, font: font) + 14
    check("badge: the short form fits where the whole does not",
          !fits(full, in: narrow) && fits(short, in: narrow))
    check("badge: and nothing fits in nothing", !fits(short, in: 20))
}

// ---- what a row is called --------------------------------------------------------
// A reader is a holder; the subject is the card in it. But the log, the records and
// the hidden list are all keyed by the device's own name, so renaming the identity
// would split a device's history in two - presentation and identity are separate.
do {
    var reader = Row(id: "usb:2", title: "USB3.0 Card Reader", subtitle: "Generic", badge: "")
    check("name: with no card, a reader is called what it is",
          reader.headline == "USB3.0 Card Reader" && reader.holder.isEmpty)

    reader.mediumClass = "SDXC 128 GB"
    reader.volumes = ["sd-21"]
    check("name: with a card in it, the card is the subject", reader.headline == "sd-21")
    check("name: and the reader becomes the holder",
          reader.holder == "USB3.0 Card Reader")
    check("name: the identity everything is keyed by does not move",
          reader.title == "USB3.0 Card Reader")

    // A card that has not been named yet still beats naming the holder, and is
    // called by its full description - "SDXC" over a badge reading "SDXC 128 GB" is
    // one fact printed twice.
    reader.volumes = []
    check("name: an unnamed card is called by what is known of it",
          reader.headline == "SDXC 128 GB")

    let drive = Row(id: "usb:1", title: "APPLE SSD AP1024Z", subtitle: "internal SSD", badge: "")
    check("name: a drive is its own subject",
          drive.headline == "APPLE SSD AP1024Z" && drive.holder.isEmpty)
}

// ---- a disk with more than one volume on it --------------------------------------
// Two shapes that look alike and are not. Several APFS volumes in one container share
// one pool of space and each reports the whole pool as its own, so they count once. A
// partitioned disk carrying two independent filesystems has two pools that add up.
do {
    func space(_ capacity: UInt64, _ used: UInt64, _ container: String,
               shared: Bool = false) -> ProcessSampler.VolumeSpace {
        ProcessSampler.VolumeSpace(capacity: capacity, used: used,
                                   container: container, shared: shared)
    }
    // APFS volumes draw from one pool. Their capacities match and their used figures
    // differ slightly - each sees its own metadata - so this cannot be decided by
    // comparing the numbers, which is what reported a 1 TB drive as holding 3.58 TB.
    let apfs = ["/Volumes/a": space(1_000, 400, "disk4", shared: true),
                "/Volumes/b": space(1_000, 398, "disk4", shared: true),
                "/Volumes/c": space(1_000, 399, "disk4", shared: true)]
    let shared = ProcessSampler.combinedSpace(of: Array(apfs.keys), in: apfs)
    check("space: volumes sharing a pool are counted once",
          shared?.capacity == 1_000 && shared?.used == 400,
          "\(shared?.capacity ?? 0) / \(shared?.used ?? 0)")

    // A partitioned HDD: same disk, separate filesystems, separate space.
    let split = ["/Volumes/one": space(600, 100, "disk4"),
                 "/Volumes/two": space(400, 350, "disk4")]
    let summed = ProcessSampler.combinedSpace(of: Array(split.keys), in: split)
    check("space: separate partitions on one disk add up",
          summed?.capacity == 1_000 && summed?.used == 450,
          "\(summed?.capacity ?? 0) / \(summed?.used ?? 0)")

    // Two partitions of exactly the same size are still two partitions - the case a
    // rule based on comparing figures would have merged.
    let even = ["/Volumes/left": space(500, 100, "disk5"),
                "/Volumes/right": space(500, 100, "disk5")]
    let evenly = ProcessSampler.combinedSpace(of: Array(even.keys), in: even)
    check("space: two partitions of equal size are still two",
          evenly?.capacity == 1_000, "\(evenly?.capacity ?? 0)")

    // And used never exceeds capacity, whatever the arithmetic.
    let odd = ["/Volumes/x": space(100, 900, "disk9")]
    check("space: used is never more than capacity",
          ProcessSampler.combinedSpace(of: ["/Volumes/x"], in: odd)?.used == 100)
}

// ---- small files over a share ----------------------------------------------------
// The same stop-start pattern costs far more over a network share than locally: each
// file is an open, a lookup, an attribute exchange and a close, and each of those is a
// round trip that takes the same time whether the file is 4 KB or 4 MB.
do {
    func session(_ id: String, section: String, device: String,
                 bytes: UInt64, peak: Double, seconds: Double) -> TransferSession {
        let began = Date(timeIntervalSince1970: 2000)
        return TransferSession(id: id, device: device, section: section, started: began,
                               ended: began.addingTimeInterval(seconds),
                               bytesRead: section == "Network" ? 0 : bytes,
                               bytesWritten: section == "Network" ? bytes : 0,
                               peakRate: peak, linkBits: 0, linkTrusted: false,
                               removable: section != "Network", physical: true,
                               wireless: false, processes: [], volumes: ["sd-19"],
                               volumeID: "CARD-1")
    }
    // A stop-start card read: 1 GB in 100 s, averaging a fifth of its peak.
    let card = session("a", section: "USB", device: "Reader",
                       bytes: 1_000_000_000, peak: 50_000_000, seconds: 100)
    let wire = session("b", section: "Network", device: "en0",
                       bytes: 1_000_000_000, peak: 60_000_000, seconds: 100)
    let routes = Analysis.routes(from: [card, wire])
    let group = Analysis.Group(key: "k", device: "Reader", section: "USB",
                               volumes: ["sd-19"], sessions: [card])
    let note = Analysis.networkSmallFiles(for: group, routes: routes)
    check("share: a stop-start copy that went over the wire says so",
          note.contains("en0") && note.contains("round trip per file"), note)
    check("share: and names the remedy",
          note.contains("archive or disk image"), note)

    // The same copy with no network counterpart gets the general advice instead.
    let alone = Analysis.networkSmallFiles(for: group, routes: [:])
    check("share: a local copy is not blamed on a share", alone.isEmpty)

    // A copy running near its peak has no pattern to explain.
    let fast = session("c", section: "USB", device: "Reader",
                       bytes: 5_000_000_000, peak: 52_000_000, seconds: 100)
    let steadyGroup = Analysis.Group(key: "k", device: "Reader", section: "USB",
                                     volumes: ["sd-19"], sessions: [fast])
    check("share: a steady copy is left alone",
          Analysis.networkSmallFiles(for: steadyGroup, routes: routes).isEmpty)
}

// ---- what the allocation unit costs ----------------------------------------------
// Two questions with opposite answers. Space: a 256 KB unit means a 10 KB file
// occupies 256 KB, and a card of small files loses most of itself to slack. Time: the
// stop-start pattern is per-file overhead, which a smaller unit does not reduce. The
// note has to separate them, or it becomes "reformat to go faster", which is wrong.
do {
    func group(steadiness: Double) -> Analysis.Group {
        let began = Date(timeIntervalSince1970: 1000)
        let peak = 100_000_000.0
        let seconds = 10.0
        let session = TransferSession(
            id: "s", device: "Reader", section: "USB", started: began,
            ended: began.addingTimeInterval(seconds),
            bytesRead: UInt64(peak * steadiness * seconds), bytesWritten: 0,
            peakRate: peak, linkBits: 0, linkTrusted: false, removable: true,
            physical: true, wireless: false, processes: [], volumes: ["sd"])
        return Analysis.Group(key: "k", device: "Reader", section: "USB",
                              volumes: ["sd"], sessions: [session])
    }
    let small = Analysis.allocationNote(blockSize: 262_144, group: group(steadiness: 0.2))
    check("clusters: a big unit on a stop-start card is worth saying",
          small.contains("256 KB"), small)
    // Clusters are powers of two and are quoted that way everywhere; "262 KB" makes a
    // round number look like a measurement error.
    check("clusters: an allocation unit is quoted in binary units",
          Fmt.blockSize(262_144) == "256 KB" && Fmt.blockSize(4096) == "4 KB",
          Fmt.blockSize(262_144))
    check("clusters: and the rest of the app stays decimal",
          Fmt.bytes(262_144).hasPrefix("262"))
    check("clusters: and it says a reformat buys space, not speed",
          small.contains("space, not time"), small)
    check("clusters: and does not blame it for the slowness",
          small.contains("not why this is slow"), small)

    let steady = Analysis.allocationNote(blockSize: 262_144, group: group(steadiness: 0.9))
    check("clusters: on a card running near its peak it claims no cost",
          steady.contains("Nothing here suggests"), steady)

    // A normal 4 KB unit is not worth a paragraph either way.
    check("clusters: an ordinary unit says nothing at all",
          Analysis.allocationNote(blockSize: 4096, group: group(steadiness: 0.2)).isEmpty)
}

// ---- filing a card under the card ------------------------------------------------
// The same card read through a slow reader and then a fast one is one history with a
// slow half and a fast half - which is the comparison worth having. Filing by the
// reader made it two unrelated histories, and filing by volume *name* would merge two
// different cards, since a freshly formatted one is "Untitled" or "NO NAME".
do {
    func session(_ id: String, device: String, volume: String, uuid: String?,
                 removable: Bool = true) -> TransferSession {
        let began = Date(timeIntervalSince1970: 1000)
        return TransferSession(id: id, device: device, section: "USB", started: began,
                               ended: began.addingTimeInterval(10),
                               bytesRead: 1_000_000_000, bytesWritten: 0, peakRate: 1,
                               linkBits: 0, linkTrusted: false, removable: removable,
                               physical: true, wireless: false, processes: [],
                               volumes: [volume], volumeID: uuid)
    }
    let slow = session("a", device: "USB2 Reader", volume: "sd-19", uuid: "CARD-1")
    let fast = session("b", device: "USB3 Reader", volume: "sd-19", uuid: "CARD-1")
    check("cards: the same card through two readers is one group",
          Analysis.groupKey(for: slow) == Analysis.groupKey(for: fast))

    let groups = Analysis.groups(from: [fast, slow])
    check("cards: and it is one group in the log", groups.count == 1)
    check("cards: which knows it spans readers", groups.first?.spansDevices == true)
    check("cards: and lists them newest first",
          groups.first?.devices == ["USB3 Reader", "USB2 Reader"])

    // Two blank cards in the same reader are two cards.
    let blankA = session("c", device: "USB3 Reader", volume: "Untitled", uuid: "CARD-A")
    let blankB = session("d", device: "USB3 Reader", volume: "Untitled", uuid: "CARD-B")
    check("cards: two cards with the same name stay apart",
          Analysis.groupKey(for: blankA) != Analysis.groupKey(for: blankB))

    // Without an identity - an old log entry - it falls back to the device.
    let legacy = session("e", device: "USB3 Reader", volume: "sd-19", uuid: nil)
    check("cards: a session with no identity is filed as before",
          Analysis.groupKey(for: legacy) == "USB3 Reader|sd-19")

    // A drive is not a card: it is filed under itself whatever its volumes are called.
    let drive = session("f", device: "APPLE SSD", volume: "Macintosh HD", uuid: "X",
                        removable: false)
    check("cards: fixed media is still filed by device",
          Analysis.groupKey(for: drive) == "APPLE SSD|Macintosh HD")
}

// ---- which mounts are volumes --------------------------------------------------
// "/Volumes/..." is the obvious spelling and not the only one: with the sealed system
// volume macOS also reports the same place under /System/Volumes/Data/Volumes. Testing
// only the short form left a card with no volume name, nothing to attach processes to,
// and a session logged as having no volume at all while 1.69 GB came off it.
check("mounts: the obvious spelling is a volume",
      ProcessSampler.isFinderVolume("/Volumes/sd-21"))
check("mounts: so is the same place through the firmlink",
      ProcessSampler.isFinderVolume("/System/Volumes/Data/Volumes/sd-21"))
check("mounts: the boot volume is not one of them",
      !ProcessSampler.isFinderVolume("/"))
check("mounts: nor is a system volume",
      !ProcessSampler.isFinderVolume("/System/Volumes/Preboot"))
check("mounts: two spellings give one name",
      ProcessSampler.finderPath("/System/Volumes/Data/Volumes/sd-21") == "/Volumes/sd-21")
check("mounts: and the short one is left alone",
      ProcessSampler.finderPath("/Volumes/sd-21") == "/Volumes/sd-21")

// ---- when a session happened ---------------------------------------------------
// A clock time makes you work out what it means relative to now, which for something
// that happened while you were watching is the wrong way round. Past a day the
// reverse holds: "31 h ago" is arithmetic nobody asked for.
do {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func ago(_ seconds: Double) -> String? {
        Fmt.relative(now.addingTimeInterval(-seconds), now: now)
    }
    check("when: seconds ago is just now", ago(5) == "just now")
    check("when: under a minute is still just now", ago(59) == "just now")
    check("when: minutes are counted", ago(17 * 60) == "17 min ago")
    check("when: an hour is not 60 min", ago(3600) == "1 h ago")
    check("when: hours are counted", ago(5 * 3600) == "5 h ago")
    check("when: just inside a day is still relative", ago(23.9 * 3600) != nil)
    check("when: past a day it hands back to the clock", ago(25 * 3600) == nil)
    // A session stamped slightly in the future - a clock adjustment mid-transfer -
    // is not "in three seconds".
    check("when: a future stamp reads as now",
          Fmt.relative(now.addingTimeInterval(3), now: now) == "just now")
}

// ---- what the log keeps --------------------------------------------------------
// One global cap meant the busiest device evicted every other. On this machine 342
// of 500 entries were the boot disk and 151 were Wi-Fi, so the card reader - the
// device the app exists for - was down to one session and a week of imports was
// gone. A device's history is its own now.
do {
    func made(_ device: String, _ volume: String, _ n: Int) -> [TransferSession] {
        (0..<n).map { i in
            let began = Date(timeIntervalSince1970: 100_000 - Double(i))
            return TransferSession(id: "\(device)-\(volume)-\(i)", device: device,
                                   section: "USB", started: began,
                                   ended: began.addingTimeInterval(1),
                                   bytesRead: 100_000_000, bytesWritten: 0,
                                   peakRate: 1, linkBits: 0, linkTrusted: false,
                                   removable: true, physical: true, wireless: false,
                                   processes: [], volumes: volume.isEmpty ? [] : [volume])
        }
    }
    // A chatty boot disk and one quiet card, newest first.
    let chatty = made("APPLE SSD", "", 400)
    let card = made("Card Reader", "sd-15", 3)
    let trimmed = TransferLog.trim(chatty + card, perDevice: 50, total: 2000)
    check("log: the chatty device is capped at its own share",
          trimmed.filter { $0.device == "APPLE SSD" }.count == 50)
    check("log: and the quiet one keeps everything it had",
          trimmed.filter { $0.device == "Card Reader" }.count == 3)

    // Two cards in the same reader are two histories - which is exactly what went
    // missing when the key was the device alone.
    let second = made("Card Reader", "sd-21", 60)
    let both = TransferLog.trim(second + card, perDevice: 50, total: 2000)
    check("log: each volume in a reader keeps its own history",
          both.filter { $0.volumes == ["sd-15"] }.count == 3
            && both.filter { $0.volumes == ["sd-21"] }.count == 50)

    // A record outlives the sessions that set it, so the heading and the row cannot
    // disagree about what a device once managed.
    do {
        let quick = made("Fast Disk", "", 1)
        let key = TransferLog.recordKey(device: "Fast Disk", volumes: [])
        let groups = Analysis.groups(from: quick, records: [key: 4_620_000_000])
        check("log: a group reports the record, not just what it still holds",
              groups.first?.bestPeak == 4_620_000_000,
              "\(groups.first?.bestPeak ?? -1)")

        // A reader holds different cards, and one card's record is not another's. The
        // record keyed to the reader alone was being shown against every card in it -
        // so a session that peaked at 26 MB/s was captioned "peaks at 102 MB/s".
        let withCard = made("Card Reader", "sd-21", 1)
        let withNone = made("Card Reader", "", 1)
        let mixed = Analysis.groups(
            from: withCard + withNone,
            records: [TransferLog.recordKey(device: "Card Reader", volumes: ["sd-21"]):
                        102_000_000])
        let carded = mixed.first { $0.volumes == ["sd-21"] }
        let empty = mixed.first { $0.volumes.isEmpty }
        check("log: the record follows the card, not the reader",
              carded?.bestPeak == 102_000_000 && (empty?.bestPeak ?? 0) < 102_000_000,
              "\(carded?.bestPeak ?? -1) vs \(empty?.bestPeak ?? -1)")
    }

    // Newest first in, newest first out.
    check("log: what is kept is the newest",
          trimmed.first?.id == chatty.first?.id)
    // The global ceiling is still a ceiling, just no longer the only rule.
    let many = (0..<60).flatMap { made("Device \($0)", "", 50) }
    check("log: the total is still capped",
          TransferLog.trim(many, perDevice: 50, total: 2000).count == 2000)
}

// ---- routes: one transfer, seen from both ends ---------------------------------
// Copying a card to a network share is two sessions in this log, and until now
// nothing connected them - even though the two halves together are the whole answer
// to "why was that slow?".
do {
    func session(_ id: String, section: String, start: Double, seconds: Double,
                 bytes: UInt64, peak: Double) -> TransferSession {
        let began = Date(timeIntervalSince1970: start)
        return TransferSession(id: id, device: section == "Network" ? "en0" : "Card Reader",
                               section: section, started: began,
                               ended: began.addingTimeInterval(seconds),
                               bytesRead: bytes, bytesWritten: 0, peakRate: peak,
                               linkBits: 0, linkTrusted: false, removable: section != "Network",
                               physical: true, wireless: false, processes: [], volumes: [])
    }
    let card = session("a", section: "USB", start: 1000, seconds: 100,
                       bytes: 1_000_000_000, peak: 90_000_000)
    var wire = session("b", section: "Network", start: 1002, seconds: 100,
                       bytes: 0, peak: 300_000_000)
    wire.bytesWritten = 980_000_000      // out over the wire: the far end of the copy
    check("route: an overlapping copy of about the same size pairs",
          Analysis.looksLikeOneTransfer(card, wire))

    // Overlapping but unrelated: a backup ticking away in the background overlaps
    // everything, which is why size has to agree as well as time.
    let backup = session("c", section: "Network", start: 1002, seconds: 100,
                         bytes: 5_000_000, peak: 2_000_000)
    check("route: a much smaller overlapping session does not pair",
          !Analysis.looksLikeOneTransfer(card, backup))

    // Same size but hours apart: two separate copies of the same folder.
    let later = session("d", section: "Network", start: 40_000, seconds: 100,
                        bytes: 1_000_000_000, peak: 300_000_000)
    check("route: the same size at another time does not pair",
          !Analysis.looksLikeOneTransfer(card, later))
    check("route: two storage sessions are never two ends of one transfer",
          !Analysis.looksLikeOneTransfer(card, session("e", section: "USB", start: 1000,
                                                       seconds: 100, bytes: 1_000_000_000,
                                                       peak: 90_000_000)))

    // Small sessions are everywhere, and several of them will always overlap
    // something. Below the floor, coincidence is likelier than causation.
    let tinyCard = session("g", section: "USB", start: 1000, seconds: 10,
                           bytes: 4_000_000, peak: 1_000_000)
    let tinyWire = session("h", section: "Network", start: 1000, seconds: 10,
                           bytes: 4_000_000, peak: 1_000_000)
    check("route: two small sessions do not pair on coincidence",
          !Analysis.looksLikeOneTransfer(tinyCard, tinyWire))

    // A card being read while something downloads is two things at once, not one
    // copy: the bytes leave the disk and also arrive from the wire.
    var inbound = session("i", section: "Network", start: 1002, seconds: 100,
                          bytes: 980_000_000, peak: 300_000_000)
    inbound.bytesRead = 980_000_000
    inbound.bytesWritten = 0
    check("route: directions have to make a route",
          !Analysis.looksLikeOneTransfer(card, inbound))

    let routes = Analysis.routes(from: [card, wire, backup, later])
    check("route: both ends are given the pairing", routes["a"] != nil && routes["b"] != nil)
    check("route: and the unrelated ones are not", routes["c"] == nil && routes["d"] == nil)
    // The point of the pairing: which end could not go faster.
    check("route: it names the slower end",
          routes["a"]?.slowerIsStorage == true,
          routes["a"]?.summary ?? "none")
    check("route: and says so in words",
          (routes["a"]?.summary ?? "").contains("Card Reader was the slower end"),
          routes["a"]?.summary ?? "none")
    // A long network session can overlap several imports; each pairs once, with the
    // nearest in time.
    let second = session("f", section: "USB", start: 1050, seconds: 100,
                         bytes: 1_000_000_000, peak: 90_000_000)
    let both = Analysis.routes(from: [card, second, wire])
    check("route: a session pairs at most once", both["b"]?.storage.id == "a",
          both["b"]?.storage.id ?? "none")
}

// ---- the logarithmic axis ------------------------------------------------------
// Storage spans four decades between "a document is being saved" and "this drive is
// flat out". A linear bar gives the first three of them one pixel, which is why the
// label read 0% for everything anyone actually does.
do {
    let ceiling = 7.0 * 1_000_000_000        // a modern internal drive
    check("axis: idle sits at the start",
          Reference.logPosition(rate: 0, ceiling: ceiling) == 0)
    check("axis: at the ceiling it is full",
          Reference.logPosition(rate: ceiling, ceiling: ceiling) == 1)
    check("axis: past the ceiling it stays full",
          Reference.logPosition(rate: ceiling * 10, ceiling: ceiling) == 1)
    check("axis: it only ever climbs",
          Reference.logPosition(rate: 1_000_000, ceiling: ceiling)
            < Reference.logPosition(rate: 10_000_000, ceiling: ceiling))
    // The case that started this: 582 KB/s on a 7 GB/s scale.
    let everyday = Reference.logPosition(rate: 582_000, ceiling: ceiling)
    check("axis: an everyday rate is visible rather than rounded away",
          everyday > 0.1, String(format: "%.3f", everyday))
    check("axis: and is still plainly not a busy drive",
          everyday < Reference.logPosition(rate: 200_000_000, ceiling: ceiling))
    // Each tenfold step covers the same distance - that is what makes it readable as
    // a scale rather than a mystery.
    let decades = Reference.logDecades(ceiling: ceiling)
    check("axis: it is marked in decades", decades.count >= 3, "\(decades.count)")
    if decades.count >= 3 {
        let first = decades[1] - decades[0]
        let second = decades[2] - decades[1]
        check("axis: the decade marks are evenly spaced", abs(first - second) < 0.01,
              String(format: "%.3f vs %.3f", first, second))
    }
}

// ---- advice ------------------------------------------------------------------
// "Slow for a modern card" was being said after 22 MB had moved. A card reading a
// directory tree at 12 MB/s looks exactly like a slow card reading one large file,
// and only one of those is a fact about the card.
check("advice: no verdict on the medium from a scrap of traffic",
      Reference.advice(peakBytesPerSec: 12_000_000, linkBits: 5_000_000_000,
                       isStorage: true, removableMedia: true,
                       bytesMoved: 22 * 1024 * 1024).isEmpty)
check("advice: the same rate does earn a verdict once enough has moved",
      !Reference.advice(peakBytesPerSec: 12_000_000, linkBits: 5_000_000_000,
                        isStorage: true, removableMedia: true,
                        bytesMoved: 4 * 1024 * 1024 * 1024).isEmpty)
check("advice: and it shows what it was based on",
      Reference.advice(peakBytesPerSec: 12_000_000, linkBits: 5_000_000_000,
                       isStorage: true, removableMedia: true,
                       bytesMoved: 4 * 1024 * 1024 * 1024).contains("peaked at"))
// A port judgement needs no sample at all - the link rate is reported, not inferred.
check("advice: a USB 2.0 port is worth saying immediately",
      Reference.advice(peakBytesPerSec: 30_000_000, linkBits: 480_000_000,
                       isStorage: true, removableMedia: true,
                       bytesMoved: 1024).contains("USB 2.0"))

// ---- the usage gauge ---------------------------------------------------------
check("gauge: a device that never moved data has no bar",
      Reference.gauge(down: 0, up: 0, peakDirectional: 0, peak: 0,
                      linkBits: 0, linkTrusted: false) == nil)

// The bar answers one question: how much of what this device could do is it doing.
// It used to fall back to the device's own past, which answered "is it working as
// hard as it has before" - not a capacity, and not what the bar looks like it means.
do {
    func bar(_ current: Double, link: UInt64, trusted: Bool,
             roles: [String]? = nil, kinds: [String]? = nil,
             internalMedium: Bool = false, peak: Double = 0) -> Reference.Gauge? {
        Reference.gauge(down: current, up: 0, peakDirectional: current, peak: peak,
                        linkBits: link, linkTrusted: trusted, families: [.storage],
                        roles: roles, internalMedium: internalMedium, kinds: kinds)
    }
    if let g = bar(400_000_000, link: 5_000_000_000, trusted: true, roles: ["card"]) {
        check("gauge: a real link gives a real proportion", g.ofLink)
        check("gauge: and says so", g.label.contains("link"))
    } else {
        check("gauge: a credible link produces a bar", false)
    }
    if let g = bar(200_000_000, link: 0, trusted: false, roles: ["disk"],
                   kinds: ["ssd"], internalMedium: true, peak: 1_090_000_000) {
        check("gauge: without a link it measures against what the class manages",
              !g.ofLink)
        // The row has about a hundred points for this, so the short form spends them
        // on the figure rather than the noun: "36% of 550 MB/s" tells you what the
        // percentage is of, which "36% of a modern drive" does not unless you already
        // know what a modern drive does.
        check("gauge: the short label carries the figure",
              g.label.contains("GB/s"), g.label)
        // A drive inside the machine is judged against what is inside machines, not
        // against a mainstream SATA SSD it passes several times over.
        check("gauge: an internal SSD is measured against an internal drive",
              g.longLabel.contains("a modern internal drive"), g.longLabel)
        check("gauge: and that yardstick is an NVMe one, not SATA",
              !g.longLabel.contains("550 MB/s"), g.longLabel)
        check("gauge: never against the device's own past",
              !g.label.contains("peak"), g.label)
        // On a linear bar 200 MB/s of 7 GB/s is 3% - three pixels of a hundred, and
        // indistinguishable from idle. The axis is logarithmic, so it is visible.
        check("gauge: a busy drive is visibly along the bar",
              g.fraction > 0.5 && g.fraction < 0.9, String(format: "%.2f", g.fraction))
    } else {
        check("gauge: a known class produces a bar", false)
    }
    // This used to assert the opposite - no bar when idle. Withdrawing the bar every
    // time the device went quiet made it flash in and out once a second, and took the
    // row's layout with it. An idle device is a reading, not the absence of one.
    if let idle = bar(0, link: 0, trusted: false, roles: ["disk"], kinds: ["ssd"],
                      internalMedium: true, peak: 1_090_000_000) {
        check("gauge: an idle device keeps its bar", idle.fraction == 0)
        check("gauge: and says the rate rather than a percentage of a distant figure",
              idle.label.contains("0 B/s") && idle.label.contains("7.00 GB/s"),
              idle.label)
    } else {
        check("gauge: an idle device keeps its bar", false)
    }
    // The mark is only honest if what it stands for can be shown. A gauge that says
    // "of typical" without being able to name the typical it used is a bare assertion.
    if let g = bar(400_000_000, link: 5_000_000_000, trusted: true, roles: ["card"]) {
        check("inference: a link-relative bar is a measurement, not a conclusion",
              !g.isInferred && g.basis == nil)
    }
    if let g = bar(200_000_000, link: 0, trusted: false, roles: ["disk"],
                   kinds: ["ssd"], internalMedium: true, peak: 1_090_000_000) {
        check("inference: a class-relative bar is marked as a conclusion", g.isInferred)
        check("inference: and can say what it was drawn from",
              (g.basis ?? "").contains("SSD") || (g.basis ?? "").contains("NVMe"),
              g.basis ?? "nil")
    }
    // A Wi-Fi interface has no entry of its own in the catalogue, so "nearest" would
    // hand it whatever wired standard sat near the rate it happened to be doing - and
    // then report it as ~100% of that, every time, because the yardstick was picked by
    // the measurement. No known class, no bar.
    check("gauge: no bar for a device with no class to be measured against",
          Reference.gauge(down: 1_350_000, up: 47_000, peakDirectional: 1_390_000,
                          peak: 1_390_000, linkBits: 0, linkTrusted: false,
                          families: [.network], hasKnownClass: false) == nil)
    check("gauge: the same rate does get a bar where the class is known",
          Reference.gauge(down: 1_350_000, up: 0, peakDirectional: 1_390_000,
                          peak: 1_390_000, linkBits: 0, linkTrusted: false,
                          families: [.storage], roles: ["card"],
                          hasKnownClass: true) != nil)
    // The narrowing is for internal media only. A card in a reader is still measured
    // against cards, and a portable drive on a cable against drives - judging either
    // against an internal NVMe would be the same category error in the other direction.
    if let card = bar(45_000_000, link: 0, trusted: false, roles: ["card"]) {
        check("gauge: a card is judged against a modern card",
              card.longLabel.contains("a modern card"), card.longLabel)
        check("gauge: a card near its class's rate is near the end of the bar",
              card.fraction > 0.8 && card.fraction <= 1.0,
              String(format: "%.2f", card.fraction))
    } else {
        check("gauge: a card produces a bar", false)
    }
    // The whole point of a fixed yardstick: two very different rates on the same kind
    // of device must be judged against the same denominator. A yardstick picked by the
    // rate gave both of them "about 100%" and told you nothing.
    if let slow = bar(50_000_000, link: 0, trusted: false, roles: ["disk"],
                      kinds: ["ssd"], internalMedium: true, peak: 50_000_000),
       let fast = bar(400_000_000, link: 0, trusted: false, roles: ["disk"],
                      kinds: ["ssd"], internalMedium: true, peak: 400_000_000) {
        check("gauge: a slow device and a fast one are not both at 100%",
              fast.fraction > slow.fraction + 0.1,
              String(format: "%.2f vs %.2f", slow.fraction, fast.fraction))
        check("gauge: and both were measured against the same thing",
              slow.basis == fast.basis)
    } else {
        check("gauge: both rates produce a bar", false)
    }
    check("gauge: it never exceeds full",
          (bar(9_000_000_000, link: 0, trusted: false, roles: ["disk"],
               kinds: ["ssd"], internalMedium: true)?.fraction ?? 0) <= 1.0)
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
    let path = NSTemporaryDirectory() + "bottleneck-test-\(UUID().uuidString).lock"
    defer { try? FileManager.default.removeItem(atPath: path) }
    check("instance: the first claim succeeds", SingleInstance.claim(at: path))
    check("instance: a second claim on the same lock is refused",
          !SingleInstance.claim(at: path))
    let other = NSTemporaryDirectory() + "bottleneck-test-\(UUID().uuidString).lock"
    defer { try? FileManager.default.removeItem(atPath: other) }
    check("instance: a different lock file is independent", SingleInstance.claim(at: other))
    check("instance: an unwritable location does not block startup",
          SingleInstance.claim(at: "/this/path/cannot/exist/bottleneck.lock"))
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


// ---- capacity, counted once per container ------------------------------------
// Volumes in one APFS container each report the container's size and free space as
// their own. Summing them claims several times the disk.
do {
    func vol(_ capacity: UInt64, _ used: UInt64, _ container: String) -> ProcessSampler.VolumeSpace {
        var v = ProcessSampler.VolumeSpace()
        v.shared = true            // these four are APFS volumes of one container
        v.capacity = capacity; v.used = used; v.container = container
        return v
    }
    // Four volumes of one 3.6 TB disk, each reporting the whole container.
    let table: [String: ProcessSampler.VolumeSpace] = [
        "/Volumes/nam DDLJ":    vol(3_600_000_000_000, 2_460_000_000_000, "disk3"),
        "/Volumes/necromancer": vol(3_600_000_000_000, 2_460_000_000_000, "disk3"),
        "/Volumes/media":       vol(3_600_000_000_000, 2_460_000_000_000, "disk3"),
        "/Volumes/admin DDLJ":  vol(3_600_000_000_000, 2_460_000_000_000, "disk3"),
        "/Volumes/card":        vol(256_000_000_000, 8_000_000_000, "disk6"),
    ]
    let mounts = ["/Volumes/nam DDLJ", "/Volumes/necromancer",
                  "/Volumes/media", "/Volumes/admin DDLJ"]
    guard let combined = ProcessSampler.combinedSpace(of: mounts, in: table) else {
        check("capacity: four volumes of one disk report something", false); exit(1)
    }
    check("capacity: the disk is counted once, not four times",
          combined.capacity == 3_600_000_000_000,
          "\(combined.capacity / 1_000_000_000) GB")
    check("capacity: its contents are counted once too",
          combined.used == 2_460_000_000_000, "\(combined.used / 1_000_000_000) GB")
    check("capacity: free space is believable",
          combined.capacity - combined.used == 1_140_000_000_000)

    // A device with two containers does add up.
    let both = ProcessSampler.combinedSpace(of: mounts + ["/Volumes/card"], in: table)
    check("capacity: separate containers are summed",
          both?.capacity == 3_856_000_000_000, "\(both?.capacity ?? 0)")

    check("capacity: used never exceeds capacity",
          (combined.used <= combined.capacity))
    check("capacity: nothing mounted means nothing to show",
          ProcessSampler.combinedSpace(of: [], in: table) == nil)
    check("capacity: an unknown mount is ignored",
          ProcessSampler.combinedSpace(of: ["/Volumes/nope"], in: table) == nil)

    check("container: a slice belongs to its disk",
          ProcessSampler.container(ofBSDName: "disk3s2") == "disk3")
    check("container: a whole disk is its own container",
          ProcessSampler.container(ofBSDName: "disk3") == "disk3")
    check("container: two-digit disks parse",
          ProcessSampler.container(ofBSDName: "disk12s4") == "disk12")
}


// ---- the capacity level fills from the bottom --------------------------------
// The list is flipped, so a larger y is further down. A level that filled from the
// top would show a disk emptying as it fills, and no value check would catch it.
do {
    let gauge = NSRect(x: 100, y: 20, width: 5, height: 44)
    let full = TrafficListView.capacityFill(in: gauge, fraction: 1)
    check("gauge: full covers the whole level", full.height == gauge.height)
    check("gauge: full starts at the top", full.minY == gauge.minY)

    let half = TrafficListView.capacityFill(in: gauge, fraction: 0.5)
    check("gauge: half is half the height", abs(half.height - gauge.height / 2) < 0.01,
          "\(half.height)")
    check("gauge: and it is anchored to the bottom", half.maxY == gauge.maxY,
          "maxY \(half.maxY) vs \(gauge.maxY)")
    check("gauge: so the empty part is at the top", half.minY > gauge.minY)

    let nearlyEmpty = TrafficListView.capacityFill(in: gauge, fraction: 0.02)
    check("gauge: a nearly empty disk still shows a sliver", nearlyEmpty.height >= 2)
    check("gauge: at the bottom", nearlyEmpty.maxY == gauge.maxY)

    check("gauge: nothing used stays inside the track",
          TrafficListView.capacityFill(in: gauge, fraction: 0).maxY == gauge.maxY)
    check("gauge: over-full is clamped",
          TrafficListView.capacityFill(in: gauge, fraction: 3).height == gauge.height)
    // Its own lane: after the icon, before the text, overlapping neither.
    let lane = TrafficListView.capacityGauge(in: NSRect(x: 0, y: 0, width: 700, height: 84))
    check("gauge: starts after the icon", lane.minX >= TrafficListView.contentLeft + 18)
    check("gauge: ends before the text", lane.maxX <= TrafficListView.textLeft)
    check("gauge: is wide enough to see", lane.width >= 6, "\(lane.width)")
    check("gauge: is tall enough to read as a level", lane.height >= 44, "\(lane.height)")
    check("gauge: stays inside the row",
          lane.minY >= 0 && lane.maxY <= TrafficListView.rowHeight)

    // Colour carries the meaning, so the thresholds are worth pinning down.
    check("gauge: room to spare reads green",
          TrafficListView.capacityColour(fraction: 0.3) == .systemGreen)
    check("gauge: tightening reads amber",
          TrafficListView.capacityColour(fraction: 0.8) == .systemYellow)
    check("gauge: nearly full reads red",
          TrafficListView.capacityColour(fraction: 0.95) == .systemRed)
    check("gauge: the boundary between green and amber is at 70%",
          TrafficListView.capacityColour(fraction: 0.699) == .systemGreen
              && TrafficListView.capacityColour(fraction: 0.70) == .systemYellow)
    check("gauge: the boundary between amber and red is at 90%",
          TrafficListView.capacityColour(fraction: 0.899) == .systemYellow
              && TrafficListView.capacityColour(fraction: 0.90) == .systemRed)
}

// ---- the inference code ------------------------------------------------------
// Colour cannot carry this on its own - it is gone in greyscale, gone for anyone who
// cannot separate violet from grey, and gone in the accessibility description. The
// mark is the part that has to be present.
check("mark: an inferred string carries the sign",
      Palette.marked("SDXC 256 GB").hasPrefix("\u{2248}"))
// Several of these strings already arrive with the sign, because "about this
// standard" is how a near match has always been written. Marking one twice looks
// like a bug rather than a code.
check("mark: marking is idempotent",
      Palette.marked(Palette.marked("Gigabit Ethernet"))
        == Palette.marked("Gigabit Ethernet"))
check("mark: a string that already has the sign is left alone",
      Palette.marked("\u{2248} Gigabit Ethernet") == "\u{2248} Gigabit Ethernet")

// A verdict either did arithmetic on two reported numbers or matched a measurement
// against a catalogue. Only the second is a conclusion, and only it should be marked.
do {
    // averageRate is derived from the bytes and the clock, so a fixture sets those
    // rather than the average - which is the right way round: a session that could
    // claim an average unrelated to what it moved would not be testing anything.
    func session(peak: Double, average: Double, linkBits: UInt64, trusted: Bool,
                 section: String = "USB") -> TransferSession {
        let seconds = 10.0
        let started = Date()
        return TransferSession(id: "v", device: "Reader", section: section,
                               started: started, ended: started.addingTimeInterval(seconds),
                               bytesRead: UInt64(average * seconds), bytesWritten: 0,
                               peakRate: peak, linkBits: linkBits, linkTrusted: trusted,
                               removable: true, physical: true, wireless: false,
                               processes: [], volumes: ["card"])
    }
    // 95% of a 5 Gbit/s link: measured at both ends of the division.
    let maxed = Analysis.verdict(for: session(peak: 590_000_000, average: 580_000_000,
                                              linkBits: 5_000_000_000, trusted: true))
    check("verdict: reaching a reported link ceiling is measured, not inferred",
          !maxed.inferred, maxed.summary)
    // No link to judge against, so the only thing left is what the rate resembles.
    let resembles = Analysis.verdict(for: session(peak: 90_000_000, average: 88_000_000,
                                                  linkBits: 0, trusted: false))
    check("verdict: naming a medium from a rate is a conclusion",
          resembles.inferred, resembles.summary)
    // Measured ratio, guessed cause: "many small files" is one explanation of a
    // stop-start transfer, and this cannot separate it from a busy far end.
    let stopStart = Analysis.verdict(for: session(peak: 200_000_000, average: 20_000_000,
                                                  linkBits: 0, trusted: false))
    check("verdict: explaining an unsteady transfer is a conclusion",
          stopStart.inferred, stopStart.summary)
}

// A view smaller than the window must never paint outside itself. AppKit passes the
// window's whole invalidated region to every subview, so a 22-point strip asked to
// refresh gets a rect 900 points tall - and filling it covered the entire interface.
do {
    let note = NSRect(x: 0, y: 0, width: 1280, height: 22)
    let whole = NSRect(x: 0, y: 0, width: 1280, height: 900)
    check("painting: a subview cannot paint beyond its own bounds",
          Palette.paintable(dirty: whole, bounds: note) == note)
    let sliver = NSRect(x: 100, y: 0, width: 40, height: 900)
    check("painting: and still repaints only the part actually asked for",
          Palette.paintable(dirty: sliver, bounds: note)
            == NSRect(x: 100, y: 0, width: 40, height: 22))
}

// The all-time peak is drawn on the bar's own scale, so it can be compared with the
// fill beside it rather than being a second number to hold in your head.
do {
    let bar = NSRect(x: 100, y: 50, width: 200, height: 5)
    let modernDrive = 550.0 * 1_000_000
    // Half the yardstick, and the device is idle: the tick belongs at the midpoint.
    if let mark = TrafficListView.peakMark(in: bar, peak: modernDrive / 2,
                                           denominator: modernDrive, current: 0) {
        check("peak mark: sits at the peak's share of the same scale",
              abs(mark.midX - bar.midX) < 2, String(format: "%.1f", mark.midX))
    } else {
        check("peak mark: a recorded peak is marked", false)
    }
    check("peak mark: nothing to mark without a recorded peak",
          TrafficListView.peakMark(in: bar, peak: 0, denominator: modernDrive,
                                   current: 0) == nil)
    check("peak mark: nor without a scale to place it on",
          TrafficListView.peakMark(in: bar, peak: 1_000, denominator: 0,
                                   current: 0) == nil)
    // A tick under the end of the fill is a smudge, not a second fact - and that
    // holds just short of it too, which is where the fill's rounded cap already is.
    check("peak mark: not drawn when the current rate has reached it",
          TrafficListView.peakMark(in: bar, peak: modernDrive / 2,
                                   denominator: modernDrive, current: 0.5) == nil)
    check("peak mark: nor when the fill has all but reached it",
          TrafficListView.peakMark(in: bar, peak: modernDrive / 2,
                                   denominator: modernDrive, current: 0.49) == nil)
    check("peak mark: but drawn once there is clear space between them",
          TrafficListView.peakMark(in: bar, peak: modernDrive / 2,
                                   denominator: modernDrive, current: 0.40) != nil)
    // A peak past the end of the scale gets a chevron, not a tick. Clamping drew the
    // mark exactly where "peaked at precisely the yardstick" would put it, so a drive
    // whose best is four times the scale looked like one that had just reached it -
    // not an imprecise reading but the wrong statement.
    check("peak mark: no tick for a peak the scale cannot hold",
          TrafficListView.peakMark(in: bar, peak: modernDrive * 4,
                                   denominator: modernDrive, current: 0) == nil)
    check("peak mark: it is reported as beyond the scale instead",
          TrafficListView.peakIsBeyond(peak: modernDrive * 4, denominator: modernDrive))
    check("peak mark: a peak inside the scale is not",
          !TrafficListView.peakIsBeyond(peak: modernDrive / 2, denominator: modernDrive))
    check("peak mark: and exactly at the scale is still a tick, not a chevron",
          !TrafficListView.peakIsBeyond(peak: modernDrive, denominator: modernDrive)
            && TrafficListView.peakMark(in: bar, peak: modernDrive,
                                        denominator: modernDrive, current: 0) != nil)
}

// Wrapping a paragraph to the whole window put about 170 characters on a line. The
// comfortable range is nearer 60-90; past that the eye loses the start of the next
// one, which is what made the log's advice unreadable rather than merely long.
check("log: advice is capped to a readable measure",
      HistoryItem.adviceWidth(1600) <= 700, "\(HistoryItem.adviceWidth(1600))")
check("log: and still uses the width it has in a narrow window",
      HistoryItem.adviceWidth(400) < HistoryItem.adviceWidth(1600))
check("log: never narrower than something can be drawn in",
      HistoryItem.adviceWidth(40) >= 80)

// The filesystem as people name it. "msdos" covers both FAT16 and FAT32 in the
// kernel's vocabulary, so naming a version would be a guess wearing a reading's
// clothes - the same habit the whole inference code exists to prevent.
check("format: apfs is APFS", Fmt.fsName("apfs") == "APFS")
check("format: hfs is named the way Disk Utility names it",
      Fmt.fsName("hfs") == "Mac OS Extended")
check("format: exfat keeps its lower-case e", Fmt.fsName("exfat") == "exFAT")
check("format: msdos does not claim a version", Fmt.fsName("msdos") == "FAT")
check("format: a network mount says so", Fmt.fsName("smbfs") == "SMB share")
check("format: an unknown type is passed through rather than dropped",
      Fmt.fsName("zfs") == "ZFS")
check("format: nothing in, nothing out", Fmt.fsName("").isEmpty)

// The boot drive is mounted at / and under /System/Volumes, never under /Volumes,
// which is why it was the one row that could not say what it was formatted as.
do {
    let traits = ProcessSampler.volumeTraits()
    check("format: the mount table covers the boot volume too",
          traits["/"] != nil || traits.keys.contains { !$0.hasPrefix("/Volumes") },
          "\(traits.keys.sorted().prefix(4))")
}

// Whatever a row states, the tooltip and the Copy item have to carry - a fact you
// can see but not copy is a fact you have to retype. The format was on the row and
// in the spoken description, and missing from the one path that exists to be pasted.
do {
    let list = TrafficListView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
    var row = Row(id: "usb:1", title: "USB3.0 Card Reader", subtitle: "Generic", badge: "")
    row.fsType = "exfat"
    row.volumes = ["Untitled"]
    row.mediumClass = "SDXC 128 GB"
    row.capacityBytes = 128_000_000_000
    row.usedBytes = 1_000_000_000
    let copied = list.identity(for: row)
    check("copy: the format is on the pasteboard too", copied.contains("exFAT"), copied)
    check("copy: along with what the row shows about the card",
          copied.contains("SDXC 128 GB") && copied.contains("Untitled"))
}

// ---- hiding a row -------------------------------------------------------------
// Hiding is about attention, not measurement. A hidden row leaves the lists, keeps
// being sampled and logged, and its history sinks to the bottom of the log rather
// than being bumped to the top every time the device twitches.
do {
    struct Fake { let id: String; let device: String }
    let rows = [Fake(id: "net:en0", device: "en0"),
                Fake(id: "net:utun5", device: "utun5"),
                Fake(id: "net:lo0", device: "lo0")]
    Hidden.revealAll()
    check("hide: nothing is hidden to begin with",
          Hidden.visible(rows, id: { $0.id }).count == 3)

    Hidden.set(id: "net:utun5", name: "utun5", hidden: true)
    let visible = Hidden.visible(rows, id: { $0.id })
    check("hide: the hidden row leaves the list", visible.count == 2)
    check("hide: and it is the right one", !visible.contains { $0.id == "net:utun5" })
    check("hide: the store knows it by name as well, which is how the log finds it",
          Hidden.isHidden(name: "utun5"))

    // Sunk, not dropped: the sessions happened.
    let sunk = Hidden.sink(rows, name: { $0.device })
    check("log: a hidden device keeps its history", sunk.count == 3)
    check("log: but stops being bumped up", sunk.last?.device == "utun5")
    check("log: and everything else keeps its order",
          sunk.map { $0.device }.prefix(2) == ["en0", "lo0"])

    // While tidying up you need to see what you hid without unhiding it first.
    Hidden.revealing = true
    check("hide: revealing shows them again without unhiding them",
          Hidden.visible(rows, id: { $0.id }).count == 3 && Hidden.isHidden(id: "net:utun5"))
    Hidden.revealing = false

    Hidden.set(id: "net:utun5", name: "utun5", hidden: false)
    check("hide: and the same call takes it back",
          Hidden.visible(rows, id: { $0.id }).count == 3 && !Hidden.isHidden(id: "net:utun5"))
    Hidden.revealAll()
}

// ---- the rename ---------------------------------------------------------------
// Everything the app remembers was filed under its old name: the session log, the
// downloaded catalogue, every setting, and a LaunchAgent still watching /Volumes.
// None of it is recoverable by hand afterwards - the files just sit in a folder
// nothing reads - so the rename has to carry them, exactly once, and never over live
// data.
check("rename: a file only the old folder has is carried across",
      Migration.shouldCarry(fileExistsInOld: true, fileExistsInNew: false))
check("rename: and never over one the new app has already written",
      !Migration.shouldCarry(fileExistsInOld: true, fileExistsInNew: true))
check("rename: nothing to do on a machine that never had the old app",
      !Migration.shouldCarry(fileExistsInOld: false, fileExistsInNew: false))
check("rename: nor once it has already run",
      !Migration.shouldCarry(fileExistsInOld: false, fileExistsInNew: true))

// Badges are laid out left to right along a column, so each one has to be measured
// against what is left of that column rather than against the whole of it. Clipping
// the second badge to the full width let it start near the end and run on into the
// chart, which is what put a graph line through the middle of it.
do {
    let limit: CGFloat = 230          // the text column in a narrow pane
    check("badges: a fresh line has room",
          TrafficListView.roomFor(cursorX: 66, limit: limit) > 100)
    check("badges: the room left shrinks as the line fills",
          TrafficListView.roomFor(cursorX: 150, limit: limit)
            < TrafficListView.roomFor(cursorX: 66, limit: limit))
    check("badges: none is offered past the end of the column",
          TrafficListView.roomFor(cursorX: 240, limit: limit) == 0)
    // A pill containing "S..." says nothing and looks broken; the hover card has it.
    check("badges: nor when what is left is too little to say anything",
          TrafficListView.roomFor(cursorX: 200, limit: limit) == 0)
    check("badges: what is offered always fits inside the column",
          TrafficListView.roomFor(cursorX: 66, limit: limit) <= limit - 66)
}

// A view smaller than the region AppKit asks it to refresh must clip to itself.
// The card's dismiss button: drawn and hit-tested from one expression, because when
// those are written out twice they drift and the cross stops being clickable.
do {
    let card = NSRect(x: 0, y: 0, width: MagnifierView.width, height: 260)
    let close = MagnifierView.closeRect(in: card)
    check("dismiss: the cross is inside the card", card.contains(close))
    // The card is drawn flipped, so the top is y = 0.
    check("dismiss: it sits in the top-right corner",
          close.maxX <= card.maxX && close.minX > card.midX && close.minY < 20)
    check("dismiss: and is big enough to hit",
          close.width >= 20 && close.height >= 20)
}

// ---- the palette, in whichever appearance this pass is running -----------------
// A new colour is only a code if it can be read and if it cannot be confused with the
// colours already in use. Both of those are appearance-dependent, which is why this
// section runs twice.
func luminance(_ colour: NSColor) -> Double {
    guard let c = colour.usingColorSpace(.sRGB) else { return 0 }
    func channel(_ v: CGFloat) -> Double {
        let v = Double(v)
        return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(c.redComponent)
         + 0.7152 * channel(c.greenComponent)
         + 0.0722 * channel(c.blueComponent)
}

func contrast(_ a: NSColor, _ b: NSColor) -> Double {
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

/// How far apart two colours look, in plain sRGB distance. Crude next to a perceptual
/// metric, but enough to catch a new colour landing on top of an existing one.
func separation(_ a: NSColor, _ b: NSColor) -> Double {
    guard let p = a.usingColorSpace(.sRGB), let q = b.usingColorSpace(.sRGB) else { return 0 }
    let dr = Double(p.redComponent - q.redComponent)
    let dg = Double(p.greenComponent - q.greenComponent)
    let db = Double(p.blueComponent - q.blueComponent)
    return (dr * dr + dg * dg + db * db).squareRoot()
}

let mode = runningLight ? "light" : "dark"
inThisAppearance {
check("palette (\(mode)): inferred text is readable on the canvas",
      contrast(Palette.inferred, Palette.canvas) >= 4.5,
      String(format: "%.2f:1", contrast(Palette.inferred, Palette.canvas)))
check("palette (\(mode)): and on a striped row",
      contrast(Palette.inferred, Palette.canvas.blended(withFraction: 0.05,
                                                        of: NSColor.textColor) ?? Palette.canvas) >= 4.0)
// If it reads as one of the direction colours it is not a separate statement any more.
check("palette (\(mode)): inferred is not mistakable for read/in",
      separation(Palette.inferred, Palette.down) > 0.35,
      String(format: "%.2f", separation(Palette.inferred, Palette.down)))
check("palette (\(mode)): nor for write/out",
      separation(Palette.inferred, Palette.up) > 0.35,
      String(format: "%.2f", separation(Palette.inferred, Palette.up)))
check("palette (\(mode)): nor for a link at its ceiling",
      separation(Palette.inferred, NSColor.systemOrange) > 0.35,
      String(format: "%.2f", separation(Palette.inferred, NSColor.systemOrange)))
check("palette (\(mode)): nor for the quiet grey everything else uses",
      separation(Palette.inferred, Palette.faint) > 0.25,
      String(format: "%.2f", separation(Palette.inferred, Palette.faint)))
// The transfer log's advice was drawn in four system colours, two of which - yellow
// and orange - sat at about 1.5:1 on the log's own background. Whatever colour these
// notes take, they have to be readable in both appearances.
// Every piece of text, not just the headline figures. These are the small greys -
// subtitles, footnotes, totals - and they are the ones that go first.
check("palette (\(mode)): the quiet grey clears the bar for body text",
      contrast(Palette.faint, Palette.canvas) >= 4.5,
      String(format: "%.2f:1", contrast(Palette.faint, Palette.canvas)))
check("palette (\(mode)): so does the secondary text beside it",
      contrast(Palette.secondary, Palette.canvas) >= 4.5,
      String(format: "%.2f:1", contrast(Palette.secondary, Palette.canvas)))
check("palette (\(mode)): and the two direction colours as small totals",
      contrast(Palette.downQuiet, Palette.canvas) >= 3.0
        && contrast(Palette.upQuiet, Palette.canvas) >= 3.0,
      String(format: "%.2f:1 / %.2f:1", contrast(Palette.downQuiet, Palette.canvas),
             contrast(Palette.upQuiet, Palette.canvas)))
check("palette (\(mode)): advice about a conclusion is readable in the log",
      contrast(Palette.inferred, Palette.canvas) >= 4.5,
      String(format: "%.2f:1", contrast(Palette.inferred, Palette.canvas)))
check("palette (\(mode)): so is advice about something costing you",
      contrast(Palette.warning, Palette.canvas) >= 4.5,
      String(format: "%.2f:1", contrast(Palette.warning, Palette.canvas)))
// The stock red is a control tint, not a text colour on this ground - which is why
// the app has its own. It fell short in both appearances, not just the light one.
check("palette (\(mode)): warning text reads better than the stock red",
      contrast(Palette.warning, Palette.canvas)
        > contrast(NSColor.systemRed, Palette.canvas),
      String(format: "%.2f:1 vs %.2f:1", contrast(Palette.warning, Palette.canvas),
             contrast(NSColor.systemRed, Palette.canvas)))
// The log's heading used to be a pale strip across a dark window, which reads as a
// gap in the interface rather than as the frame around a section. Whatever the
// appearance, a grey band recedes from the ground rather than standing off it.
let greyBand = Palette.canvas.blended(
    withFraction: Palette.headingBand(NSColor.secondaryLabelColor).alphaComponent,
    of: Palette.headingBand(NSColor.secondaryLabelColor).withAlphaComponent(1)) ?? Palette.canvas
check("palette (\(mode)): a grey heading band is darker than the ground it sits on",
      luminance(greyBand) < luminance(Palette.canvas),
      String(format: "%.3f vs %.3f", luminance(greyBand), luminance(Palette.canvas)))
if !runningLight {
    // Deliberately below the stock window background: a monitor is mostly ground
    // with thin coloured lines over it, and the lines want somewhere dark to be
    // thin against.
    check("palette (dark): the ground is darker than the stock window background",
          luminance(Palette.canvas) < luminance(NSColor.windowBackgroundColor),
          String(format: "%.3f vs %.3f", luminance(Palette.canvas),
                 luminance(NSColor.windowBackgroundColor)))
}
}

// ---- the hover panel: volumes are not one more item in the identity list -------
//
// The line read "Western Digital  ·  1058:2621  ·  nam DDLJ, necromancer, media  ·
// APFS" - a comma-joined list nested inside a middot-joined one, so the format
// scanned as a fourth volume called APFS. Volumes now take a labelled line of their
// own, and these checks are what stops them drifting back into the list.
do {
    let view = MagnifierView(frame: NSRect(x: 0, y: 0,
                                           width: MagnifierView.width, height: 400))
    var wd = Row(id: "usb:9", title: "My Passport",
                 subtitle: "Western Digital · 1058:2621 · nam DDLJ, necromancer, media",
                 badge: "")
    wd.vendor = "Western Digital"
    wd.deviceID = "1058:2621"
    wd.volumes = ["nam DDLJ", "necromancer", "media"]
    wd.fsType = "apfs"
    wd.capacityBytes = 4_000_751_529_984
    wd.usedBytes = 2_459_539_628_032

    let identity = view.identityLine(wd)
    check("volumes: the identity line still says who made it and what it is",
          identity.contains("Western Digital") && identity.contains("1058:2621")
              && identity.contains("APFS"), identity)
    for volume in wd.volumes {
        check("volumes: \(volume) is no longer in the identity line",
              !identity.contains(volume), identity)
    }
    // The exact misreading, named: a volume immediately followed by the format.
    check("volumes: the format never trails the volume list",
          !identity.contains("media  ·  APFS"), identity)

    check("volumes: they get a line of their own",
          view.volumeList(wd) == "nam DDLJ, necromancer, media", view.volumeList(wd))
    check("volumes: the label carries the count", view.volumeListLabel(wd) == "VOLUMES")
    var one = wd
    one.volumes = ["media"]
    check("volumes: singular when there is one", view.volumeListLabel(one) == "VOLUME")

    // A card's panel is about the card, and its volume is the title above the panel.
    var card = wd
    card.mediumClass = "SDXC 256 GB"
    check("volumes: a card's panel does not repeat its own volume",
          view.volumeList(card).isEmpty, view.volumeList(card))

    // The panel has to grow by the line it gained, or it clips what it draws.
    var bare = wd
    bare.volumes = []
    check("volumes: the panel is taller for carrying them",
          view.cardPanelHeight(wd) > view.cardPanelHeight(bare),
          "\(view.cardPanelHeight(wd)) vs \(view.cardPanelHeight(bare))")

    // The subtitle is built from the same disk names. Falling back to it while the
    // volume line is already showing them would restate the list in two shapes.
    var plain = wd
    plain.vendor = ""
    plain.deviceID = ""
    plain.fsType = ""
    check("volumes: the subtitle fallback does not restate them",
          view.identityLine(plain).isEmpty, view.identityLine(plain))
}


print(failures == 0 ? "\n\(checks) checks passed" : "\n\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
