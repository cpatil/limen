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
        guard !FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        try? builtInJSON.data(using: .utf8)?.write(to: cacheURL, options: .atomic)
    }

    /// Cached catalogue if it parses, else the built-in one. A corrupt or hostile
    /// cache can only fall back, never crash.
    static func load() -> SpeedCatalogue {
        if let data = try? Data(contentsOf: cacheURL),
           let parsed = try? JSONDecoder().decode(SpeedCatalogue.self, from: data),
           !parsed.entries.isEmpty {
            return parsed
        }
        return builtIn
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
      "version": 1,
      "updated": "2026-09-08",
      "entries": [
        {"name":"USB 1.1","line":12000000,"payload":9600000,"family":"usb"},
        {"name":"USB 2.0","appleName":"USB 2.0 high speed","line":480000000,"payload":320000000,"family":"usb"},
        {"name":"USB 3.2 Gen 1","appleName":"USB 3.0 SuperSpeed","alias":"USB 3.0","line":5000000000,"payload":3600000000,"family":"usb"},
        {"name":"USB 3.2 Gen 2","appleName":"USB 3.1 SuperSpeed+","alias":"USB 3.1 Gen 2","line":10000000000,"payload":8000000000,"family":"usb"},
        {"name":"USB 3.2 Gen 2x2","line":20000000000,"payload":16000000000,"family":"usb"},
        {"name":"USB4 / Thunderbolt 3","appleName":"Thunderbolt 3","line":40000000000,"payload":22000000000,"family":"usb"},
        {"name":"USB4 v2 / Thunderbolt 5","appleName":"Thunderbolt 5","line":80000000000,"payload":50000000000,"family":"usb"},
        {"name":"10 Mbit Ethernet","line":10000000,"payload":9400000,"family":"network"},
        {"name":"100 Mbit Ethernet","line":100000000,"payload":94000000,"family":"network"},
        {"name":"Wi-Fi 5","appleName":"802.11ac","line":866000000,"payload":400000000,"family":"network"},
        {"name":"Gigabit Ethernet","line":1000000000,"payload":940000000,"family":"network"},
        {"name":"Wi-Fi 6","appleName":"802.11ax","line":1200000000,"payload":700000000,"family":"network"},
        {"name":"2.5G Ethernet","line":2500000000,"payload":2350000000,"family":"network"},
        {"name":"Wi-Fi 6E","line":2400000000,"payload":1400000000,"family":"network"},
        {"name":"10G Ethernet","line":10000000000,"payload":9400000000,"family":"network"},
        {"name":"SD card (UHS-I)","line":832000000,"payload":720000000,"family":"storage"},
        {"name":"hard disk","line":1200000000,"payload":1200000000,"family":"storage"},
        {"name":"SD card (UHS-II)","line":2500000000,"payload":2200000000,"family":"storage"},
        {"name":"SATA SSD","alias":"SATA III","line":6000000000,"payload":4400000000,"family":"storage"},
        {"name":"SD Express","line":7900000000,"payload":6000000000,"family":"storage"},
        {"name":"NVMe (Gen 3)","line":32000000000,"payload":28000000000,"family":"storage"},
        {"name":"NVMe (Gen 4)","line":64000000000,"payload":56000000000,"family":"storage"}
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
