import AFMKernel
import Foundation

/// Remembered options and saved sets (spec 09 › Saved sync sets).
extension SyncSession {
    /// The saved sets, sorted by name (spec 09 › Saved sync sets).
    ///
    /// A set that cannot be read is left out; the others stay.
    internal var savedSets: [SyncSet] {
        (settings.value([StoredElement<SyncSet>].self, forKey: SyncSettingsKey.sets) ?? []).compactMap(\.value)
            .sorted { first, second in Sorter.compare(first.name, second.name, numeric: true) == .orderedAscending }
    }

    /// Stores the options and the Show buttons, for the next window.
    internal func rememberOptions() {
        var remembered = options
        remembered.onlyNames = []
        settings.set(remembered, forKey: SyncSettingsKey.options)
        settings.set(show, forKey: SyncSettingsKey.show)
    }

    /// "Add current directories and settings to list"; a set of the same name is replaced.
    internal func saveSet(named name: String) {
        var saved = options
        saved.onlyNames = []
        let set = SyncSet(name: name, left: leftPath, right: rightPath, options: saved, show: show)
        settings.set(savedSets.filter { other in other.name != name } + [set], forKey: SyncSettingsKey.sets)
    }

    /// Deletes the saved set of that name.
    internal func removeSet(named name: String) {
        settings.set(savedSets.filter { other in other.name != name }, forKey: SyncSettingsKey.sets)
    }

    /// Takes the directories, options and Show buttons of the saved set of that name; false when there is none
    /// (or the files are being synchronized).
    @discardableResult
    internal func loadSet(named name: String) -> Bool {
        guard phase != .synchronizing, let set = savedSets.first(where: { saved in saved.name == name }) else {
            return false
        }
        let includeHidden = options.includeHidden
        leftPath = set.left
        rightPath = set.right
        options = set.options
        options.includeHidden = includeHidden
        onlySelected = false
        clear()
        show = set.show
        return true
    }
}
