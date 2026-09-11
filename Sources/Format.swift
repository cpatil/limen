import Foundation

enum RateUnit {
    case bytes
    case bits
}

enum Fmt {
    static func scale(_ value: Double, units: [String], divisor: Double) -> String {
        var x = value.isFinite ? max(0, value) : 0
        var i = 0
        while x >= divisor && i < units.count - 1 {
            x /= divisor
            i += 1
        }
        let digits: String
        if i == 0 {
            digits = String(format: "%.0f", x)
        } else if x < 10 {
            digits = String(format: "%.2f", x)
        } else if x < 100 {
            digits = String(format: "%.1f", x)
        } else {
            digits = String(format: "%.0f", x)
        }
        return digits + " " + units[i]
    }

    /// Formats a rate given in **bytes per second** into the user's chosen unit.
    static func rate(_ bytesPerSec: Double, unit: RateUnit) -> String {
        switch unit {
        case .bytes:
            // Base 10, like Finder and like every advertised figure: a 5 Gbit/s link
            // is 625 MB/s, not the 596 you get from dividing by 1024 while still
            // calling it MB.
            return scale(bytesPerSec, units: ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"], divisor: 1000)
        case .bits:
            return scale(bytesPerSec * 8, units: ["bit/s", "Kbit/s", "Mbit/s", "Gbit/s", "Tbit/s"], divisor: 1000)
        }
    }

    static func bytes(_ value: Double) -> String {
        scale(value, units: ["B", "KB", "MB", "GB", "TB", "PB"], divisor: 1000)
    }

    /// The filesystem as people name it, not as statfs spells it.
    ///
    /// "msdos" becomes FAT rather than FAT32: the kernel reports one name for both
    /// FAT16 and FAT32, so the version would be a guess dressed as a reading.
    static func fsName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "": return ""
        case "apfs": return "APFS"
        case "hfs": return "Mac OS Extended"
        case "exfat": return "exFAT"
        case "msdos": return "FAT"
        case "ntfs": return "NTFS"
        case "smbfs": return "SMB share"
        case "nfs": return "NFS share"
        case "afpfs": return "AFP share"
        case "webdav": return "WebDAV"
        case "cd9660": return "ISO 9660"
        case "udf": return "UDF"
        default: return raw.uppercased()
        }
    }

    /// Link capability is conventionally quoted in bits regardless of the rate unit toggle.
    static func linkSpeed(bitsPerSec: UInt64) -> String {
        guard bitsPerSec > 0 else { return "" }
        return scale(Double(bitsPerSec), units: ["bit/s", "Kbit/s", "Mbit/s", "Gbit/s", "Tbit/s"], divisor: 1000)
    }

    /// A link speed in the chosen unit alone.
    static func speed(bitsPerSec: UInt64, unit: RateUnit) -> String {
        guard bitsPerSec > 0 else { return "" }
        switch unit {
        case .bits: return linkSpeed(bitsPerSec: bitsPerSec)
        case .bytes: return scale(Double(bitsPerSec) / 8,
                                  units: ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"], divisor: 1000)
        }
    }

    /// The same link speed in the other vocabulary, for showing alongside.
    static func alternateSpeed(bitsPerSec: UInt64, unit: RateUnit) -> String {
        speed(bitsPerSec: bitsPerSec, unit: unit == .bits ? .bytes : .bits)
    }

    /// A link speed in both vocabularies, the chosen unit first.
    ///
    /// Ports are advertised in bits and files are measured in bytes, and the factor
    /// of eight between them is exactly what makes a "5 Gbit/s" port confusing. So
    /// rather than picking a side and contradicting the unit switch, show both.
    static func dualSpeed(bitsPerSec: UInt64, unit: RateUnit) -> String {
        guard bitsPerSec > 0 else { return "" }
        let inBits = linkSpeed(bitsPerSec: bitsPerSec)
        let inBytes = scale(Double(bitsPerSec) / 8,
                            units: ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"], divisor: 1000)
        return unit == .bits ? "\(inBits) (\(inBytes))" : "\(inBytes) (\(inBits))"
    }
}
