import Foundation

/// The speed reference table, kept as data rather than code.
///
/// New transports appear faster than an app gets rebuilt, so this loads from a
/// JSON catalogue that can be refreshed independently of the binary: a bundled
/// copy ships as the floor, a cached download overrides it, and the remote URL is
/// just a file in the repository. Nothing here needs a new release to learn about
/// USB4 v2 or 800G Ethernet.
struct SpeedCatalogue: Codable {
    var version: Int
    var updated: String
    var entries: [Entry]
    /// Helper process -> the application it works on behalf of. macOS parents every
    /// GUI helper to launchd, so the process tree cannot answer "who asked for this
    /// copy". A curated map can, and lives here so it updates with the catalogue.
    var processOwners: [String: String]?

    struct Entry: Codable {
        var name: String            // the neutral, current name
        var appleName: String?      // what Apple calls it, when that differs
        var alias: String?          // a previous or competing name for the same thing
        var line: Double            // advertised signalling rate, bits/sec
        var payload: Double         // realistically sustained, bits/sec
        var family: String          // usb | network | storage
        // What kind of thing this is, so advice can distinguish "a faster port" from
        // "a faster card": bus | card | disk.
        var role: String?
        // The standard that supersedes this one. This is what turns the catalogue
        // from a lookup table into an upgrade graph: with it, recommending a newer
        // protocol is a lookup and a division rather than a sentence written by hand.
        var upgrade: String?
        // Anything the upgrade also requires, e.g. a UHS-II card needs a UHS-II reader.
        var upgradeNote: String?
        /// The sensible thing to buy today for this kind of medium. Anything slower is
        /// legacy, and stepping one rung from legacy is poor advice.
        var mainstream: Bool?
        // What the medium physically is: ssd | spinning | flash. A drive whose type
        // the system already reports should not have it guessed from throughput - an
        // SSD is still an SSD while it is idle.
        var kind: String?
        // Where this medium physically lives: "external" for things that only ever
        // hang off a cable. Absent means it can be either, so it is a fair yardstick
        // for a drive inside the machine as well as one on the desk. Without this an
        // internal SSD was being measured against a USB flash drive.
        var mount: String?
    }
}

enum Catalogue {
    /// Where a catalogue update is fetched from, and only ever when the user asks.
    /// Nothing in this app contacts the network on its own.
    static let remoteURL = URL(string:
        "https://raw.githubusercontent.com/cpatil/limen/main/Resources/speeds.json")!

    private static let lastCheckKey = "CatalogueLastCheck"
    static let reminderInterval: TimeInterval = 30 * 24 * 3600

