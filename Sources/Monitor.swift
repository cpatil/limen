import Foundation

/// One line in the list, already reduced to display-ready values.
struct Row {
    var id: String
    var title: String
    var subtitle: String
    var badge: String
    var down: Double = 0
    var up: Double = 0
    var totalDown: UInt64 = 0
    var totalUp: UInt64 = 0
    var downHist: [Double] = []
    var upHist: [Double] = []
    var note: String = ""
    /// Currently moving data.
    var active: Bool = false
    /// Backed by real hardware, so it is counted in the headline total and never hidden.
    var isPhysical: Bool = false
    /// Negotiated link rate in bits/sec, for the utilisation read-out. 0 when unknown.
    var linkBits: UInt64 = 0
    /// Highest combined rate seen this session, so you can tell whether a link ever
    /// approached its ceiling rather than only what it is doing right now.
    var peak: Double = 0
    /// Highest rate seen in a single direction. Utilisation is measured against this
    /// rather than the combined figure, because links are full duplex.
    var peakDirectional: Double = 0
    /// The best this device has ever been seen to do, across every run - taken from
    /// the transfer log rather than from this session, which may have been idle.
    var allTimePeak: Double = 0
    /// "Network" or "USB" - both are shown on one page now, grouped under headings.
    var section: String = ""
    /// Processes the kernel says are moving this data, most active first.
    var actors: [Actor] = []
    /// A quiet suggestion about this device, when the measurements support one.
    var hint: String = ""
    /// What Apple calls this link, when that differs from the neutral name.
    var appleName: String = ""
    /// Other names the same wire goes by - the USB-IF has renamed it more than once,
    /// and the marketing name on the box ("USB 5Gbps") is not the one in the spec.
    var alsoKnown: String = ""
    /// What it is sold as today, which is none of the specification names.
    var marketingName: String = ""
    /// Identity, kept as separate fields rather than one joined subtitle so it can be
    /// shown and copied on its own.
    var vendor: String = ""
    var deviceID: String = ""
    var volumes: [String] = []
    /// What to draw beside the name.
    var icon: IconKind = .hub
    /// The medium can be taken out - a card rather than a fixed disk. Drives which
    /// advice applies.
    var removable: Bool = false
    /// Which SD family the card in this reader belongs to, with its capacity, when the
    /// device is one that reads cards. Empty otherwise.
    var mediumClass: String = ""

    /// What to call this row on screen, which is not always what it is filed under.
    ///
    /// A card reader is a holder: the subject is the card in it. The title stays the
    /// device's own name because the session log, the records and the hidden list are
    /// all keyed by it - renaming the identity would split a device's history in two -
    /// so presentation and identity are separate things.
    var headline: String {
        guard !mediumClass.isEmpty else { return title }
        if let volume = volumes.first, !volume.isEmpty { return volume }
        // No name yet: the card's own description is the best title available, and
        // saying "SDXC" while a badge underneath says "SDXC 394 GB" is one fact
        // printed twice.
        return mediumClass
    }

    /// The holder, named for a row whose subject is what is inside it.
    var holder: String { mediumClass.isEmpty ? "" : title }

    /// Type, capacity and name in one label - "SDXC 256 GB · sd-14". Composed in one
    /// place so the row, the hover card and the tooltip cannot drift apart.
    static func cardLabel(class mediumClass: String, volumes: [String]) -> String {
        guard !mediumClass.isEmpty else { return "" }
        guard !volumes.isEmpty else { return mediumClass }
        return mediumClass + "  ·  " + volumes.joined(separator: ", ")
    }
    /// Wireless, as reported by SystemConfiguration rather than guessed from a name.
    var wireless: Bool = false
    /// Whether the reported link rate can be presented as a capacity at all.
    var linkTrusted: Bool = true
    /// Which reference speeds this row may be compared against. Comparing a Wi-Fi
    /// interface to USB 1.1, or a USB 3.0 card reader to USB 2.0, is arithmetically
    /// nearest and completely meaningless.
    var compareFamilies: [SpeedRef.Family] = []
    /// Which kind of medium this is measured against - "card" for something in a
    /// reader, "disk" for a drive. Empty means the whole family is fair game.
    var compareRoles: [String] = []
    /// A drive inside the machine, so cable-only media are not fair comparisons.
    var internalMedium: Bool = false
    /// What the medium is, when the system says: ssd, spinning or flash. Empty when
    /// it does not, in which case the class is inferred from what the device has done.
    var mediumKinds: [String] = []
    /// Whether this row is a thing that holds data, rather than something data passes
    /// through.
    ///
    /// A hub and an empty card reader are both real USB devices and neither is the
    /// subject of anything: the subject is the card, and the reader is how the card is
    /// attached - which the row already says in its badge. Six rows for three cards,
    /// two readers and a hub is a list of plumbing with the contents mixed in.
    var carriesMedium: Bool { !allMounts.isEmpty }

