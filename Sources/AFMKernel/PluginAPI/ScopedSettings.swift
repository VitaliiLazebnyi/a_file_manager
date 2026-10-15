import Foundation

/// One plugin's corner of a settings store (`SettingsStore.scoped(to:)`): every key it is
/// given goes to the store with the plugin's prefix in front.
internal final class ScopedSettings: SettingsStore {
    private let base: any SettingsStore
    private let prefix: String

    /// The keys of `base` that begin with `prefix`.
    internal init(base: any SettingsStore, prefix: String) {
        self.base = base
        self.prefix = prefix
    }

    /// The value of the prefixed key.
    internal func data(forKey key: String) -> Data? { base.data(forKey: prefix + key) }
    /// Stores under the prefixed key.
    internal func set(_ data: Data?, forKey key: String) { base.set(data, forKey: prefix + key) }
    /// The large value of the prefixed key.
    internal func largeData(forKey key: String) -> Data? { base.largeData(forKey: prefix + key) }
    /// Stores a large value under the prefixed key.
    internal func setLarge(_ data: Data?, forKey key: String) { base.setLarge(data, forKey: prefix + key) }

    deinit {
        // Nothing to release.
    }
}