    static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Limen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("speeds.json")
    }

    /// Writes the built-in catalogue to disk when none is there yet.
    ///
    /// The shipped copy is the seed, so a missing file is filled locally rather than
    /// by reaching out. That is what keeps "fetch only when absent" from ever meaning
    /// a silent download: the file is never absent after first launch, and the first
    /// launch fills it from the binary.
    static func seedIfMissing() {
        // Also replaces a cache the shipped copy has overtaken, so the file on disk
        // never lags the binary.
        if let data = try? Data(contentsOf: cacheURL),
           let parsed = try? JSONDecoder().decode(SpeedCatalogue.self, from: data),
           parsed.version >= builtIn.version {
            return
        }
        try? builtInJSON.data(using: .utf8)?.write(to: cacheURL, options: .atomic)
    }

    /// The newer of the cached and built-in catalogues.
    ///
    /// Version matters, not just presence: after an app update the shipped catalogue
    /// is usually ahead of whatever was cached, and an old cache lacking newly added
    /// fields would silently disable the features that read them. A corrupt or
    /// hostile cache can only fall back, never crash.
    static func load() -> SpeedCatalogue {
        if let data = try? Data(contentsOf: cacheURL),
           let parsed = try? JSONDecoder().decode(SpeedCatalogue.self, from: data),
           !parsed.entries.isEmpty,
           parsed.version >= builtIn.version {
            return parsed
        }
        return builtIn
    }

    /// True when a downloaded catalogue is in use rather than the one in the binary.
    static var usingDownloaded: Bool {
        guard let data = try? Data(contentsOf: cacheURL),
              let parsed = try? JSONDecoder().decode(SpeedCatalogue.self, from: data)
        else { return false }
        return parsed.version > builtIn.version
    }

    /// Throws away a downloaded catalogue and goes back to the one that shipped.
    /// An update is a change to how every comparison reads, so it needs a way back.
    static func revertToBuiltIn() {
        try? FileManager.default.removeItem(at: cacheURL)
        seedIfMissing()
    }

    static var lastChecked: Date? {
        UserDefaults.standard.object(forKey: lastCheckKey) as? Date
    }

    /// True when it has been a month since the user last checked, so they can be
    /// offered the choice. The offer is all this does - it never checks by itself.
    static var updateReminderDue: Bool {
        guard let last = lastChecked else { return false }
        return Date().timeIntervalSince(last) > reminderInterval
    }

    static func noteChecked() {
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
    }

    /// Downloads a newer catalogue. Only ever called from an explicit user action.
    static func checkForUpdate(completion: @escaping (Int?, String?) -> Void) {
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, _, error in
            noteChecked()
            DispatchQueue.main.async {
                if let error = error {
                    completion(nil, error.localizedDescription); return
                }
                guard let data = data,
                      let parsed = try? JSONDecoder().decode(SpeedCatalogue.self, from: data),
                      !parsed.entries.isEmpty else {
                    completion(nil, "the downloaded catalogue could not be read"); return
                }
                guard parsed.version > load().version else {
                    completion(0, nil); return
                }
                try? data.write(to: cacheURL, options: .atomic)
                completion(parsed.version, nil)
            }
        }.resume()
    }

    static let builtIn: SpeedCatalogue = {
        guard let data = builtInJSON.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(SpeedCatalogue.self, from: data) else {
            return SpeedCatalogue(version: 0, updated: "", entries: [])
        }
        return parsed
    }()

    /// The shipped floor. Payload figures are what healthy hardware actually
    /// sustains, not the advertised rate: 8b/10b coding alone costs USB 3.0 a fifth
    /// of its headline number before any protocol framing.
    static let builtInJSON = """
    {
      "version": 8,
      "updated": "2026-09-08",
      "entries": [
        {
          "name": "USB 1.1",
          "line": 12000000.0,
          "payload": 9600000.0,
          "family": "usb",
          "role": "bus",
          "upgrade": "USB 2.0"
        },
        {
          "name": "USB 2.0",
          "line": 480000000.0,
          "payload": 320000000.0,
          "family": "usb",
          "role": "bus",
          "upgrade": "USB 3.2 Gen 1",
          "appleName": "USB 2.0 high speed"
        },
        {
          "name": "USB 3.2 Gen 1",
          "line": 5000000000.0,
          "payload": 3600000000.0,
          "family": "usb",
          "role": "bus",
          "upgrade": "USB 3.2 Gen 2",
          "appleName": "USB 3.0 SuperSpeed",
          "alias": "USB 5Gbps · USB 3.0 / USB 3.1 Gen 1"
        },
        {
          "name": "USB 3.2 Gen 2",
          "line": 10000000000.0,
          "payload": 8000000000.0,
          "family": "usb",
          "role": "bus",
          "upgrade": "USB 3.2 Gen 2x2",
          "appleName": "USB 3.1 SuperSpeed+",
          "alias": "USB 10Gbps · USB 3.1 Gen 2"
        },
        {
          "name": "USB 3.2 Gen 2x2",
          "line": 20000000000.0,
          "payload": 16000000000.0,
          "family": "usb",
          "role": "bus",
          "upgrade": "USB4 / Thunderbolt 3"
        },
        {
          "name": "USB4 / Thunderbolt 3",
          "line": 40000000000.0,
          "payload": 22000000000.0,
          "family": "usb",
          "role": "bus",
          "upgrade": "USB4 v2 / Thunderbolt 5",
          "appleName": "Thunderbolt 3",
          "alias": "USB4 40Gbps",
          "upgradeNote": "and both the cable and the device must support USB4 or Thunderbolt"
        },
        {
          "name": "USB4 v2 / Thunderbolt 5",
          "line": 80000000000.0,
          "payload": 50000000000.0,
          "family": "usb",
          "role": "bus",
          "appleName": "Thunderbolt 5"
        },
        {
          "name": "10 Mbit Ethernet",
          "line": 10000000.0,
          "payload": 9400000.0,
          "family": "network",
          "role": "bus",
          "upgrade": "100 Mbit Ethernet"
        },
        {
          "name": "100 Mbit Ethernet",
          "line": 100000000.0,
          "payload": 94000000.0,
          "family": "network",
          "role": "bus",
          "upgrade": "Gigabit Ethernet"
        },
        {
          "name": "Wi-Fi 4",
          "line": 300000000.0,
          "payload": 120000000.0,
          "family": "network",
          "role": "bus",
          "upgrade": "Wi-Fi 5",
          "appleName": "802.11n"
        },
        {
          "name": "Wi-Fi 5",
          "line": 866000000.0,
          "payload": 400000000.0,
          "family": "network",
          "role": "bus",
          "upgrade": "Wi-Fi 6",
          "appleName": "802.11ac"
        },
        {
          "name": "Gigabit Ethernet",
          "line": 1000000000.0,
          "payload": 940000000.0,
          "family": "network",
          "role": "bus",
          "upgrade": "2.5G Ethernet"
        },
        {
          "name": "Wi-Fi 6",
          "line": 1200000000.0,
          "payload": 700000000.0,
          "family": "network",
          "role": "bus",
          "upgrade": "Wi-Fi 6E",
          "appleName": "802.11ax"
        },
        {
          "name": "Wi-Fi 6E",
          "line": 2400000000.0,
          "payload": 1400000000.0,
          "family": "network",
          "role": "bus",
          "upgrade": "Wi-Fi 7"
        },
        {
          "name": "2.5G Ethernet",
          "line": 2500000000.0,
          "payload": 2350000000.0,
          "family": "network",
          "role": "bus",
          "upgrade": "5G Ethernet"
        },
        {
          "name": "5G Ethernet",
          "line": 5000000000.0,
          "payload": 4700000000.0,
          "family": "network",
          "role": "bus",
          "upgrade": "10G Ethernet"
        },
        {
          "name": "Wi-Fi 7",
          "line": 5800000000.0,
          "payload": 2900000000.0,
          "family": "network",
          "role": "bus",
          "appleName": "802.11be"
        },
        {
          "name": "10G Ethernet",
          "line": 10000000000.0,
          "payload": 9400000000.0,
          "family": "network",
          "role": "bus",
          "upgrade": "25G Ethernet"
        },
        {
          "name": "25G Ethernet",
          "line": 25000000000.0,
          "payload": 23500000000.0,
          "family": "network",
          "role": "bus"
        },
        {
          "name": "SD card (default speed)",
          "line": 100000000.0,
          "payload": 96000000.0,
          "family": "storage",
          "role": "card",
          "upgrade": "SD card (high speed)"
        },
        {
          "name": "SD card (high speed)",
          "line": 200000000.0,
          "payload": 192000000.0,
          "family": "storage",
          "role": "card",
          "upgrade": "SD card (UHS-I SDR50)"
        },
        {
          "name": "SD card (UHS-I SDR50)",
          "line": 400000000.0,
          "payload": 368000000.0,
          "family": "storage",
          "role": "card",
          "upgrade": "SD card (UHS-I SDR104)"
        },
        {
          "name": "SD card (UHS-I SDR104)",
          "line": 832000000.0,
          "payload": 720000000.0,
          "family": "storage",
          "role": "card",
          "upgrade": "SD card (UHS-II)",
          "upgradeNote": "which also needs a UHS-II reader",
          "mainstream": true
        },
        {
          "name": "SD card (UHS-II)",
          "line": 2500000000.0,
          "payload": 2200000000.0,
          "family": "storage",
          "role": "card",
          "upgrade": "SD card (UHS-III)",
          "upgradeNote": "which also needs a UHS-III reader"
        },
        {
          "name": "SD card (UHS-III)",
          "line": 5000000000.0,
          "payload": 4400000000.0,
          "family": "storage",
          "role": "card",
          "upgrade": "SD Express"
        },
        {
          "name": "SD Express",
          "line": 7900000000.0,
          "payload": 6400000000.0,
          "family": "storage",
          "role": "card",
          "upgrade": "SD Express (PCIe 4.0 x2)",
          "alias": "microSD Express",
          "upgradeNote": "which also needs an SD Express reader"
        },
        {
          "name": "SD Express (PCIe 4.0 x2)",
          "line": 31600000000.0,
          "payload": 25000000000.0,
          "family": "storage",
          "role": "card"
        },
        {
          "name": "CompactFlash (UDMA 7)",
          "line": 1330000000.0,
          "payload": 1200000000.0,
          "family": "storage",
          "role": "card",
          "upgrade": "CFast 2.0"
        },
        {
          "name": "CFast 2.0",
          "line": 6000000000.0,
          "payload": 4400000000.0,
          "family": "storage",
          "role": "card",
          "upgrade": "CFexpress Type A"
        },
        {
          "name": "CFexpress Type A",
          "line": 8000000000.0,
          "payload": 6800000000.0,
          "family": "storage",
          "role": "card",
          "upgrade": "CFexpress Type B"
        },
        {
          "name": "CFexpress Type B",
          "line": 16000000000.0,
          "payload": 13600000000.0,
          "family": "storage",
          "role": "card",
          "upgrade": "CFexpress Type C"
        },
        {
          "name": "CFexpress Type C",
          "line": 32000000000.0,
          "payload": 27000000000.0,
          "family": "storage",
          "role": "card"
        },
        {
          "name": "USB flash drive",
          "line": 400000000.0,
          "payload": 240000000.0,
          "family": "storage",
          "role": "disk",
          "upgrade": "portable hard disk",
          "mount": "external",
          "kind": "flash"
        },
        {
          "name": "portable hard disk",
          "line": 880000000.0,
          "payload": 880000000.0,
          "family": "storage",
          "role": "disk",
          "upgrade": "desktop hard disk",
          "mount": "external",
          "kind": "spinning"
        },
        {
          "name": "desktop hard disk",
          "line": 1440000000.0,
          "payload": 1440000000.0,
          "family": "storage",
          "role": "disk",
          "upgrade": "SATA SSD",
          "kind": "spinning"
        },
        {
          "name": "SATA SSD",
          "line": 6000000000.0,
          "payload": 4400000000.0,
          "family": "storage",
          "role": "disk",
          "upgrade": "NVMe SSD (Gen 3)",
          "alias": "SATA III",
          "mainstream": true,
          "kind": "ssd"
        },
        {
          "name": "NVMe SSD (Gen 3)",
          "line": 32000000000.0,
          "payload": 28000000000.0,
          "family": "storage",
          "role": "disk",
          "upgrade": "NVMe SSD (Gen 4)",
          "kind": "ssd"
        },
        {
          "name": "NVMe SSD (Gen 4)",
          "line": 64000000000.0,
          "payload": 56000000000.0,
          "family": "storage",
          "role": "disk",
          "upgrade": "NVMe SSD (Gen 5)",
          "kind": "ssd"
        },
        {
          "name": "NVMe SSD (Gen 5)",
          "line": 128000000000.0,
          "payload": 112000000000.0,
          "family": "storage",
          "role": "disk",
          "kind": "ssd"
        }
      ],
      "processOwners": {
        "DesktopServicesHelper": "Finder",
        "diskimages-helper": "Disk Utility",
        "backupd": "Time Machine",
        "mds_stores": "Spotlight",
        "mdworker": "Spotlight",
        "mdbulkimport": "Spotlight",
        "photoanalysisd": "Photos",
        "cloudphotod": "iCloud Photos",
        "bird": "iCloud Drive",
        "fileproviderd": "File Provider",
        "ThumbnailHelper": "Quick Look",
        "QuickLookUIService": "Quick Look",
        "quicklookd": "Quick Look",
        "AppleSpell": "Spell Checker",
        "Google Drive": "Google Drive",
        "Dropbox": "Dropbox"
      }
    }
    """
}