    /// Whether there is a class of device in the catalogue this row can honestly be
    /// measured against. A drive or a card has one; a Wi-Fi interface does not, and
    /// matching it to the nearest wired standard says nothing except that a number
    /// exists near another number.
    var hasKnownMediumClass: Bool { !compareRoles.isEmpty || !mediumKinds.isEmpty }

    /// How full the device is. Counted once per container, so a disk with several
    /// volumes mounted is not reported several times over.
    var capacityBytes: UInt64 = 0
    var usedBytes: UInt64 = 0

    var fullness: Double? {
        guard capacityBytes > 0 else { return nil }
        return min(1, Double(usedBytes) / Double(capacityBytes))
    }

    /// Whether Spotlight indexing is worth reporting for this row.
    ///
    /// Only for storage you plug in. Indexing the boot disk is what makes the machine
    /// searchable, so flagging it red would be advice nobody should take; a card you
    /// import from gains nothing from being indexed and pays for it in wear and
    /// contention.
    var indexingWorthReporting: Bool {
        section != "Network" && !internalMedium && !mountRoots.isEmpty
    }
    /// One mounted volume's own facts.
    ///
    /// Per volume, because that is what they are. A disk can carry an exFAT partition
    /// beside an APFS one, and on every modern Mac the sealed system volume is
    /// read-only while the Data volume on the same disk is not. Reporting one of them
    /// as "the device's format" is a statement about a volume wearing a device's name.
    struct VolumeDetail {
        /// What Finder calls it - the name in the volume list.
        var name: String = ""
        var mount: String = ""
        var device: String = ""
        var fsType: String = ""
        var blockSize: UInt32 = 0
        var readOnly = false
        var uuid: String = ""
        var created: Date?
    }

    /// Every mounted volume of this device, each with its own facts. The panel draws
    /// these as rows; a card is simply the case where there is one.
    var volumeDetails: [VolumeDetail] = []

    /// The first volume's identity, independent of the reader or port it arrived
    /// through - so a card's history follows the card.
    ///
    /// These next few are the FIRST volume's facts, not the device's. They are kept
    /// because a session belongs to one volume and the log needs a single value to
    /// file it under; for the many devices that carry exactly one volume they are
    /// exact. Anything that means to describe the whole device reads volumeDetails.
    var volumeID: String = ""
    /// The allocation unit, the lock switch, and the device node: three facts about a
    /// card that nothing on a Mac normally shows you.
    var blockSize: UInt32 = 0
    var readOnly = false
    var deviceNode: String = ""
    var created: Date?
    /// The filesystem on the mounted volume, and what it does to itself when read.
    var fsType: String = ""
    var journalWrites: Bool = false
    var spotlight: Bool = false
    /// Spotlight has been told never to index this volume.
    var indexingDisabled: Bool = false
    /// Every place this device is mounted. A single enclosure often carries
    /// several partitions, and the traffic may be on any of them.
    var mountRoots: [String] = []
    /// Every mount of this device, including ones outside /Volumes. The boot drive
    /// lives at "/" and "/System/Volumes/...", so filtering to /Volumes - right for
    /// naming volumes and for attributing open files - left it with no capacity at all.
    var allMounts: [String] = []
}

extension Row {
    /// Storage is read and written; a network carries traffic in and out. Using one
    /// vocabulary for both would be wrong for one of them.
    var isStorageLike: Bool { section != "Network" }
    var inShort: String { isStorageLike ? "R" : "IN" }
    var outShort: String { isStorageLike ? "W" : "OUT" }
    var inLong: String { isStorageLike ? "READ" : "IN" }
    var outLong: String { isStorageLike ? "WRITE" : "OUT" }
}

/// Samples the system on a timer and turns raw cumulative counters into rates.
final class Monitor {
    enum Mode {
        case network
        case usb
    }

