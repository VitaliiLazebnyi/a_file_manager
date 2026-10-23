import AFMKernel
import Foundation

/// What the Mark menu remembers between sessions: the masks typed into Select group, the
/// predefined selection types and the options of the configuration page.
///
/// Main thread only.
internal final class SelectionStore {
    /// How many masks the history keeps.
    internal static let historyLimit = 20
    /// The settings scope the history and the types are kept under.
    internal static let scope = "selection"
    /// The full settings key of `marksFolders`, as the configuration dialog writes it.
    internal static let marksFoldersKey = scope + ".markDirectories"
    /// The full settings key of `ignoresOneHour`.
    internal static let oneHourKey = scope + ".oneHourDifference"

    private let settings: any SettingsStore
    private let scoped: any SettingsStore

    /// Whether Num +, Ctrl+Num + and Num * also affect folders (`MarkDirectories`).
    internal var marksFolders: Bool { settings.flag(Self.marksFoldersKey, default: true) }
    /// Whether comparing treats times exactly one hour apart as equal (`1hourdif`).
    internal var ignoresOneHour: Bool { settings.flag(Self.oneHourKey, default: false) }

    /// The masks used so far, the newest first.
    internal var history: [String] { scoped.value([String].self, forKey: "maskHistory") ?? [] }

    /// The saved types; one that does not read is left out, the others stay.
    internal var types: [SelectionType] {
        (scoped.value([Readable<SelectionType>].self, forKey: "types") ?? []).compactMap(\.value)
    }

    /// A store over the program's settings.
    internal init(settings: any SettingsStore) {
        self.settings = settings
        scoped = settings.scoped(to: Self.scope)
    }

    /// Puts a mask first in the history; an earlier use of it is dropped, and the oldest beyond
    /// `historyLimit` go.
    internal func remember(_ mask: String) {
        var masks = history.filter { $0 != mask }
        masks.insert(mask, at: 0)
        scoped.set(Array(masks.prefix(Self.historyLimit)), forKey: "maskHistory")
    }

    /// Removes a mask from the history.
    internal func forget(mask: String) {
        scoped.set(history.filter { $0 != mask }, forKey: "maskHistory")
    }

    /// The saved type of that name, compared without regard to case; nil when there is none.
    internal func type(named name: String) -> SelectionType? {
        types.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Saves a type; one of the same name is replaced.
    internal func save(_ type: SelectionType) {
        var all = types
        if let index = all.firstIndex(where: { $0.name.caseInsensitiveCompare(type.name) == .orderedSame }) {
            all[index] = type
        } else {
            all.append(type)
        }
        scoped.set(all, forKey: "types")
    }

    /// Removes the saved type of that name, compared without regard to case.
    internal func removeType(named name: String) {
        scoped.set(types.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }, forKey: "types")
    }

    deinit {
        // Nothing to release.
    }
}
