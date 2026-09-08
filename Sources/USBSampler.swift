import Foundation
import IOKit

struct USBDeviceInfo {
    var id = ""
    var name = ""
    var vendor = ""
    var speedCode = -1
    var vendorID = 0
    var productID = 0

    /// Attached storage volumes (disk3, disk4 ...) found beneath this USB device.
    var disks: [String] = []
    /// Attached network interfaces (en5 ...) found beneath this USB device.
    var interfaces: [String] = []

    /// Cumulative bytes moved by any IOBlockStorageDriver under this device.
    var diskRead: UInt64 = 0
    var diskWritten: UInt64 = 0

    /// True when this device exposes byte counters we can actually measure.
    var hasStorageCounters = false

    /// Negotiated link speed as advertised by the port, in bits/sec.
    var linkSpeedBits: UInt64 {
        switch speedCode {
        case 0: return 1_500_000
        case 1: return 12_000_000
        case 2: return 480_000_000
        case 3: return 5_000_000_000
        case 4: return 10_000_000_000
        case 5: return 20_000_000_000
        default: return 0
        }
    }

    var speedLabel: String {
        switch speedCode {
        case 0: return "USB 1.0 low speed"
        case 1: return "USB 1.1 full speed"
        case 2: return "USB 2.0 high speed"
        case 3: return "USB 3.0 SuperSpeed"
        case 4: return "USB 3.1 SuperSpeed+"
        case 5: return "USB 3.2 SuperSpeed+ x2"
        default: return "Unknown speed"
        }
    }
}

enum USBSampler {
    /// IOKit's default port. kIOMasterPortDefault was renamed kIOMainPortDefault in macOS 12,
    /// so pass MACH_PORT_NULL (0) directly, which IOKit documents as meaning "the default port"
    /// and which compiles identically on every OS version we target.
    private static let defaultPort: mach_port_t = 0

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        guard let cf = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return cf.takeRetainedValue()
    }

    private static func intValue(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        (property(entry, key) as? NSNumber)?.intValue
    }

    static func sample() -> [USBDeviceInfo] {
        var out: [USBDeviceInfo] = []
        var seen = Set<String>()

        // IOUSBHostDevice is the modern class (10.11+); IOUSBDevice is the legacy one still
        // used by some drivers. Enumerate both and de-duplicate on location ID.
        for className in ["IOUSBHostDevice", "IOUSBDevice"] {
            guard let matching = IOServiceMatching(className) else { continue }
            var iter: io_iterator_t = 0
            guard IOServiceGetMatchingServices(defaultPort, matching, &iter) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iter) }

            while true {
                let service = IOIteratorNext(iter)
                if service == 0 { break }
                defer { IOObjectRelease(service) }

                var info = read(service)
                if info.id.isEmpty || seen.contains(info.id) { continue }
                walkChildren(of: service, into: &info)
                seen.insert(info.id)
                out.append(info)
            }
        }

        out.sort { lhs, rhs in
            if lhs.name.lowercased() != rhs.name.lowercased() {
                return lhs.name.lowercased() < rhs.name.lowercased()
            }
            return lhs.id < rhs.id
        }
        return out
    }

    private static func read(_ service: io_registry_entry_t) -> USBDeviceInfo {
        var info = USBDeviceInfo()

        if let location = intValue(service, "locationID") {
            info.id = String(format: "0x%08x", location)
        } else {
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS {
                info.id = "id:\(entryID)"
            }
        }

        info.name = (property(service, "USB Product Name") as? String)
            ?? (property(service, "kUSBProductString") as? String)
            ?? registryName(service)
            ?? "USB device"

        info.vendor = (property(service, "USB Vendor Name") as? String)
            ?? (property(service, "kUSBVendorString") as? String)
            ?? ""

        info.speedCode = intValue(service, "Device Speed") ?? -1
        info.vendorID = intValue(service, "idVendor") ?? 0
        info.productID = intValue(service, "idProduct") ?? 0
        return info
    }

    private static func registryName(_ entry: io_registry_entry_t) -> String? {
        var buf = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buf) == KERN_SUCCESS else { return nil }
        let name = String(cString: buf)
        return name.isEmpty ? nil : name
    }

    private static func isUSBDevice(_ entry: io_registry_entry_t) -> Bool {
        IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 || IOObjectConformsTo(entry, "IOUSBDevice") != 0
    }

    /// Walks what a USB device publishes, looking for the two device classes macOS actually
    /// keeps byte counters for: block storage and network interfaces.
    ///
    /// Descends manually instead of using kIORegistryIterateRecursively so the walk can stop at
    /// nested USB devices. A hub is the registry parent of everything plugged into it, so a fully
    /// recursive walk would credit a downstream drive's counters to the hub as well and report
    /// the same traffic twice.
    private static func walkChildren(of service: io_registry_entry_t, into info: inout USBDeviceInfo) {
        var iter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }

        while true {
            let child = IOIteratorNext(iter)
            if child == 0 { break }
            defer { IOObjectRelease(child) }

            if isUSBDevice(child) { continue }

            collect(child, into: &info)
            walkChildren(of: child, into: &info)
        }
    }

    private static func collect(_ entry: io_registry_entry_t, into info: inout USBDeviceInfo) {
        if IOObjectConformsTo(entry, "IOBlockStorageDriver") != 0,
           let stats = property(entry, "Statistics") as? [String: Any] {
            info.diskRead += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            info.diskWritten += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            info.hasStorageCounters = true
        }

        if let bsd = property(entry, "BSD Name") as? String {
            if bsd.hasPrefix("disk") {
                if !info.disks.contains(bsd) { info.disks.append(bsd) }
            } else if !info.interfaces.contains(bsd) {
                info.interfaces.append(bsd)
            }
        }
    }
}