    static let historyLength = 150

    /// Helper -> owning application, from the catalogue.
    static let processOwners: [String: String] = Catalogue.load().processOwners ?? [:]

    var onUpdate: (() -> Void)?
    var interval: TimeInterval = 1.0 {
        didSet { restartTimer() }
    }
    var showInactive = false
    /// Ordering is per section, not global. What you want from a handful of network
    /// interfaces (a stable list you can find Wi-Fi in) is rarely what you want from a
    /// stack of cards and drives (whichever is busiest), so each keeps its own choice.
    var storageSort: SortOrder = .activeFirst
    var networkSort: SortOrder = .activeFirst
    /// Row ids in the arrangement the user dragged them into, per section.
    var storageOrder: [String] = []
    var networkOrder: [String] = []
    /// The "active first" arrangement as it stood when it was last worked out. Empty
    /// means it has not been decided yet, so the next sample decides and keeps it.
    private var storagePinned: [String] = []
    private var networkPinned: [String] = []

    /// Forget the held arrangement so the next sample works it out again. This is what
    /// the Re-sort command does: nothing is reordered on the spot, the next tick simply
    /// finds no arrangement to hold and establishes a new one.
    func resortNow() {
        storagePinned = []
        networkPinned = []
    }

    /// How the list is ordered. Rate-ranked ordering is available but not the
    /// default: it reshuffles the list every second, which is unreadable while
    /// anything is busy.
    enum SortOrder: Int {
        case activeFirst = 0
        case name = 1
        case rate = 2
        case total = 3
        /// An arrangement the user dragged into place. Chosen automatically the moment
        /// a row is dragged, since that is unambiguously what dragging one means.
        case manual = 4

        var title: String {
            switch self {
            case .activeFirst: return "Active first"
            case .name: return "Name"
            case .rate: return "Current rate"
            case .total: return "Total moved"
            case .manual: return "Custom order"
            }
        }
    }

