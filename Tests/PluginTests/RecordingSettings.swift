import AFMKernel
import Foundation

/// Settings that remember every value ever stored, to prove what never went through them.
///
/// Unchecked: its switches are set by the test before use, and it is used from one thread at a
/// time.
internal final class RecordingSettings: SettingsStore, @unchecked Sendable {
    /// What is stored now, by key.
    private var values: [String: Data] = [:]
    /// Every key and value ever stored, one after the other.
    internal private(set) var everything = Data()

    /// The value stored now under the key, or nil.
    internal func data(forKey key: String) -> Data? {
        values[key]
    }

    /// Stores the value (nil removes it) and adds the key and the value to `everything`.
    internal func set(_ data: Data?, forKey key: String) {
        values[key] = data
        everything.append(Data(key.utf8))
        if let data {
            everything.append(data)
        }
    }

    deinit {
        // Nothing to release.
    }
}
