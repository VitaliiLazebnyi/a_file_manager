import AFMKernel
import Foundation

/// A settings file read, checked and made harmless, before anything of it is stored.
///
/// Unchecked: `objects` holds only JSON values (texts, numbers, lists and dictionaries, as
/// `JSONSerialization` reads them), which nobody changes once the file is checked.
internal struct CheckedSettings: @unchecked Sendable {
    /// Why a settings file is refused as a whole.
    internal enum Problem: LocalizedError {
        /// The file is larger than `fileLimit`.
        case tooLarge
        /// The value of this key cannot be read, or does not have the shape its key needs.
        case unreadable(String)

        /// What the user is told: what is wrong and that nothing was imported.
        internal var errorDescription: String? {
            switch self {
            case .tooLarge:
                "The file is larger than \(CheckedSettings.fileLimit / 1_024 / 1_024) MB; "
                    + "a settings file is never that large. Nothing was imported."

            case .unreadable(let key):
                "The value of “\(DisplayText.oneLine(key, limit: 80))” in this file cannot be read, "
                    + "so nothing was imported."
            }
        }
    }

    /// The largest file that is read: a settings file is some hundred kilobytes.
    internal static let fileLimit = 16 * 1_024 * 1_024
    /// No number of a settings file may be larger: counters are counted on, sizes multiplied.
    internal static let numberLimit: Double = 1_000_000_000_000
    /// The largest visit counter of a frequently used folder.
    internal static let frequentCountLimit = 1_000_000
    /// The most user commands a file may hold.
    internal static let userCommandLimit = 2_000
    /// The most Start-menu entries a file may hold.
    internal static let startMenuLimit = 500
    /// The longest text of an option, a title or a command, in UTF-8 bytes.
    internal static let textLimit = 65_536

    /// The values that may be stored, as the JSON they are stored as.
    internal var values: [String: Data] = [:]
    /// The same as objects, for describing them.
    internal var objects: [String: Any] = [:]
    /// Entries of the file whose key the program does not know; they are left out.
    internal var unknown: [String] = []
    /// How many numbers were out of every sensible range and were limited.
    internal var limited = 0

    /// Checks every entry: its key must be known, a value whose shape is known must have it,
    /// and numbers are limited.
    ///
    /// Throws when a known value cannot be read, so that a damaged file is refused before it
    /// replaces working settings.
    internal init(_ archive: SettingsArchive, schema: SettingsSchema) throws {
        for (key, data) in archive.values {
            guard schema.isKnown(key) else {
                unknown.append(key)
                continue
            }
            guard data.count <= Self.fileLimit,
                let parsed = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            else {
                throw Problem.unreadable(key)
            }
            var object = Self.limitingNumbers(parsed, &limited)
            if key == SettingsSchema.frequentFoldersKey { object = Self.limitingCounts(object, &limited) }
            // What was read as JSON, its numbers limited, is JSON again.
            let clean = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
            try Self.checkShape(of: key, clean, object, schema: schema)
            values[key] = clean
            objects[key] = object
        }
        unknown.sort()
    }