    /// Ordering is applied here so both sections agree, and so "active first" stays
    /// stable: it groups by whether a row is carrying traffic, then sorts by name
    /// within each group, rather than by a rate that changes every tick.
    static func ordered(_ rows: [Row], by order: SortOrder,
                        manual: [String] = [], pinned: [String] = []) -> [Row] {
        func byName(_ a: Row, _ b: Row) -> Bool {
            a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        func activeFirst(_ a: Row, _ b: Row) -> Bool {
            if a.active != b.active { return a.active }
            if a.isPhysical != b.isPhysical { return a.isPhysical }
            return byName(a, b)
        }
        switch order {
        case .activeFirst:
            // Held, not recomputed. Ordering by "is it busy right now" every second
            // means rows swap places while you are reading them, which is what the
            // sort was meant to avoid in the first place. The arrangement is decided
            // once - at launch, or when Re-sort is chosen - and then left alone.
            // Anything that appears afterwards goes to the end rather than shoving
            // its way into the middle.
            return held(rows, order: pinned, newcomersBy: activeFirst)
        case .name:
            return rows.sorted(by: byName)
        case .rate:
            return rows.sorted { a, b in
                let l = a.down + a.up, r = b.down + b.up
                return l != r ? l > r : byName(a, b)
            }
        case .total:
            return rows.sorted { a, b in
                let l = a.totalDown + a.totalUp, r = b.totalDown + b.totalUp
                return l != r ? l > r : byName(a, b)
            }
        case .manual:
            return held(rows, order: manual, newcomersBy: byName)
        }
    }

    /// Rows in the order given by `order`, with anything not named in it appended,
    /// sorted among themselves by `newcomersBy`.
    ///
    /// An empty `order` means nothing has been decided yet, so the fallback comparator
    /// decides everything - which is how the first sample after launch establishes the
    /// arrangement that later samples then hold.
    private static func held(_ rows: [Row], order: [String],
                             newcomersBy fallback: (Row, Row) -> Bool) -> [Row] {
        guard !order.isEmpty else { return rows.sorted(by: fallback) }
        var rank: [String: Int] = [:]
        for (index, id) in order.enumerated() { rank[id] = index }
        let known = order.compactMap { id in rows.first { $0.id == id } }
        let newcomers = rows.filter { rank[$0.id] == nil }.sorted(by: fallback)
        return known + newcomers
    }

    private(set) var networkRows: [Row] = []
    private(set) var usbRows: [Row] = []
    /// Everything, including what has been hidden - this is what the log is fed.
    private(set) var recordableNetworkRows: [Row] = []
    private(set) var recordableUSBRows: [Row] = []
    // Histories start pre-filled with zeros so graphs render at full width from the first
    // sample instead of creeping in as a sliver at the right edge.
    private(set) var totalDownHist: [Double] = Array(repeating: 0, count: Monitor.historyLength)
    private(set) var totalUpHist: [Double] = Array(repeating: 0, count: Monitor.historyLength)
    private(set) var totalDown: Double = 0
    private(set) var totalUp: Double = 0
    private(set) var usbTotalDown: Double = 0
    private(set) var usbTotalUp: Double = 0
    private(set) var usbDownHist: [Double] = Array(repeating: 0, count: Monitor.historyLength)
    private(set) var usbUpHist: [Double] = Array(repeating: 0, count: Monitor.historyLength)
    // Everything at once, for the combined view.
    private(set) var allDown: Double = 0
    private(set) var allUp: Double = 0
    private(set) var allDownHist: [Double] = Array(repeating: 0, count: Monitor.historyLength)
    private(set) var allUpHist: [Double] = Array(repeating: 0, count: Monitor.historyLength)

    /// Interfaces and USB devices on one page, each under its own heading.
    var combinedRows: [Row] { networkRows + usbRows }

    private var prevNet: [String: NetCounters] = [:]
    private var prevUSB: [String: USBDeviceInfo] = [:]
    private var lastSample: CFAbsoluteTime = 0
    private var peaks: [String: Double] = [:]
    /// Link rates seen per interface. A real link speed is a constant; a value that
    /// moves is a per-frame PHY rate, which is not a capacity and must not be shown
    /// as one. macOS reports Wi-Fi this way - the same interface read 304 Mbit/s and
    /// 30.2 Mbit/s minutes apart while moving far more than either.
    private var linkRateSeen: [String: UInt64] = [:]
    private var linkRateVaries: Set<String> = []
    private var prevProcs: [Int32: ProcSample] = [:]
    private var procs: [Int32: ProcSample] = [:]
    private var mounts: [String: String] = [:]
    private var traits: [String: ProcessSampler.VolumeTraits] = [:]
    private var space: [String: ProcessSampler.VolumeSpace] = [:]
    /// Set when something changed a volume out from under the sampler - turning off
    /// indexing, say - so the next tick re-reads rather than showing the old answer
    /// for another few seconds.
    private var volumesDirty = false

    func volumeStateChanged() { volumesDirty = true }
    private var mountRefresh = 0
    private var histDown: [String: [Double]] = [:]
    private var histUp: [String: [Double]] = [:]
    private var friendly: [String: String] = [:]
    private var wireless: Set<String> = []
    private var friendlyRefresh = 0
    private var timer: Timer?

    func start() {
        friendly = NetSampler.friendlyNames()
        wireless = NetSampler.wirelessNames()
        primeCounters()
        restartTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func restartTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        // .common keeps the readout live while the user is dragging or resizing the window.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Takes a throwaway first sample so the initial displayed rate is a real delta, not a spike.
    private func primeCounters() {
        prevNet = NetSampler.sample()
        for device in USBSampler.sample() { prevUSB[device.id] = device }
        lastSample = CFAbsoluteTimeGetCurrent()
    }

    @objc private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastSample
        guard elapsed > 0.05 else { return }
        lastSample = now

        // SystemConfiguration lookups are comparatively expensive; refresh names occasionally
        // rather than every tick so the loop stays cheap on slower hardware.
        friendlyRefresh += 1
        if friendlyRefresh % 10 == 0 {
            friendly = NetSampler.friendlyNames()
            wireless = NetSampler.wirelessNames()
        }

        // Snapshot the previous interface counters before updateNetwork replaces them:
        // updateUSB needs them to compute deltas for USB network adapters.
        let previousNet = prevNet
        let net = NetSampler.sample()
        // Mount points move rarely; processes change constantly.
        mountRefresh += 1
        if mounts.isEmpty || volumesDirty || mountRefresh % 5 == 0 {
            volumesDirty = false
            mounts = ProcessSampler.mountPoints()
            // What each volume does to itself while being read. Refreshed with the
            // mount table rather than every tick - it only changes on mount.
            traits = ProcessSampler.volumeTraits()
            space = ProcessSampler.volumeSpace()
        }
        prevProcs = procs
        procs = ProcessSampler.sample()
        updateNetwork(net, elapsed: elapsed)
        updateUSB(net, previousNet: previousNet, elapsed: elapsed)
        // Fold this sample into the transfer history.
        TransferLog.shared.record(rows: recordableNetworkRows + recordableUSBRows)

        // Then read back out of it what this device has ever managed. Done here, once
        // for all rows, rather than per row while drawing: it is a fold over the whole
        // log, and the lists redraw every second.
        let best = TransferLog.shared.bestPeaks()
        for index in networkRows.indices {
            networkRows[index].allTimePeak = max(
                networkRows[index].peak,
                best[TransferLog.recordKey(device: networkRows[index].title,
                                           volumes: networkRows[index].volumes)] ?? 0)
        }
        for index in usbRows.indices {
            usbRows[index].allTimePeak = max(
                usbRows[index].peak,
                best[TransferLog.recordKey(device: usbRows[index].title,
                                           volumes: usbRows[index].volumes)] ?? 0)
        }
        for index in recordableNetworkRows.indices {
            recordableNetworkRows[index].allTimePeak =
                max(recordableNetworkRows[index].peak,
                    best[TransferLog.recordKey(device: recordableNetworkRows[index].title,
                                               volumes: recordableNetworkRows[index].volumes)] ?? 0)
        }
        for index in recordableUSBRows.indices {
            recordableUSBRows[index].allTimePeak =
                max(recordableUSBRows[index].peak,
                    best[TransferLog.recordKey(device: recordableUSBRows[index].title,
                                               volumes: recordableUSBRows[index].volumes)] ?? 0)
        }

        allDown = totalDown + usbTotalDown
        allUp = totalUp + usbTotalUp
        Monitor.appendCapped(&allDownHist, allDown)
        Monitor.appendCapped(&allUpHist, allUp)
        onUpdate?()
    }

    /// Cumulative counters only ever move forward; a decrease means the counter was reset
    /// (interface reconfigured, device replugged), so report no traffic rather than a huge spike.
    private static func delta(_ current: UInt64, _ previous: UInt64) -> Double {
        current >= previous ? Double(current - previous) : 0
    }

    private func combinedActive(_ down: Double, _ up: Double) -> Bool {
        down + up > 256 * 1024
    }

    /// Processes moving meaningful disk traffic that also hold a file open under
    /// `root`. The rate comes from the kernel's per-process counters; the open
    /// descriptor is what ties the process to this particular volume.
    private func actors(under roots: [String], elapsed: Double) -> [Actor] {
        var found: [Actor] = []
        for (pid, now) in procs {
            guard let before = prevProcs[pid] else { continue }
            let moved = Monitor.delta(now.read, before.read) + Monitor.delta(now.written, before.written)
            let rate = moved / elapsed
            guard rate > 512 * 1024 else { continue }
            // Checking descriptors is the expensive part, so only ask about
            // processes that are actually busy.
            if roots.contains(where: { ProcessSampler.hasOpenFile(pid: pid, under: $0) }) {
                found.append(Actor(name: now.name, pid: pid, bytesPerSec: rate,
                                   owner: Monitor.processOwners[now.name] ?? ""))
            }
        }
        found.sort { $0.bytesPerSec > $1.bytesPerSec }
        return Array(found.prefix(3))
    }

    /// Remembers the highest rate seen for one row and returns it.
    private func notePeak(_ key: String, _ value: Double) -> Double {
        let best = max(peaks[key] ?? 0, value)
        peaks[key] = best
        return best
    }

    private func pushHistory(_ key: String, down: Double, up: Double) -> (down: [Double], up: [Double]) {
        var d = histDown[key] ?? Array(repeating: 0, count: Monitor.historyLength)
        var u = histUp[key] ?? Array(repeating: 0, count: Monitor.historyLength)
        d.append(down)
        u.append(up)
        if d.count > Monitor.historyLength { d.removeFirst(d.count - Monitor.historyLength) }
        if u.count > Monitor.historyLength { u.removeFirst(u.count - Monitor.historyLength) }
        histDown[key] = d
        histUp[key] = u
        return (d, u)
    }

    private static func appendCapped(_ series: inout [Double], _ value: Double) {
        series.append(value)
        if series.count > historyLength { series.removeFirst(series.count - historyLength) }
    }

    private func updateNetwork(_ net: [String: NetCounters], elapsed: Double) {
        var rows: [Row] = []
        var sumDown: Double = 0
        var sumUp: Double = 0

        for (name, counters) in net {
            if NetSampler.isNoise(name) && !showInactive { continue }

            var down: Double = 0
            var up: Double = 0
            if let prev = prevNet[name] {
                down = Monitor.delta(counters.ibytes, prev.ibytes) / elapsed
                up = Monitor.delta(counters.obytes, prev.obytes) / elapsed
            }

            // Only hardware interfaces count toward the headline total. A VPN tunnel (utun*),
            // AWDL, or a bridge carries traffic that is *also* counted on the physical interface
            // it rides over, so summing everything would report roughly double the real rate.
            // SystemConfiguration only names real hardware, which makes it a reliable test;
            // bridges are named but are software over member ports, so exclude them too.
            let isPhysical = friendly[name] != nil && !name.hasPrefix("bridge")
            if isPhysical {
                sumDown += down
                sumUp += up
            }

            let hist = pushHistory("net:" + name, down: down, up: up)

            var row = Row(
                id: "net:" + name,
                title: name,
                subtitle: friendly[name] ?? NetSampler.kind(for: name),
                badge: ""
            )
            row.down = down
            row.up = up
            row.totalDown = counters.ibytes
            row.totalUp = counters.obytes
            row.downHist = hist.down
            row.upHist = hist.up
            row.active = down > 0 || up > 0
            row.isPhysical = isPhysical
            if let first = linkRateSeen[name], first != counters.baudrate {
                linkRateVaries.insert(name)
            } else if linkRateSeen[name] == nil {
                linkRateSeen[name] = counters.baudrate
            }
            row.linkBits = counters.baudrate
            row.peak = notePeak("net:" + name, down + up)
            row.peakDirectional = notePeak("netdir:" + name, max(down, up))
            // Trust it only if it has held steady and nothing has exceeded it.
            // Wi-Fi is excluded outright rather than waiting to catch it changing:
            // the number is a PHY rate by definition, not a link capacity.
            row.linkTrusted = !wireless.contains(name)
                && !linkRateVaries.contains(name)
                && Reference.linkRateIsCredible(observedBytesPerSec: max(max(down, up), row.peakDirectional),
                                                linkBits: counters.baudrate)
            // Only present a link rate that is actually a capacity. A constant one
            // (Thunderbolt, wired Ethernet) is real and stays; a fluctuating or
            // already-exceeded one is dropped rather than shown as fact.
            row.badge = ""   // interfaces have no standard name to show
            row.section = "Network"
            row.compareFamilies = [.network]
            row.vendor = friendly[name] ?? ""
            row.wireless = wireless.contains(name)
            row.icon = IconKind.forInterface(name: name, wireless: row.wireless)
            if counters.ierrors > 0 || counters.oerrors > 0 {
                row.note = "\(counters.ierrors + counters.oerrors) errors"
            }
            rows.append(row)
        }

        rows = Monitor.ordered(rows, by: networkSort, manual: networkOrder,
                               pinned: networkPinned)

        // Hardware only by default, whether busy or idle, so Wi-Fi stays visible when
        // nothing is moving. Tunnels and bridges are left out because their traffic is
        // already counted on the interface underneath them - a VPN carrying a download
        // put the same bytes on screen twice, once as utun and once as en0. "Show all"
        // brings them back, along with loopback and the long tail of virtual
        // interfaces that have merely seen a byte since boot.
        // Recorded before hiding is applied: hiding is about attention, not about
        // measurement, and a row you have put out of sight is still moving bytes you
        // will want to find in the log afterwards.
        recordableNetworkRows = showInactive ? rows : rows.filter { $0.isPhysical }
        networkRows = Hidden.visible(recordableNetworkRows) { $0.id }
        if networkSort == .activeFirst, networkPinned.isEmpty, !networkRows.isEmpty {
            networkPinned = networkRows.map { $0.id }
        }
        totalDown = sumDown
        totalUp = sumUp
        Monitor.appendCapped(&totalDownHist, sumDown)
        Monitor.appendCapped(&totalUpHist, sumUp)
        prevNet = net
    }

    private func updateUSB(_ net: [String: NetCounters], previousNet: [String: NetCounters], elapsed: Double) {
        // Internal drives alongside the plugged-in ones: a card import is a read from
        // one and a write to the other, and showing only half of it explains nothing.
        let devices = USBSampler.sample() + InternalStorage.sample()
        var rows: [Row] = []
        var sumDown: Double = 0
        var sumUp: Double = 0
        var current: [String: USBDeviceInfo] = [:]

        for device in devices {
            current[device.id] = device
            let prev = prevUSB[device.id]

            var down: Double = 0
            var up: Double = 0
            var measurable = false

            // Storage: read = device -> host (down), write = host -> device (up).
            if device.hasStorageCounters {
                measurable = true
                if let prev = prev, prev.hasStorageCounters {
                    down += Monitor.delta(device.diskRead, prev.diskRead) / elapsed
                    up += Monitor.delta(device.diskWritten, prev.diskWritten) / elapsed
                }
            }

            // USB network adapters: attribute the BSD interface's counters to the device.
            var totalDownBytes = device.diskRead
            var totalUpBytes = device.diskWritten
            for iface in device.interfaces {
                guard let counters = net[iface] else { continue }
                measurable = true
                totalDownBytes += counters.ibytes
                totalUpBytes += counters.obytes
                if let prev = previousNet[iface] {
                    down += Monitor.delta(counters.ibytes, prev.ibytes) / elapsed
                    up += Monitor.delta(counters.obytes, prev.obytes) / elapsed
                }
            }

            sumDown += down
            sumUp += up
            let hist = pushHistory("usb:" + device.id, down: down, up: up)

            var subtitleParts: [String] = []
            let deviceID = (device.vendorID != 0 || device.productID != 0)
                ? String(format: "%04x:%04x", device.vendorID, device.productID) : ""
            if !device.vendor.isEmpty { subtitleParts.append(device.vendor) }
            if !deviceID.isEmpty { subtitleParts.append(deviceID) }
            if !device.disks.isEmpty { subtitleParts.append(device.disks.joined(separator: ", ")) }
            if !device.interfaces.isEmpty { subtitleParts.append(device.interfaces.joined(separator: ", ")) }

            var row = Row(
                id: "usb:" + device.id,
                title: device.name,
                subtitle: subtitleParts.joined(separator: " · "),
                // The neutral name on the badge; Apple's name goes in the footer, so
                // both are visible without the badge overflowing a half-width pane.
                // Name only. The speed is appended by the view, which knows whether
                // bytes or bits is selected.
                // Internal drives have no negotiated link to report, and labelling one
                // "Unknown speed" invited a comparison against USB 1.1.
                badge: Reference.standard(forLinkBits: device.linkSpeedBits)?.name
                    ?? (device.linkSpeedBits > 0 ? device.speedLabel : "")
            )
            row.down = down
            row.up = up
            row.totalDown = totalDownBytes
            row.totalUp = totalUpBytes
            row.downHist = hist.down
            row.upHist = hist.up
            // "Active" means data is moving. It used to mean "has counters", which
            // left every drive permanently lit and broke the default sort.
            row.active = down > 0 || up > 0
            row.isPhysical = true
            row.linkBits = device.linkSpeedBits
            row.peak = notePeak("usb:" + device.id, down + up)
            row.peakDirectional = notePeak("usbdir:" + device.id, max(down, up))
            row.section = device.id.hasPrefix("internal:") ? "Internal" : "USB"
            row.vendor = device.vendor
            row.deviceID = deviceID
            row.removable = device.removableMedia
            row.mediumClass = Reference.mediumClass(bytes: device.mediumBytes,
                                                    deviceName: device.name,
                                                    removable: device.removableMedia)
            row.icon = IconKind.forUSB(hasDisks: !device.disks.isEmpty,
                                       removableMedia: device.removableMedia,
                                       hasInterfaces: !device.interfaces.isEmpty)
            // Storage devices are best understood against other storage; a USB
            // network adapter against other networks.
            row.compareFamilies = device.hasStorageCounters ? [.storage]
                                : (!device.interfaces.isEmpty ? [.network] : [.usb])
            // A card in a reader belongs against cards; a drive - portable or internal -
            // against drives. Judged by whether the medium is removable, which the
            // storage stack reports, rather than by the product name.
            if device.hasStorageCounters {
                row.compareRoles = device.removableMedia ? ["card"] : ["disk"]
                if let solid = device.solidState {
                    row.mediumKinds = solid ? ["ssd"] : ["spinning"]
                }
                row.internalMedium = device.id.hasPrefix("internal:")
            }
            if let std = Reference.standard(forLinkBits: device.linkSpeedBits) {
                if let apple = std.appleName, apple != std.name { row.appleName = apple }
                if let alias = std.alias, alias != std.name { row.alsoKnown = alias }
                if let marketing = std.marketing { row.marketingName = marketing }
            }
            // How much this device has actually been asked to move, so a verdict on
            // the medium is only offered once there is something to base it on.
            row.hint = Reference.advice(peakBytesPerSec: row.peak,
                                        linkBits: device.linkSpeedBits,
                                        isStorage: !device.disks.isEmpty,
                                        removableMedia: device.removableMedia,
                                        bytesMoved: Double(row.totalDown + row.totalUp))
            // Where this device is mounted, so its traffic can be tied to the
            // processes holding files open there. All partitions, since a copy may
            // be touching any one of them.
            row.allMounts = device.disks.compactMap { mounts[$0] }
            row.mountRoots = row.allMounts.filter { ProcessSampler.isFinderVolume($0) }
            // Volume names as shown in Finder, not full paths.
            row.volumes = row.mountRoots.map {
                (ProcessSampler.finderPath($0) as NSString).lastPathComponent
            }
            if let combined = ProcessSampler.combinedSpace(of: row.allMounts, in: space) {
                row.capacityBytes = combined.capacity
                row.usedBytes = combined.used
            }
            // Two lookups, because they answer different questions. What a device is
            // formatted as holds wherever it is mounted; what Spotlight has been told
            // about it is only reported for the removable volumes under /Volumes.
            // One record per mounted volume. The Finder volumes when there are any,
            // so the table matches the names the user knows; every mount otherwise,
            // which is what lets the boot drive say anything at all about itself -
            // its volumes are not under /Volumes.
            let detailed = row.mountRoots.isEmpty ? row.allMounts : row.mountRoots
            row.volumeDetails = detailed.compactMap { mount in
                guard let t = traits[mount] else { return nil }
                var d = Row.VolumeDetail()
                d.mount = mount
                // The mount point's own last component is the name almost always.
                // The startup disk is the exception: it is mounted at "/".
                let short = (ProcessSampler.finderPath(mount) as NSString).lastPathComponent
                d.name = (short.isEmpty || short == "/")
                    ? (t.name.isEmpty ? mount : t.name) : short
                d.device = t.device
                d.fsType = t.fsType
                d.blockSize = t.blockSize
                d.readOnly = t.readOnly
                d.created = t.created
                d.uuid = t.uuid
                return d
            }
            if let first = row.allMounts.first, let t = traits[first] {
                row.fsType = t.fsType
                row.journalWrites = t.journalWrites
                row.blockSize = t.blockSize
                row.readOnly = t.readOnly
                row.deviceNode = t.device
                row.created = t.created
            }
            if let first = row.mountRoots.first, let t = traits[first] {
                row.spotlight = t.spotlight
                row.indexingDisabled = t.neverIndex
                // From the traits map rather than a fresh lookup: that map is rebuilt
                // every fifth sample at most, and this ran on every one of them.
                row.volumeID = t.uuid
            }
            if combinedActive(down, up), !row.mountRoots.isEmpty {
                row.actors = actors(under: row.mountRoots, elapsed: elapsed)
            }
            // Be explicit about the limitation rather than drawing a flat line that looks like idle.
            row.note = measurable ? "" : "no byte counters for this device class"
            rows.append(row)
        }

        rows = Monitor.ordered(rows, by: storageSort, manual: storageOrder,
                               pinned: storagePinned)

        // What is recorded is unaffected: a hub with counters is still measured, and
        // hiding it from the list does not stop it being logged.
        recordableUSBRows = rows
        let carrying = showInactive ? rows : rows.filter { $0.carriesMedium }
        usbRows = Hidden.visible(carrying) { $0.id }
        if storageSort == .activeFirst, storagePinned.isEmpty, !usbRows.isEmpty {
            storagePinned = usbRows.map { $0.id }
        }
        usbTotalDown = sumDown
        usbTotalUp = sumUp
        Monitor.appendCapped(&usbDownHist, sumDown)
        Monitor.appendCapped(&usbUpHist, sumUp)
        prevUSB = current
    }
}
