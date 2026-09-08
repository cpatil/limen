import Foundation
import Darwin
import SystemConfiguration

struct NetCounters {
    var name = ""
    var type: UInt8 = 0
    var baudrate: UInt64 = 0
    var ibytes: UInt64 = 0
    var obytes: UInt64 = 0
    var ipackets: UInt64 = 0
    var opackets: UInt64 = 0
    var ierrors: UInt64 = 0
    var oerrors: UInt64 = 0
}

enum NetSampler {
    /// RTM_IFINFO2 from <net/route.h>. Declared locally so the build does not depend on
    /// whether a given SDK re-exports the constant to Swift.
    private static let rtmIfInfo2: UInt8 = 0x12

    /// Reads 64-bit per-interface byte counters via sysctl(NET_RT_IFLIST2).
    /// getifaddrs() would be simpler but only exposes 32-bit counters, which wrap every 4 GB.
    static func sample() -> [String: NetCounters] {
        var result: [String: NetCounters] = [:]
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var needed = 0

        guard sysctl(&mib, 6, nil, &needed, nil, 0) == 0, needed > 0 else { return result }
        var buf = [UInt8](repeating: 0, count: needed)
        guard sysctl(&mib, 6, &buf, &needed, nil, 0) == 0 else { return result }

        let total = needed
        buf.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= total {
                let hdr = base.advanced(by: off).assumingMemoryBound(to: if_msghdr.self).pointee
                let msglen = Int(hdr.ifm_msglen)
                if msglen <= 0 { break }

                if hdr.ifm_type == rtmIfInfo2, off + MemoryLayout<if_msghdr2>.size <= total {
                    let m = base.advanced(by: off).assumingMemoryBound(to: if_msghdr2.self).pointee
                    var nameBuf = [CChar](repeating: 0, count: Int(IFNAMSIZ) + 1)
                    if if_indextoname(UInt32(m.ifm_index), &nameBuf) != nil {
                        var c = NetCounters()
                        c.name = String(cString: nameBuf)
                        c.type = m.ifm_data.ifi_type
                        c.baudrate = m.ifm_data.ifi_baudrate
                        c.ibytes = m.ifm_data.ifi_ibytes
                        c.obytes = m.ifm_data.ifi_obytes
                        c.ipackets = m.ifm_data.ifi_ipackets
                        c.opackets = m.ifm_data.ifi_opackets
                        c.ierrors = m.ifm_data.ifi_ierrors
                        c.oerrors = m.ifm_data.ifi_oerrors
                        result[c.name] = c
                    }
                }
                off += msglen
            }
        }
        return result
    }

    /// BSD name -> localized display name ("en0" -> "Wi-Fi").
    static func friendlyNames() -> [String: String] {
        var map: [String: String] = [:]
        guard let list = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return map }
        for iface in list {
            guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { continue }
            if let display = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? {
                map[bsd] = display
            }
        }
        return map
    }

    /// BSD names of wireless interfaces.
    ///
    /// Wi-Fi reports `ifi_baudrate` as the rate the radio last negotiated for a
    /// frame, which changes with distance, interference and rate adaptation - the
    /// same interface has read 30.2 and 304 Mbit/s minutes apart. It is never a
    /// capacity, so it must not be presented as one however steady it looks in the
    /// moment.
    static func wirelessNames() -> Set<String> {
        var names: Set<String> = []
        guard let list = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return names }
        for iface in list {
            guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(iface) as String? else { continue }
            if type == (kSCNetworkInterfaceTypeIEEE80211 as String) { names.insert(bsd) }
        }
        return names
    }

    /// Best-effort classification for interfaces SystemConfiguration does not name.
    static func kind(for name: String) -> String {
        if name.hasPrefix("lo") { return "Loopback" }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { return "VPN / tunnel" }
        if name.hasPrefix("awdl") { return "AirDrop / AWDL" }
        if name.hasPrefix("llw") { return "Low-latency WLAN" }
        if name.hasPrefix("bridge") { return "Bridge" }
        if name.hasPrefix("gif") || name.hasPrefix("stf") { return "Tunnel" }
        if name.hasPrefix("ap") { return "Access point" }
        if name.hasPrefix("anpi") { return "Internal" }
        if name.hasPrefix("vmenet") || name.hasPrefix("vnic") { return "Virtual machine" }
        if name.hasPrefix("en") { return "Ethernet / Wi-Fi" }
        return "Interface"
    }

    /// Interfaces that are almost never interesting and only add noise to the list.
    static func isNoise(_ name: String) -> Bool {
        name.hasPrefix("gif") || name.hasPrefix("stf") || name.hasPrefix("anpi")
    }
}
