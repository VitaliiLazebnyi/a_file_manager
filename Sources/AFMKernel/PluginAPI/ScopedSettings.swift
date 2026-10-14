import Foundation

/// One plugin's corner of a settings store (`SettingsStore.scoped(to:)`): every key it is
/// given goes to the store with the plugin's prefix in front.
internal final class ScopedSettings: SettingsStore {
    private let base: any SettingsStore
    private let prefix: String

    init(base: any SettingsStore, prefix: String) {
        self.base = base
        self.prefix = prefix
    }

    func data(forKey key: String) -> Data? { base.data(forKey: prefix + key) }
    func set(_ data: Data?, forKey key: String) { base.set(data, forKey: prefix + key) }
    func largeData(forKey key: String) -> Data? { base.largeData(forKey: prefix + key) }
    func setLarge(_ data: Data?, forKey key: String) { base.setLarge(data, forKey: prefix + key) }
}
