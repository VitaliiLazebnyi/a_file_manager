import AFMKernel

/// A page of the Options window while it is open (spec 13 › The dialog framework): the values
/// the user sees, which reach the settings only with Apply or OK. Main thread only.
@MainActor
internal final class PreferencePageModel {
    /// The page a plugin registered: its title, its preferences and whom to tell of a change.
    internal let page: PreferencePage
    private let settings: any SettingsStore
    private var stored: [String: FormValues.Value] = [:]
    private var pending: [String: FormValues.Value] = [:]

    /// The title the page shows in the list of pages.
    internal var title: String { page.title }

    /// Whether the user changed a value since the page was opened or last applied.
    internal var isChanged: Bool { pending != stored }

    /// The page with the values `settings` hold now.
    internal init(page: PreferencePage, settings: any SettingsStore) {
        self.page = page
        self.settings = settings
        discard()
    }

    /// What the page shows for `preference`: the user's change if there is one, else the stored value.
    internal func value(of preference: Preference) -> FormValues.Value {
        pending[preference.key] ?? settings.value(of: preference)
    }

    /// Takes the user's `value` for `preference`; it is written only by `commit()`.
    internal func set(_ value: FormValues.Value, for preference: Preference) {
        pending[preference.key] = value
    }

    /// Apply: writes what was changed and tells the page's plugin, once, if anything was.
    internal func commit() {
        let changed = page.preferences.filter { pending[$0.key] != stored[$0.key] }
        guard !changed.isEmpty else {
            return
        }
        for preference in changed {
            if let value = pending[preference.key] { settings.set(value, for: preference) }
        }
        stored = pending
        page.onChange()
    }

    /// Cancel: back to what the settings hold.
    internal func discard() {
        stored = [:]
        for preference in page.preferences { stored[preference.key] = settings.value(of: preference) }
        pending = stored
    }

    deinit {
        // Nothing to release.
    }
}
