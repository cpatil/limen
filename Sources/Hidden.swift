import Foundation

/// Rows the user has put out of sight.
///
/// Hiding is a statement about attention, not about measurement: a tunnel that
/// carries a copy of every byte on the interface beneath it is noise in the lists and
/// noise at the top of the log, but its counters are still the truth about what the
/// machine did. So hidden rows keep being sampled and keep being recorded - they are
/// dropped from the lists, and their groups sink to the bottom of the log instead of
/// being bumped up every time they twitch.
///
/// Hidden by row id, which is stable across launches; the device's name is kept
/// alongside because the transfer log is keyed by name rather than by id, and the two
/// have to agree about what has been hidden.
enum Hidden {
    private static let idsKey = "HiddenRowIDs"
    private static let namesKey = "HiddenRowNames"
    /// Whether the lists are currently showing hidden rows so they can be brought
    /// back. Not persisted: it is a mode you are in while tidying up, and coming back
    /// tomorrow to a window still full of the rows you hid would be a bug.
    static var revealing = false

    static var ids: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: idsKey) ?? [])
    }
    static var names: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: namesKey) ?? [])
    }

    static var count: Int { ids.count }

    static func isHidden(id: String) -> Bool { ids.contains(id) }
    static func isHidden(name: String) -> Bool { names.contains(name) }

    /// Hides or reveals one row. Both directions from one call, because an action with
    /// no way back is not finished.
    static func set(id: String, name: String, hidden: Bool) {
        var currentIDs = ids
        var currentNames = names
        if hidden {
            currentIDs.insert(id)
            currentNames.insert(name)
        } else {
            currentIDs.remove(id)
            currentNames.remove(name)
        }
        UserDefaults.standard.set(Array(currentIDs).sorted(), forKey: idsKey)
        UserDefaults.standard.set(Array(currentNames).sorted(), forKey: namesKey)
    }

    static func revealAll() {
        UserDefaults.standard.removeObject(forKey: idsKey)
        UserDefaults.standard.removeObject(forKey: namesKey)
    }

    /// What the lists should show: everything unless something has been hidden, and
    /// everything again while the user is looking at what they hid.
    static func visible<T>(_ rows: [T], id: (T) -> String) -> [T] {
        guard !revealing else { return rows }
        let hidden = ids
        guard !hidden.isEmpty else { return rows }
        return rows.filter { !hidden.contains(id($0)) }
    }

    /// The log in the same order it had, with hidden devices moved to the end rather
    /// than removed - the sessions happened, and they are still worth finding. A
    /// stable partition, so everything else keeps its newest-first order.
    static func sink<T>(_ groups: [T], name: (T) -> String) -> [T] {
        let hidden = names
        guard !hidden.isEmpty else { return groups }
        return groups.filter { !hidden.contains(name($0)) }
             + groups.filter { hidden.contains(name($0)) }
    }
}
