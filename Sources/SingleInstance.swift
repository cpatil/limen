import Cocoa
import Darwin

/// Keeps one Limen running at a time.
///
/// This is not tidiness. Two instances both write `history.json`, and neither knows
/// about the other's sessions, so whichever saves last silently discards the other's
/// transfers. The counters themselves are read-only and harmless to sample twice; the
/// log is not.
///
/// LaunchServices already refuses to launch a second copy of the *same* bundle, but
/// that guarantee is thinner than it looks: a copy in `~/Downloads` and a copy in
/// `/Applications` are different bundles to it, and running the executable inside the
/// bundle directly bypasses it entirely. Both happen routinely while developing, which
/// is how the problem was noticed.
///
/// An advisory `flock` covers all three cases, because it is about the file rather
/// than the bundle. The lock is released by the kernel when the process dies, so a
/// crash cannot leave Limen permanently unable to start.
enum SingleInstance {

    /// Held for the lifetime of the process. Closing this descriptor drops the lock,
    /// so it is deliberately never closed.
    private static var lockDescriptor: Int32 = -1

    private static var lockURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Limen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("instance.lock")
    }

    /// True when this process may proceed. When it returns false the running copy has
    /// been brought to the front and this one should exit without a word - that is what
    /// people expect from reopening a Mac app, rather than an error about instances.
    static func claim() -> Bool { claim(at: lockURL.path) }

    /// Split out so the checks can exercise the locking against a temporary file
    /// instead of the one the running app holds.
    static func claim(at path: String) -> Bool {
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            // Somewhere unwritable. Refusing to start over a lock file would be worse
            // than the duplicate-log risk it protects against.
            return true
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            activateRunningInstance()
            return false
        }
        lockDescriptor = fd
        // Record who holds it, purely so the file is legible when someone wonders.
        let note = "pid \(ProcessInfo.processInfo.processIdentifier) "
            + "\(Bundle.main.bundlePath)\n"
        ftruncate(fd, 0)
        _ = note.withCString { write(fd, $0, strlen($0)) }
        return true
    }

    /// Brings the copy that owns the lock to the front.
    ///
    /// Matching on bundle identifier finds it wherever it was launched from. A copy
    /// started as a bare executable has no bundle identity to match, so there may be
    /// nothing to activate - in that case this quietly does nothing and the second
    /// instance still declines to start, which is the part that matters.
    private static func activateRunningInstance() {
        let mine = ProcessInfo.processInfo.processIdentifier
        guard let id = Bundle.main.bundleIdentifier else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id)
        where app.processIdentifier != mine {
            app.activate(options: [.activateAllWindows])
            return
        }
    }
}
