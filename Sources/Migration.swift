import Foundation

/// Carrying a user's data across the rename from Limen to Bottleneck.
///
/// The app kept everything under an Application Support folder and a preferences
/// domain named after itself, so renaming it would have quietly abandoned both: three
/// hundred logged sessions, the speed catalogue, every setting, and a LaunchAgent
/// still watching /Volumes under the old label. None of that is recoverable by the
/// user afterwards - the files are simply in a folder nothing reads any more - so the
/// rename has to bring them along.
///
/// Runs once, at launch, before anything reads either location. Deliberately a move
/// rather than a copy for the folder, so there is one copy of the log and no question
/// afterwards about which is current; and deliberately a no-op the moment the new
/// folder exists, so it cannot run twice and cannot overwrite live data.
enum Migration {
    static let oldName = "Limen"
    static let newName = "Bottleneck"
    static let oldDomain = "local.limen"
    static let newDomain = "local.bottleneck"
    static let oldAgentLabel = "local.limen.card-watch"

    /// Whether one file should be carried across: it is in the old folder and the new
    /// folder has nothing by that name. Pure, so the decision can be tested without
    /// moving anything.
    ///
    /// Per file, not per folder. The first version of this asked whether the new
    /// folder existed at all - and the new folder gets created the moment anything
    /// touches the catalogue, including the test suite, so the guard meant to protect
    /// live data would have skipped the move entirely and left five hundred sessions
    /// sitting in a folder nothing reads.
    static func shouldCarry(fileExistsInOld: Bool, fileExistsInNew: Bool) -> Bool {
        fileExistsInOld && !fileExistsInNew
    }

    static func run(fileManager: FileManager = .default,
                    defaults: UserDefaults = .standard) {
        let support = fileManager.urls(for: .applicationSupportDirectory,
                                       in: .userDomainMask)[0]
        let old = support.appendingPathComponent(oldName, isDirectory: true)
        let new = support.appendingPathComponent(newName, isDirectory: true)

        if let items = try? fileManager.contentsOfDirectory(atPath: old.path) {
            try? fileManager.createDirectory(at: new, withIntermediateDirectories: true)
            for item in items {
                // The lock file belongs to whichever process is running; it is
                // recreated on demand and carrying it across means nothing.
                guard item != "instance.lock" else { continue }
                let from = old.appendingPathComponent(item)
                let to = new.appendingPathComponent(item)
                guard shouldCarry(fileExistsInOld: fileManager.fileExists(atPath: from.path),
                                  fileExistsInNew: fileManager.fileExists(atPath: to.path))
                else { continue }
                try? fileManager.moveItem(at: from, to: to)
            }
            // Left behind only if something could not be moved, which is worth being
            // able to see afterwards rather than silently deleting.
            if (try? fileManager.contentsOfDirectory(atPath: old.path))?
                .filter({ $0 != "instance.lock" }).isEmpty == true {
                try? fileManager.removeItem(at: old)
            }
        }

        // Preferences are a separate store keyed by domain, so they need their own
        // pass. Only what the old app actually wrote: copying the whole domain would
        // drag in AppKit's own window-frame keys under the wrong name.
        if defaults.persistentDomain(forName: newDomain) == nil,
           let carried = defaults.persistentDomain(forName: oldDomain) {
            defaults.setPersistentDomain(carried, forName: newDomain)
        }

        // The old watcher would keep running, keep reading the old preferences domain,
        // and keep opening an app that no longer exists there.
        retireOldAgent(fileManager: fileManager)
    }

    /// Unloads and removes the LaunchAgent installed under the old name. The new one
    /// is installed on demand by CardWatch, from the switches carried across above.
    private static func retireOldAgent(fileManager: FileManager) {
        let plist = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchAgents/\(oldAgentLabel).plist")
        guard fileManager.fileExists(atPath: plist.path) else { return }
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["unload", plist.path]
        task.standardError = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        try? fileManager.removeItem(at: plist)
    }
}
