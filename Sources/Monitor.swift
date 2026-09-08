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
}

/// Samples the system on a timer and turns raw cumulative counters into rates.
final class Monitor {
    enum Mode {
        case network
        case usb
    }

    static let historyLength = 150

    var onUpdate: (() -> Void)?
    var interval: TimeInterval = 1.0 {
        didSet { restartTimer() }
    }
    var showInactive = false

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

    private var prevNet: [String: NetCounters] = [:]
    private var prevUSB: [String: USBDeviceInfo] = [:]
    private var lastSample: CFAbsoluteTime = 0
    private var peaks: [String: Double] = [:]
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
        updateNetwork(net, elapsed: elapsed)
        updateUSB(net, previousNet: previousNet, elapsed: elapsed)
        onUpdate?()
    }

    /// Cumulative counters only ever move forward; a decrease means the counter was reset
    /// (interface reconfigured, device replugged), so report no traffic rather than a huge spike.
    private static func delta(_ current: UInt64, _ previous: UInt64) -> Double {
        current >= previous ? Double(current - previous) : 0
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
            if counters.ierrors > 0 || counters.oerrors > 0 {
                row.note = "\(counters.ierrors + counters.oerrors) errors"
            }
            rows.append(row)
        }

        rows.sort { lhs, rhs in
            let l = lhs.down + lhs.up
            let r = rhs.down + rhs.up
            if l != r { return l > r }
            if lhs.active != rhs.active { return lhs.active }
            return lhs.title < rhs.title
        }

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
                badge: device.speedLabel + (device.linkSpeedBits > 0
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
            // Be explicit about the limitation rather than drawing a flat line that looks like idle.
            row.note = measurable ? "" : "no byte counters for this device class"
            rows.append(row)
        }

        rows.sort { lhs, rhs in
            let l = lhs.down + lhs.up
            let r = rhs.down + rhs.up
            if l != r { return l > r }
            if lhs.active != rhs.active { return lhs.active }
            return lhs.title.lowercased() < rhs.title.lowercased()
        }

        usbRows = rows
        usbTotalDown = sumDown
        usbTotalUp = sumUp
        Monitor.appendCapped(&usbDownHist, sumDown)
        Monitor.appendCapped(&usbUpHist, sumUp)
        prevUSB = current
    }
}
