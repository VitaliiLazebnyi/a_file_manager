public import AFMKernel
public import Foundation

/// Settings that live only as long as the test runs. Unchecked: the values
/// are guarded by `lock`.
public final class MemorySettings: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    public init() {}
    public func data(forKey key: String) -> Data? { lock.withLock { values[key] } }
    public func set(_ data: Data?, forKey key: String) { lock.withLock { values[key] = data } }
}
