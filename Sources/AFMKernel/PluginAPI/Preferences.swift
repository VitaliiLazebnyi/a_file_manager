import Foundation

/// One setting the user can change in the configuration dialog (spec 13 › The dialog
/// framework). The value lives in the settings store under `key`.
public struct Preference {
    public enum Kind {
        case flag(default: Bool)
        case text(default: String)
        /// One of a few options; the index is stored.
        case choice([String], default: Int)
    }

    /// The full settings key, e.g. `viewer.wrapLines`.
    public let key: String
    public let label: String
    public let kind: Kind

    public init(_ key: String, _ label: String, _ kind: Kind) {
        self.key = key
        self.label = label
        self.kind = kind
    }
}

/// A page of the configuration dialog, offered by the plugin whose settings it holds.
public struct PreferencePage {
    public let title: String
    public let preferences: [Preference]
    /// Called on the main thread after the user changed something on this page.
    public let onChange: () -> Void

    public init(title: String, preferences: [Preference], onChange: @escaping () -> Void = {}) {
        self.title = title
        self.preferences = preferences
        self.onChange = onChange
    }
}

/// The pages of the configuration dialog. Plugins add pages while they start; whichever plugin
/// provides the dialog shows them.
public final class PreferenceRegistry {
    public private(set) var pages: [PreferencePage] = []

    public init() {}

    public func add(_ page: PreferencePage) {
        pages.append(page)
    }
}

extension SettingsStore {
    public func flag(_ key: String, default value: Bool) -> Bool { self.value(Bool.self, forKey: key) ?? value }
    public func text(_ key: String, default value: String) -> String { self.value(String.self, forKey: key) ?? value }
    public func index(_ key: String, default value: Int) -> Int { self.value(Int.self, forKey: key) ?? value }

    /// The current value of a preference as a form would hold it.
    public func value(of preference: Preference) -> FormValues.Value {
        switch preference.kind {
        case .flag(let value): return .flag(flag(preference.key, default: value))
        case .text(let value): return .text(text(preference.key, default: value))
        case .choice(_, let value): return .index(index(preference.key, default: value))
        }
    }

    public func set(_ value: FormValues.Value, for preference: Preference) {
        switch value {
        case .flag(let flag): set(flag, forKey: preference.key)
        case .text(let text): set(text, forKey: preference.key)
        case .index(let index): set(index, forKey: preference.key)
        }
    }
}
