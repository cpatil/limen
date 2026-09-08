import Darwin
import Foundation
import IOKit

/// What this Mac's own ports are capable of, as opposed to what a device negotiated.
///
/// The gap between the two is actionable in a way the device's own limit is not: a
/// drive connected at USB 2.0 speeds on a machine with Thunderbolt ports is usually a
/// cable or a port choice, and both are cheap to change.
enum HostPorts {
    private static let defaultPort: mach_port_t = 0

    private static func exists(_ className: String) -> Bool {
        guard let matching = IOServiceMatching(className) else { return false }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(defaultPort, matching, &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }
        let first = IOIteratorNext(iterator)
        defer { if first != 0 { IOObjectRelease(first) } }
        return first != 0
    }

    /// Thunderbolt implies USB4-class ports on every Mac that has shipped with it.
    ///
    /// IOKit exposes the controllers but not their generation - no link-speed or
    /// version property is published on IOThunderboltSwitch or IOThunderboltPort - so
    /// this reports the conservative floor rather than guessing at Thunderbolt 4 or 5.
    static let hasThunderbolt: Bool = exists("IOThunderboltSwitch") || exists("IOThunderboltPort")

    /// The best port standard this machine is known to offer, or nil when unknown.
    static var best: SpeedRef? {
        guard hasThunderbolt else { return nil }
        return Reference.entry(named: "USB4 / Thunderbolt 3")
    }
}
