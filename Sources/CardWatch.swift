import Cocoa

/// What Bottleneck does by itself when a memory card is inserted.
///
/// Both jobs are off until asked for. They are carried out by a small LaunchAgent
/// watching `/Volumes`, because the interesting moment is when a card arrives, which
/// is usually before Bottleneck is running - an app cannot notice an event it was not
/// there for.
///
/// The agent is installed the first time either switch is turned on and removed when
/// the last one is turned off, so a machine where the feature is unused carries
/// nothing. The switches themselves are ordinary preferences, so toggling one needs
/// no privileges and rewrites nothing on disk.
enum CardWatch {

    enum Job: String, CaseIterable {
        case neverIndex = "NeverIndexCards"
        case launchOnInsert = "LaunchOnCardInsert"

        var title: String {
            switch self {
            case .neverIndex: return "Stop Spotlight Indexing New Cards"
            case .launchOnInsert: return "Open Bottleneck When a Card Is Inserted"
            }
        }

        var explanation: String {
            switch self {
            case .neverIndex:
                return "Writes a .metadata_never_index marker to a card as it mounts, "
                    + "so Spotlight leaves it alone. Indexing a card you only import "
                    + "from costs wear and competes with the transfer.\n\n"
                    + "macOS withholds removable volumes until an app is granted them, "
                    + "so this may need Bottleneck to be allowed under Privacy & Security."
            case .launchOnInsert:
                return "Opens Bottleneck as a card mounts, so the transfer is recorded from "
                    + "the first byte rather than from whenever you think to look.\n\n"
                    + "If Bottleneck is already running it simply comes forward - it allows "
                    + "one instance at a time."
            }
        }
    }

    static func isOn(_ job: Job) -> Bool {
        UserDefaults.standard.bool(forKey: job.rawValue)
    }

    /// Turns one job on or off, and installs or removes the agent to match.
    static func set(_ job: Job, on: Bool) throws {
        UserDefaults.standard.set(on, forKey: job.rawValue)
        // The agent reads these with `defaults`, from another process, so they have to
        // have actually landed before it next runs.
        UserDefaults.standard.synchronize()
        rememberAppLocation()
        if Job.allCases.contains(where: isOn) {
            try install()
        } else {
            uninstall()
        }
    }

    /// Records where this copy of Bottleneck lives, so the agent can open the same one
    /// rather than guessing at /Applications.
    static func rememberAppLocation() {
        UserDefaults.standard.set(Bundle.main.bundlePath, forKey: "AppPath")
        UserDefaults.standard.synchronize()
    }

    // ---- the agent -------------------------------------------------------

    static let label = "local.bottleneck.card-watch"

    private static var supportDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bottleneck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var scriptURL: URL { supportDirectory.appendingPathComponent("card-watch.sh") }

    private static var plistURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// The script is written out from the copy inside the app, so it cannot drift from
    /// the version that shipped and does not depend on where the source tree was.
    private static func install() throws {
        guard let bundled = Bundle.main.url(forResource: "card-watch", withExtension: "sh"),
              let script = try? Data(contentsOf: bundled) else {
            throw Failure.missingScript
        }
        try script.write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: scriptURL.path)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [scriptURL.path],
            // Fires when a volume appears or disappears.
            "WatchPaths": ["/Volumes"],
            "RunAtLoad": false,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml, options: 0)
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)

        launchctl("unload")     // no-op when it was not loaded
        launchctl("load")
    }

    private static func uninstall() {
        launchctl("unload")
        try? FileManager.default.removeItem(at: plistURL)
    }

    private static func launchctl(_ verb: String) {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = [verb, plistURL.path]
        task.standardError = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    enum Failure: LocalizedError {
        case missingScript
        var errorDescription: String? {
            "This copy of Bottleneck is missing card-watch.sh, so the watcher cannot be "
                + "installed. Rebuilding from source restores it."
        }
    }
}
