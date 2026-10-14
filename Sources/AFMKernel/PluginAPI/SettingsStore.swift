public import Foundation

/// Values remembered between sessions.
///
/// Used from any thread.
public protocol SettingsStore: AnyObject, Sendable {
    /// The value stored under `key`; nil when there is none.
    func data(forKey key: String) -> Data?
    /// Stores `data` under `key`; nil removes the value.
    func set(_ data: Data?, forKey key: String)
    /// A value that may be large (megabytes: a long history) and is read and written as a
    /// whole. A store that keeps such values apart from the small ones (a file each, written
    /// in the background) offers these two; the default keeps them with the rest.
    func largeData(forKey key: String) -> Data?
    /// Stores a large value (see `largeData(forKey:)`); nil removes it.
    func setLarge(_ data: Data?, forKey key: String)
}

/// Large values kept with the rest, values as JSON, and a plugin's own corner of the store.
extension SettingsStore {
    /// The value under `key`, kept with the small ones.
    public func largeData(forKey key: String) -> Data? { data(forKey: key) }

    /// Stores a large value with the small ones.
    public func setLarge(_ data: Data?, forKey key: String) { set(data, forKey: key) }

    /// The value under `key` read as JSON; nil when there is none or it does not read as `type`.
    public func value<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    /// Stores a value as JSON.
    public func set<Value: Encodable>(_ value: Value, forKey key: String) {
        set(try? JSONEncoder().encode(value), forKey: key)
    }

    /// Raw data is stored as it is, through `set(_:forKey:)` with a `Data?`.
    ///
    /// Without this, `Data` would match the generic method above better and be stored as JSON text.
    @available(*, unavailable, message: "Pass the data as `Data?`: it is then stored as it is")
    public func set(_ data: Data, forKey key: String) {
        set(data as Data?, forKey: key)
    }

    /// A plugin's own corner of the settings: its keys cannot clash with anyone else's.
    public func scoped(to owner: String) -> any SettingsStore {
        ScopedSettings(base: self, prefix: owner + ".")
    }
}
