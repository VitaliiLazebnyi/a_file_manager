public import AFMKernel
public import Foundation

/// Settings that live only as long as the test runs.
///
/// Unchecked `Sendable`: the values are guarded by `lock`.
public final class MemorySettings: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    /// Settings with nothing stored.
    public init() {
        // Nothing is stored yet.
    }

    /// The data stored for `key`, or nil.
    public func data(forKey key: String) -> Data? { lock.withLock { values[key] } }

    /// Stores `data` for `key`; nil removes what was stored.
    public func set(_ data: Data?, forKey key: String) { lock.withLock { values[key] = data } }

    deinit {
        // Nothing to release.
    }
}
