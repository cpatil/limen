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

    /// Whether any Thunderbolt controller is present. Says nothing about which
    /// generation: IOKit publishes no version or link-speed property on
    /// IOThunderboltSwitch or IOThunderboltPort.
    static let hasThunderbolt: Bool = exists("IOThunderboltSwitch") || exists("IOThunderboltPort")

    /// True when this machine is Apple Silicon, which is the one case where the port
    /// generation can be asserted without a model table: every Apple Silicon Mac has
    /// shipped with Thunderbolt 3 / USB4 or better.
    private static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0, value == 1 {
            return true
        }
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// The best port standard this machine is *known* to offer, or nil when unknown.
    ///
    /// Presence of a Thunderbolt controller does not imply USB4. A 2015 15" MacBook
    /// Pro has Thunderbolt 2 at 20 Gbit/s and separate USB 3 ports at 5 Gbit/s, and
    /// telling its owner to buy a 40 Gbit/s cable would be advice their machine cannot
    /// use. Intel Macs span Thunderbolt 1 through 4 with no way to tell them apart
    /// from IOKit, so no claim is made there; Apple Silicon is uniform and safe.
    static var best: SpeedRef? {
        guard isAppleSilicon, hasThunderbolt else { return nil }
        return Reference.entry(named: "USB4 / Thunderbolt 3")
    }
}
