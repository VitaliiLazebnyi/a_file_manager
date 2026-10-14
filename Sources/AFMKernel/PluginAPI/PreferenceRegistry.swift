import Foundation

/// The pages of the configuration dialog. Plugins add pages while they start; whichever plugin
/// provides the dialog shows them.
@MainActor
public final class PreferenceRegistry {
    public private(set) var pages: [PreferencePage] = []

    public init() {}

    public func add(_ page: PreferencePage) {
        pages.append(page)
    }
}
