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
    /// "Network" or "USB" - both are shown on one page now, grouped under headings.
    var section: String = ""
    /// Processes the kernel says are moving this data, most active first.
    var actors: [Actor] = []
    /// A quiet suggestion about this device, when the measurements support one.
    var hint: String = ""
    /// What Apple calls this link, when that differs from the neutral name.
    var appleName: String = ""
    /// Every place this device is mounted. A single enclosure often carries
    /// several partitions, and the traffic may be on any of them.
    var mountRoots: [String] = []
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
    var sortOrder: SortOrder = .activeFirst

    /// How the list is ordered. Rate-ranked ordering is available but not the
    /// default: it reshuffles the list every second, which is unreadable while
    /// anything is busy.
    enum SortOrder: Int {
        case activeFirst = 0
        case name = 1
        case rate = 2
        case total = 3

        var title: String {
            switch self {
            case .activeFirst: return "Active first"
            case .name: return "Name"
            case .rate: return "Current rate"
            case .total: return "Total moved"
            }
        }
    }

    /// Ordering is applied here so both sections agree, and so "active first" stays
    /// stable: it groups by whether a row is carrying traffic, then sorts by name
    /// within each group, rather than by a rate that changes every tick.
    static func ordered(_ rows: [Row], by order: SortOrder) -> [Row] {
        func byName(_ a: Row, _ b: Row) -> Bool {
            a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        switch order {
        case .activeFirst:
            return rows.sorted { a, b in
                if a.active != b.active { return a.active }
                if a.isPhysical != b.isPhysical { return a.isPhysical }
                return byName(a, b)
            }
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
        }
    }

    private(set) var networkRows: [Row] = []
    private(set) var usbRows: [Row] = []
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
    private var prevProcs: [Int32: ProcSample] = [:]
    private var procs: [Int32: ProcSample] = [:]
    private var mounts: [String: String] = [:]
    private var mountRefresh = 0
    private var histDown: [String: [Double]] = [:]
    private var histUp: [String: [Double]] = [:]
    private var friendly: [String: String] = [:]
    private var friendlyRefresh = 0
    private var timer: Timer?

    func start() {
        friendly = NetSampler.friendlyNames()
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
        if friendlyRefresh % 10 == 0 { friendly = NetSampler.friendlyNames() }

        // Snapshot the previous interface counters before updateNetwork replaces them:
        // updateUSB needs them to compute deltas for USB network adapters.
        let previousNet = prevNet
        let net = NetSampler.sample()
        // Mount points move rarely; processes change constantly.
        mountRefresh += 1
        if mounts.isEmpty || mountRefresh % 10 == 0 { mounts = ProcessSampler.mountPoints() }
        prevProcs = procs
        procs = ProcessSampler.sample()
        updateNetwork(net, elapsed: elapsed)
        updateUSB(net, previousNet: previousNet, elapsed: elapsed)
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
                badge: Fmt.linkSpeed(bitsPerSec: counters.baudrate)
            )
            row.down = down
            row.up = up
            row.totalDown = counters.ibytes
            row.totalUp = counters.obytes
            row.downHist = hist.down
            row.upHist = hist.up
            row.active = down > 0 || up > 0
            row.isPhysical = isPhysical
            row.linkBits = counters.baudrate
            row.peak = notePeak("net:" + name, down + up)
            row.section = "Network"
            if counters.ierrors > 0 || counters.oerrors > 0 {
                row.note = "\(counters.ierrors + counters.oerrors) errors"
            }
            rows.append(row)
        }

        rows = Monitor.ordered(rows, by: sortOrder)

        // Default view: hardware interfaces (so Wi-Fi stays visible when idle) plus anything
        // currently moving data (so an active VPN tunnel still appears). "Show all" reveals
        // the long tail of virtual interfaces that have merely seen a byte since boot.
        networkRows = showInactive ? rows : rows.filter { $0.isPhysical || $0.active }
        totalDown = sumDown
        totalUp = sumUp
        Monitor.appendCapped(&totalDownHist, sumDown)
        Monitor.appendCapped(&totalUpHist, sumUp)
        prevNet = net
    }

    private func updateUSB(_ net: [String: NetCounters], previousNet: [String: NetCounters], elapsed: Double) {
        let devices = USBSampler.sample()
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
            if !device.vendor.isEmpty { subtitleParts.append(device.vendor) }
            if device.vendorID != 0 || device.productID != 0 {
                subtitleParts.append(String(format: "%04x:%04x", device.vendorID, device.productID))
            }
            if !device.disks.isEmpty { subtitleParts.append(device.disks.joined(separator: ", ")) }
            if !device.interfaces.isEmpty { subtitleParts.append(device.interfaces.joined(separator: ", ")) }

            var row = Row(
                id: "usb:" + device.id,
                title: device.name,
                subtitle: subtitleParts.joined(separator: " · "),
                // The neutral name on the badge; Apple's name goes in the footer, so
                // both are visible without the badge overflowing a half-width pane.
                badge: (Reference.standard(forLinkBits: device.linkSpeedBits)?.name
                        ?? device.speedLabel)
                    + (device.linkSpeedBits > 0
                       ? " · " + Fmt.linkSpeed(bitsPerSec: device.linkSpeedBits)
                       : "")
            )
            row.down = down
            row.up = up
            row.totalDown = totalDownBytes
            row.totalUp = totalUpBytes
            row.downHist = hist.down
            row.upHist = hist.up
            row.active = measurable
            row.isPhysical = true
            row.linkBits = device.linkSpeedBits
            row.peak = notePeak("usb:" + device.id, down + up)
            row.section = "USB"
            if let std = Reference.standard(forLinkBits: device.linkSpeedBits),
               let apple = std.appleName, apple != std.name {
                row.appleName = apple
            }
            row.hint = Reference.advice(peakBytesPerSec: row.peak,
                                        linkBits: device.linkSpeedBits,
                                        isStorage: !device.disks.isEmpty,
                                        removableMedia: device.removableMedia)
            // Where this device is mounted, so its traffic can be tied to the
            // processes holding files open there. All partitions, since a copy may
            // be touching any one of them.
            row.mountRoots = device.disks.compactMap { mounts[$0] }
                .filter { $0.hasPrefix("/Volumes") }
            if combinedActive(down, up), !row.mountRoots.isEmpty {
                row.actors = actors(under: row.mountRoots, elapsed: elapsed)
            }
            // Be explicit about the limitation rather than drawing a flat line that looks like idle.
            row.note = measurable ? "" : "no byte counters for this device class"
            rows.append(row)
        }

        rows = Monitor.ordered(rows, by: sortOrder)

        usbRows = rows
        usbTotalDown = sumDown
        usbTotalUp = sumUp
        Monitor.appendCapped(&usbDownHist, sumDown)
        Monitor.appendCapped(&usbUpHist, sumUp)
        prevUSB = current
    }
}
