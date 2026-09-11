import Cocoa
import Darwin

/// First-run setup and a short tour.
///
/// Deliberately not a slideshow. Each setup page checks the thing it is talking about
/// and says what it found, because a page that only gives instructions cannot tell you
/// whether they worked - and the two failures people actually hit here (an app still
/// sitting in Downloads under quarantine, and removable-volume access never granted)
/// both look exactly like the app being broken.
///
/// Reachable afterwards from Help ▸ Setup and Tour, so it is not a one-shot.
enum Setup {

    private static let seenKey = "SeenWelcome"

    static var hasBeenSeen: Bool { UserDefaults.standard.bool(forKey: seenKey) }

    static func markSeen() { UserDefaults.standard.set(true, forKey: seenKey) }

    // ---- what the setup pages actually check ----------------------------

    enum InstallState {
        /// Running from a read-only disk image or a translocated copy: nothing the
        /// user does in this copy will persist.
        case translocated
        /// Somewhere other than an Applications folder.
        case elsewhere(String)
        case installed

        var isFine: Bool { if case .installed = self { return true }; return false }
    }

    static var installState: InstallState {
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return .translocated
        }
        if path.hasPrefix("/Applications/")
            || path.hasPrefix(NSHomeDirectory() + "/Applications/") {
            return .installed
        }
        return .elsewhere((path as NSString).deletingLastPathComponent)
    }

    /// Whether the app is still carrying the quarantine flag, which is what makes
    /// Gatekeeper refuse an unnotarised download.
    static var isQuarantined: Bool {
        var buffer = [CChar](repeating: 0, count: 512)
        let size = getxattr(Bundle.main.bundlePath, "com.apple.quarantine",
                            &buffer, buffer.count, 0, 0)
        return size > 0
    }

    enum RemovableAccess {
        case granted
        case denied
        /// Nothing removable is attached, so there is nothing to test against.
        case untested
    }

    /// Tries to read a removable volume, because that is the only honest test: macOS
    /// exposes no query for "do I hold this permission", only the answer you get when
    /// you use it.
    static var removableAccess: RemovableAccess {
        let mounts = ProcessSampler.mountPoints()
        let removable = USBSampler.sample()
            .filter { $0.removableMedia }
            .flatMap { $0.disks }
            .compactMap { mounts[$0] }
            .filter { $0.hasPrefix("/Volumes") }
        guard let volume = removable.first else { return .untested }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: volume)
            return .granted
        } catch {
            return .denied
        }
    }

    // ---- actions the pages offer ----------------------------------------

    /// Opens the Privacy pane at removable volumes, falling back to the pane itself on
    /// releases that do not take the anchor.
    static func openRemovablePrivacySettings() {
        let anchored = "x-apple.systempreferences:com.apple.preference.security?Privacy_RemovableVolumes"
        let plain = "x-apple.systempreferences:com.apple.preference.security"
        if let url = URL(string: anchored), NSWorkspace.shared.open(url) { return }
        if let url = URL(string: plain) { NSWorkspace.shared.open(url) }
    }

    /// Asks macOS for removable-volume access by doing the thing that needs it.
    ///
    /// There is no API that means "please show the permission prompt". The prompt is
    /// raised by the first attempt to read a removable volume, and the attempt blocks
    /// until the answer comes back - so this both asks and reports. With nothing
    /// attached there is nothing to ask about, which is why the page says to insert a
    /// card first rather than offering a button that would silently do nothing.
    ///
    /// macOS asks once per app. If the answer was no, it is not asked again, and the
    /// only way back is System Settings - which is why that route stays on the page.
    static func requestRemovableAccess() -> RemovableAccess { removableAccess }

    /// Opens Privacy & Security at the top, where the "Open Anyway" button appears
    /// after macOS has blocked something.
    ///
    /// A different anchor from the removable-volumes one: that button lives in the
    /// Security section of the same pane, and only after a blocked launch - macOS
    /// shows it for about an hour afterwards and then withdraws it, which is why the
    /// instruction has to say "try to open it first".
    static func openSecuritySettings() {
        let anchored = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        let plain = "x-apple.systempreferences:com.apple.preference.security"
        if let url = URL(string: anchored), NSWorkspace.shared.open(url) { return }
        if let url = URL(string: plain) { NSWorkspace.shared.open(url) }
    }

    /// Copies the app into /Applications and restarts from there.
    static func installToApplications() -> String? {
        let source = Bundle.main.bundlePath
        let destination = "/Applications/" + (source as NSString).lastPathComponent
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination) { try fm.removeItem(atPath: destination) }
            try fm.copyItem(atPath: source, toPath: destination)
        } catch {
            return error.localizedDescription
        }
        relaunch(at: destination)
        return nil
    }

    /// Quits and starts the copy at `path`. Used after installing, and after granting
    /// a permission - macOS hands some privileges out only to a freshly launched
    /// process, so "restart it" is genuinely part of the instructions.
    static func relaunch(at path: String? = nil) {
        let target = path ?? Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/bin/sh"
        // A moment's delay so this process is gone before the next one claims the
        // single-instance lock.
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"\(target)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
