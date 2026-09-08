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
            return scale(bytesPerSec, units: ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"], divisor: 1024)
        case .bits:
            return scale(bytesPerSec * 8, units: ["bit/s", "Kbit/s", "Mbit/s", "Gbit/s", "Tbit/s"], divisor: 1000)
        }
    }

    static func bytes(_ value: Double) -> String {
        scale(value, units: ["B", "KB", "MB", "GB", "TB", "PB"], divisor: 1024)
    }

    /// Link capability is conventionally quoted in bits regardless of the rate unit toggle.
    static func linkSpeed(bitsPerSec: UInt64) -> String {
        guard bitsPerSec > 0 else { return "" }
        return scale(Double(bitsPerSec), units: ["bit/s", "Kbit/s", "Mbit/s", "Gbit/s", "Tbit/s"], divisor: 1000)
    }
}