    /// Reads at most `fileLimit` bytes of a file.
    internal static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: fileLimit + 1) ?? Data()
        guard data.count <= fileLimit else { throw Problem.tooLarge }
        return data
    }

    /// Whether a JSON value is `true` or `false`.
    private static func isBoolean(_ object: Any) -> Bool { CFGetTypeID(object as AnyObject) == CFBooleanGetTypeID() }

    /// The value of a JSON number, as close as a `Double` comes to it; nil for anything else,
    /// `true` and `false` too (they are not numbers to Core Foundation).
    private static func number(_ object: Any) -> Double? {
        let reference = object as AnyObject
        guard CFGetTypeID(reference) == CFNumberGetTypeID() else {
            return nil
        }
        var value = 0.0
        // The type was checked above. The answer says whether the conversion was exact; a
        // rounded value is what is wanted.
        _ = CFNumberGetValue(unsafeDowncast(reference, to: CFNumber.self), .doubleType, &value)
        return value
    }

    private static func limitingNumbers(_ object: Any, _ limited: inout Int) -> Any {
        if let list = object as? [Any] {
            return list.map { limitingNumbers($0, &limited) }
        }
        if let dictionary = object as? [String: Any] {
            return dictionary.mapValues { limitingNumbers($0, &limited) }
        }
        // (JSON has no NaN.)
        guard let value = number(object), abs(value) > numberLimit else {
            return object
        }
        limited += 1
        return value < 0 ? -Int(numberLimit) : Int(numberLimit)
    }

    /// The visit counters of the frequently used folders are counted on with every visit.
    private static func limitingCounts(_ object: Any, _ limited: inout Int) -> Any {
        guard var frequent = object as? [String: Any], let counts = frequent["counts"] as? [String: Any] else {
            return object
        }
        frequent["counts"] = counts.mapValues { value -> Any in
            guard let count = number(value), count < 0 || count > Double(frequentCountLimit) else {
                return value
            }
            limited += 1
            return count < 0 ? 0 : frequentCountLimit
        }
        return frequent
    }

    private static func checkShape(of key: String, _ data: Data, _ object: Any, schema: SettingsSchema) throws {
        if let kind = schema.preferences[key] {
            try checkPreference(kind, object, key: key)
        } else {
            try checkStructure(of: key, data, object, schema: schema)
        }
    }

    /// The value of a page's option must be of its kind: a flag, a short text or the number of a choice.
    private static func checkPreference(_ kind: Preference.Kind, _ object: Any, key: String) throws {
        switch kind {
        case .flag:
            try require(isBoolean(object), key: key)

        case .text:
            try require((object as? String).map { $0.utf8.count <= textLimit } ?? false, key: key)

        case .choice(let options, _):
            guard let value = number(object), let index = Int(exactly: value) else {
                throw Problem.unreadable(key)
            }
            try require(options.indices.contains(index), key: key)
        }
    }

    /// The values the configuration and the panels read back as whole structures must decode
    /// as those, within the limits.
    private static func checkStructure(of key: String, _ data: Data, _ object: Any, schema: SettingsSchema) throws {
        switch key {
        case SettingsSchema.userCommandsKey:
            let list = try decoded(LenientList<UserCommand>.self, from: data, key: key)
            try require(list.skipped == 0 && list.elements.count <= userCommandLimit, key: key)
            try require(
                list.elements.allSatisfy { command in
                    UserCommand.name(from: command.name) == command.name && command.title.utf8.count <= textLimit
                        && isShort(command.action)
                },
                key: key
            )

        case SettingsSchema.startMenuKey:
            let list = try decoded(LenientList<StartMenuEntry>.self, from: data, key: key)
            try require(list.skipped == 0 && list.elements.count <= startMenuLimit, key: key)
            try require(list.elements.allSatisfy { $0.title.utf8.count <= textLimit && isShort($0.action) }, key: key)

        case SettingsSchema.symbolsKey:
            _ = try decoded([String: String].self, from: data, key: key)

        case schema.keyBindingsKey:
            _ = try decoded([String: [String]].self, from: data, key: key)

        case SettingsSchema.connectionsKey:
            try require(object is [[String: Any]], key: key)

        default:
            if SettingsSchema.tabKeys.contains(key) { _ = try decoded(PanelTabs.State.self, from: data, key: key) }
        }
    }

    /// The value decoded as `type`; throws `Problem.unreadable(key)` when it is not one.
    private static func decoded<Value: Decodable>(_ type: Value.Type, from data: Data, key: String) throws -> Value {
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            throw Problem.unreadable(key)
        }
        return value
    }

    /// Throws `Problem.unreadable(key)` unless `condition` holds.
    private static func require(_ condition: Bool, key: String) throws {
        if !condition { throw Problem.unreadable(key) }
    }

    /// Whether every text of an action is within `textLimit`.
    private static func isShort(_ action: CommandAction) -> Bool {
        [action.command, action.parameters, action.startPath].allSatisfy { $0.utf8.count <= textLimit }
    }
}
