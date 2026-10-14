import AFMKernel
import Foundation

/// What the settings migration tests share: a fixture goes into a store byte for byte, and two
/// stored values are compared as JSON.
///
/// A fixture is the JSON one version of the program wrote for one key. Today's code must read
/// it, and must write a value of the same shape when it saves it again; a change of the format
/// fails a test and needs a fixture of its own.
internal enum SettingsJSON {
    /// Puts a fixture into the store under `key`, exactly as written.
    internal static func store(_ fixture: String, forKey key: String, in settings: any SettingsStore) {
        settings.set(Data(fixture.utf8) as Data?, forKey: key)
    }

    /// Stored data in one canonical form; nil when it is no JSON.
    ///
    /// Read by `JSONSerialization` and written again with sorted keys and no spacing. Written
    /// out, `true` and `1` stay apart, which comparing the objects would not keep.
    internal static func canonical(_ data: Data?) -> Data? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
    }

    /// Whether the stored value holds the same JSON as the fixture: the same objects, lists,
    /// texts, numbers and truth values, whatever the order of the keys and the spacing.
    internal static func matches(_ data: Data?, _ fixture: String) -> Bool {
        guard let stored = canonical(data) else {
            return false
        }
        return stored == canonical(Data(fixture.utf8))
    }
}
