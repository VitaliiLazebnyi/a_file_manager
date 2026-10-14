import Foundation

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
