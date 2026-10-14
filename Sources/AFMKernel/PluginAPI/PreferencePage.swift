import Foundation

/// A page of the configuration dialog, offered by the plugin whose settings it holds.
public struct PreferencePage: Sendable {
    public let title: String
    public let preferences: [Preference]
    /// Called on the main thread after the user changed something on this page.
    public let onChange: @MainActor @Sendable () -> Void

    public init(title: String, preferences: [Preference], onChange: @escaping @MainActor @Sendable () -> Void = {}) {
        self.title = title
        self.preferences = preferences
        self.onChange = onChange
    }
}
