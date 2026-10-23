import AFMKernel
import Foundation

/// Settings written to a file and read back (the Mac's stand-in for copying `wincmd.ini`;
/// spec 19 › What is saved when).
///
/// A value is kept as the JSON it is stored as, so the file can be read and changed by hand.
internal struct SettingsArchive: Equatable {
    /// Why a file was not taken.
    internal enum ArchiveError: LocalizedError {
        /// The file is not JSON, or not a settings file of this program.
        case notAnArchive
        /// The value of this key does not have the shape the program reads.
        case unreadable(String)

        /// What the user is told.
        internal var errorDescription: String? {
            switch self {
            case .notAnArchive:
                "This is not a settings file of this program."

            case .unreadable(let key):
                "The value of “\(key)” in this file cannot be read, so nothing was imported."
            }
        }
    }

    /// What the `format` field of a settings file holds.
    internal static let format = "A File Manager settings"

    /// The stored data of each key, as the settings hold it.
    internal var values: [String: Data] = [:]

    /// An archive without values.
    internal init() {
        // Every key is filled in afterwards.
    }

    /// Reads a settings file: a value that is JSON is taken as it is, one written as `$data`
    /// (data that is not JSON) is decoded from Base64.
    ///
    /// Throws `ArchiveError.notAnArchive` when the file is not a settings file of this program.
    internal init(data: Data) throws {
        guard let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            file["format"] as? String == Self.format,
            let entries = file["settings"] as? [String: Any]
        else { throw ArchiveError.notAnArchive }
        for (key, value) in entries {
            if let wrapped = value as? [String: Any], wrapped.count == 1, let text = wrapped["$data"] as? String,
                let raw = Data(base64Encoded: text)
            {
                values[key] = raw
            } else if let json = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.fragmentsAllowed, .sortedKeys]
            ) {
                values[key] = json
            }
        }
    }

    /// What the store holds under the given keys; keys without a value are left out.
    internal static func capture(from settings: any SettingsStore, keys: [String]) -> Self {
        var archive = Self()
        for key in keys { archive.values[key] = settings.data(forKey: key) }
        return archive
    }

    /// Makes the store hold what the archive holds.
    ///
    /// Of `knownKeys`, those the archive lacks are removed, so an import brings back the state at
    /// export, not a mixture.
    internal func restore(into settings: any SettingsStore, replacing knownKeys: [String]) {
        for key in knownKeys where values[key] == nil { settings.set(nil as Data?, forKey: key) }
        for (key, value) in values { settings.set(value as Data?, forKey: key) }
    }

    /// Checks the values whose shape is known against it, so that a damaged file is refused
    /// before it replaces working settings.
    internal func validate(keyBindingsKey: String) throws {
        func check<Value: Decodable>(_ key: String, _ type: Value.Type, valid: (Value) -> Bool = { _ in true }) throws {
            guard let data = values[key] else {
                return
            }
            guard let value = try? JSONDecoder().decode(type, from: data), valid(value) else {
                throw ArchiveError.unreadable(key)
            }
        }
        let prefix = ConfigurationStore.owner + "."
        try check(prefix + ConfigurationStore.userCommandsKey, LenientList<UserCommand>.self) { list in
            list.skipped == 0
        }
        try check(prefix + ConfigurationStore.startMenuKey, LenientList<StartMenuEntry>.self) { list in
            list.skipped == 0
        }
        try check(prefix + ConfigurationStore.symbolsKey, [String: String].self)
        try check(keyBindingsKey, [String: [String]].self)
    }

    /// The settings file: pretty-printed JSON with sorted keys, so it can be read and compared.
    ///
    /// Throws only when JSON cannot be written, which the values it holds never cause.
    internal func encoded() throws -> Data {
        var entries: [String: Any] = [:]
        for (key, data) in values {
            entries[key] =
                (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) ?? [
                    "$data": data.base64EncodedString()
                ]
        }
        let file: [String: Any] = ["format": Self.format, "version": 1, "settings": entries]
        return try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys])
    }
}
