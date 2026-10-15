/// The pages of the configuration dialog.
///
/// Plugins add pages while they start; whichever plugin provides the dialog shows them. Main thread.
@preconcurrency
@MainActor
public final class PreferenceRegistry {
    /// Every page, in the order the plugins added them.
    public private(set) var pages: [PreferencePage] = []

    /// No pages yet.
    public init() {
        // Pages come with the plugins.
    }

    /// Adds a page after the others.
    public func add(_ page: PreferencePage) {
        pages.append(page)
    }

    deinit {
        // Nothing to release.
    }
}
