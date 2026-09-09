import Darwin
import Foundation
import IOKit

/// Drives inside the machine, counted the same way as the ones plugged into it.
///
/// Without these, half of a card import is invisible: you watch the reader deliver
/// 90 MB/s and never see where it lands. The internal disk is also occasionally the
/// real constraint - nearly full, or thermally throttled - and that is impossible to
/// notice while only one end is measured.
enum InternalStorage {
    private static let defaultPort: mach_port_t = 0

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        guard let cf = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return cf.takeRetainedValue()
    }

    /// True when any ancestor is a USB device, i.e. this is external and already
    /// covered by the USB walk.
    private static func behindUSB(_ entry: io_registry_entry_t) -> Bool {
        var current = entry
        IOObjectRetain(current)
        var hops = 0
        while hops < 24 {
            hops += 1
            if IOObjectConformsTo(current, "IOUSBHostDevice") != 0
                || IOObjectConformsTo(current, "IOUSBDevice") != 0 {
                IOObjectRelease(current)
                return true
            }
            var parent: io_registry_entry_t = 0
            let rc = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard rc == KERN_SUCCESS, parent != 0 else { return false }
            current = parent
        }
        IOObjectRelease(current)
        return false
    }

    /// What the storage stack says about this device: its product name, whether the
    /// medium is solid state, and whether it is backed by a file rather than hardware.
    ///
    /// The two characteristics dictionaries live at different depths, so this collects
    /// whichever it meets on one walk up to the device rather than stopping at the
    /// first.
    private static func describe(_ entry: io_registry_entry_t) -> Description {
        var result = Description()
        var current = entry
        IOObjectRetain(current)
        var hops = 0
        while hops < 12 {
            hops += 1
            if !result.haveDevice,
               let chars = property(current, "Device Characteristics") as? [String: Any] {
                let product = (chars["Product Name"] as? String)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if !product.isEmpty { result.name = product }
                let medium = (chars["Medium Type"] as? String) ?? ""
                result.solidState = medium.localizedCaseInsensitiveContains("solid")
                result.haveDevice = true
            }
            if !result.haveProtocol,
               let proto = property(current, "Protocol Characteristics") as? [String: Any] {
                // A mounted disk image is a loopback onto a file on some real disk, so
                // its bytes are already counted on whichever drive actually holds it.
                // Showing it as a device of its own is double counting dressed up as
                // hardware. The storage stack labels these plainly.
                let interconnect = (proto["Physical Interconnect"] as? String) ?? ""
                let location = (proto["Physical Interconnect Location"] as? String) ?? ""
                result.virtual = interconnect.localizedCaseInsensitiveContains("virtual")
                    || location.localizedCaseInsensitiveContains("file")
                result.haveProtocol = true
            }
            if result.haveDevice && result.haveProtocol { break }
            var parent: io_registry_entry_t = 0
            let rc = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard rc == KERN_SUCCESS, parent != 0 else { return result }
            current = parent
        }
        IOObjectRelease(current)
        return result
    }

    private struct Description {
        var name = "Internal drive"
        var solidState = true
        var virtual = false
        var haveDevice = false
        var haveProtocol = false
    }

    private static func collectBSDNames(under entry: io_registry_entry_t, into info: inout USBDeviceInfo) {
        var iterator: io_iterator_t = 0
        let options = IOOptionBits(kIORegistryIterateRecursively)
        guard IORegistryEntryCreateIterator(entry, kIOServicePlane, options, &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        while true {
            let child = IOIteratorNext(iterator)
            if child == 0 { break }
            defer { IOObjectRelease(child) }
            if let bsd = property(child, "BSD Name") as? String, bsd.hasPrefix("disk"),
               !info.disks.contains(bsd) {
                info.disks.append(bsd)
            }
        }
    }

    static func sample() -> [USBDeviceInfo] {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(defaultPort, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var byName: [String: USBDeviceInfo] = [:]
        var order: [String] = []

        while true {
            let driver = IOIteratorNext(iterator)
            if driver == 0 { break }
            defer { IOObjectRelease(driver) }
            if behindUSB(driver) { continue }

            guard let stats = property(driver, "Statistics") as? [String: Any] else { continue }
            let described = describe(driver)
            if described.virtual { continue }

            var info = byName[described.name] ?? {
                order.append(described.name)
                var fresh = USBDeviceInfo()
                fresh.id = "internal:" + described.name
                fresh.name = described.name
                fresh.vendor = described.solidState ? "internal SSD" : "internal drive"
                // No negotiated link to report: the internal bus is not a cable the
                // user can change, so claiming a ceiling here would only mislead.
                fresh.speedCode = -1
                fresh.hasStorageCounters = true
                return fresh
            }()
            info.diskRead += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            info.diskWritten += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            // BSD names let the same mount lookup and process attribution work for
            // internal drives as for external ones.
            collectBSDNames(under: driver, into: &info)
            byName[described.name] = info
        }
        return order.compactMap { byName[$0] }
    }
}
