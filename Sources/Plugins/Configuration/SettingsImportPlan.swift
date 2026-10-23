import AFMKernel
import Foundation

/// What an import would do, worked out before anything is stored, so that the user can be
/// shown it and asked.
internal struct SettingsImportPlan {
    /// One part that needs the user's own word.
    internal struct Part {
        /// The group the part's keys belong to.
        internal let group: SettingsSchema.Group
        /// What the checkbox says.
        internal let title: String
        /// What the part holds, line by line.
        internal let lines: [String]
        /// The keys of the file that make up the part, sorted.
        internal var keys: [String]
    }

    /// Ordinary settings: stored when the user confirms the import.
    internal var ordinary: [String: Data] = [:]
    /// Ordinary settings the program has and the file has not: removed, so that the import
    /// brings back the state of the export and not a mixture.
    internal var removed: [String] = []
    /// How many of the ordinary settings differ from what is stored now, and some of their names.
    internal var changed: [String] = []
    /// The parts the user is asked about, in the order of `SettingsSchema.Group.allCases`.
    internal var parts: [Part] = []
    /// The values of the parts, already made harmless.
    internal var guarded: [String: Data] = [:]
    /// Entries of the file whose key the program does not know; they are left out.
    internal var unknown: [String] = []
    /// How many numbers of the file were out of range and were limited.
    internal var limited = 0

    /// Whether the import would change nothing.
    internal var isEmpty: Bool { changed.isEmpty && removed.isEmpty && parts.isEmpty }

    /// `current` is what is stored now under every key of the file and of `knownKeys`.
    internal init(_ checked: CheckedSettings, current: [String: Data], knownKeys: [String], schema: SettingsSchema) {
        unknown = checked.unknown
        limited = checked.limited
        var objects = checked.objects
        var values = checked.values
        Self.renumberConnections(&objects, &values, current: current)

        var grouped: [SettingsSchema.Group: [String]] = [:]
        // (The values and the objects have the same keys.)
        for (key, object) in objects {
            let isSame = Self.isStored(object, under: key, in: current)
            if let group = schema.group(of: key, value: object) {
                // What is stored already was the user's own doing and needs no question.
                if !isSame {
                    grouped[group, default: []].append(key)
                    guarded[key] = values[key]
                }
            } else {
                ordinary[key] = values[key]
                if !isSame { changed.append(key) }
            }
        }
        changed.sort()
        removed = Self.removedKeys(knownKeys, file: values, current: current, schema: schema)
        parts = SettingsSchema.Group.allCases.compactMap { group in
            guard let keys = grouped[group]?.sorted(), !keys.isEmpty else {
                return nil
            }
            return Self.part(group, keys: keys, objects: objects)
        }
    }

    /// A value of the file as the type its check gave it; `empty` for anything else.
    internal static func value<Value>(_ object: Any?, or empty: Value) -> Value {
        object as? Value ?? empty
    }

    /// Whether `object` is what is stored under `key` now.
    private static func isStored(_ object: Any, under key: String, in current: [String: Data]) -> Bool {
        guard let data = current[key],
            let stored = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        else { return false }
        return (stored as AnyObject).isEqual(object)
    }

    /// A connection keeps its number only when nothing of it differs from the one stored
    /// under that number: the password in the keychain is found by the number alone, and
    /// must never go to another server because a file reused it.
    ///
    /// The connection used last follows its connection to the new number.
    private static func renumberConnections(
        _ objects: inout [String: Any],
        _ values: inout [String: Data],
        current: [String: Data]
    ) {
        guard let imported = objects[SettingsSchema.connectionsKey] as? [[String: Any]] else {
            return
        }
        let stored =
            (current[SettingsSchema.connectionsKey].flatMap { try? JSONSerialization.jsonObject(with: $0) }
                as? [[String: Any]]) ?? []
        var renumbered: [String: String] = [:]
        let fresh = imported.map { connection -> [String: Any] in
            guard let id = connection["id"] as? String else {
                return connection
            }
            if stored.contains(where: { ($0 as AnyObject).isEqual(connection) }) {
                return connection
            }
            var copy = connection
            let new = UUID().uuidString
            renumbered[id.uppercased()] = new
            copy["id"] = new
            return copy
        }
        objects[SettingsSchema.connectionsKey] = fresh
        values[SettingsSchema.connectionsKey] = try? JSONSerialization.data(
            withJSONObject: fresh,
            options: [.sortedKeys]
        )
        if let last = objects[SettingsSchema.lastConnectionKey] as? String, let new = renumbered[last.uppercased()] {
            objects[SettingsSchema.lastConnectionKey] = new
            values[SettingsSchema.lastConnectionKey] = try? JSONSerialization.data(
                withJSONObject: new,
                options: [.fragmentsAllowed]
            )
        }
    }

    /// The keys of `knownKeys` the file has not and the import removes, sorted.
    ///
    /// What an export leaves out by default is not removed for being absent, and neither is
    /// anything the user is asked about separately.
    private static func removedKeys(
        _ knownKeys: [String],
        file values: [String: Data],
        current: [String: Data],
        schema: SettingsSchema
    ) -> [String] {
        knownKeys.filter { key in
            guard values[key] == nil, let stored = current[key], !SettingsSchema.tabKeys.contains(key),
                !schema.isHistory(key),
                !schema.isConnectionData(key), !schema.isBackup(key)
            else { return false }
            return schema.group(
                of: key,
                value: try? JSONSerialization.jsonObject(with: stored, options: .fragmentsAllowed)
            ) == nil
        }
        .sorted()
    }

    /// What the user is told before the import, apart from the parts that are asked about.
    internal func summary(fileName: String) -> String {
        func listed(_ keys: [String]) -> String {
            let shown = keys.prefix(12).map { DisplayText.oneLine($0, limit: 60) }.joined(separator: ", ")
            return keys.count > 12 ? shown + ", … (\(keys.count - 12) more)" : shown
        }
        var lines = [
            "“\(DisplayText.oneLine(fileName, limit: 120))” holds \(ordinary.count + guarded.count) settings "
                + "the program knows."
        ]
        lines.append(
            changed.isEmpty
                ? "None of the ordinary settings differs from the present ones."
                : "\(changed.count) ordinary settings differ from the present ones and are replaced: "
                    + "\(listed(changed))."
        )
        if !removed.isEmpty {
            lines.append(
                "\(removed.count) settings are not in the file and go back to how the program came: \(listed(removed))."
            )
        }
        if !unknown.isEmpty {
            lines.append("\(unknown.count) entries the program does not know are left out: \(listed(unknown)).")
        }
        if limited > 0 { lines.append("\(limited) numbers were out of range and were limited.") }
        if !parts.isEmpty {
            lines.append(
                "The parts below can make the program run something, change what a key does or change whom it trusts. "
                    + "Each is imported only if you tick it; otherwise it stays as it is now."
            )
        }
        return lines.joined(separator: "\n")
    }

    /// Stores the plan.
    ///
    /// Of the parts, only those in `accepted`.
    internal func apply(to settings: any SettingsStore, accepting accepted: Set<SettingsSchema.Group>) {
        for key in removed { settings.set(nil as Data?, forKey: key) }
        for (key, value) in ordinary { settings.set(value as Data?, forKey: key) }
        for part in parts where accepted.contains(part.group) {
            for key in part.keys { settings.set(guarded[key], forKey: key) }
        }
    }
}
