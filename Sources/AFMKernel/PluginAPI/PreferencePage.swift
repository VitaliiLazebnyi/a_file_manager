/// A page of the configuration dialog, offered by the plugin whose settings it holds.
public struct PreferencePage: Sendable {
    /// The page's name in the dialog.
    public let title: String
    /// The settings on the page, in the order they are shown.
    public let preferences: [Preference]
    /// Called on the main thread after the user changed something on this page.
    public let onChange: @MainActor @Sendable () -> Void

    /// A page called `title`; `onChange` is told when the user changed one of its settings.
    @preconcurrency
    public init(
        title: String,
        preferences: [Preference],
        onChange: @escaping @MainActor @Sendable () -> Void = {
            // Most pages are read again when they are next needed.
        }
    ) {
        self.title = title
        self.preferences = preferences
        self.onChange = onChange
    }
}
