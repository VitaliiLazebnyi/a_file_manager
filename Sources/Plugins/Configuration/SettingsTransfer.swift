import AFMKernel
import Foundation

/// What the program knows about its settings, for deciding what a settings file may bring in
/// and what an export leaves out.
///
/// A plain value: made on the main thread, used on any.
internal struct SettingsSchema {
    /// The options of the configuration pages, with their kinds.
    internal var preferences: [String: Preference.Kind] = [:]
    /// Keys the running program knows by name: its own, and those it has stored.
    internal var known: Set<String> = []
    internal var keyBindingsKey = KeyBindings.settingsKey
    /// What the plugin a key belongs to has said about it (`Kernel.settingsKeys`), nil for a
    /// key nobody declared.
    ///
    /// Asked before the names are looked at: a plugin knows what its key does, and a name gives it
    /// away only when it happens to hold the right word.
    internal var declaredKind: @Sendable (String) -> SettingsKeyKind? = { _ in nil }

    /// The corners of the settings the parts of the program keep their values in.
    ///
    /// A key of none of them is nobody's and is not imported.
    internal static let namespaces: Set<String> = [
        "window", "panel", "listingCache", "toolbar", "configuration", "systemTools", "viewOptions", "macIntegration",
        "folderTabs", "clipboard",
        "virtualFolders", "findFiles", "places", "network", "selection", "multirename", "directorySync",
        "compareContent", "filetools", "viewer",
        "archives", "fileOperations", "fileProperties"
    ]
    internal static let tabKeys: Set<String> = ["left.tabs", "right.tabs"]
    internal static let userCommandsKey = ConfigurationStore.owner + "." + ConfigurationStore.userCommandsKey
    internal static let startMenuKey = ConfigurationStore.owner + "." + ConfigurationStore.startMenuKey
    internal static let symbolsKey = ConfigurationStore.owner + "." + ConfigurationStore.symbolsKey
    internal static let frequentFoldersKey = "places.history.frequent"
    internal static let hotlistKey = "places.hotlist"
    internal static let connectionsKey = "network.connections"
    internal static let lastConnectionKey = "network.lastUsed"

    internal func isKnown(_ key: String) -> Bool {
        if preferences[key] != nil || known.contains(key) || key == keyBindingsKey
            || Self.tabKeys.contains(key)
        {
            return true
        }
        guard !isBackup(key), let dot = key.firstIndex(of: "."),
            key[key.index(after: dot)...].contains(where: { $0 != "." })
        else { return false }
        return Self.namespaces.contains(String(key[..<dot]))
    }

    /// The copy the program keeps of stored data it could not read.
    ///
    /// It is neither exported nor imported.
    internal func isBackup(_ key: String) -> Bool { key.contains(".unreadable") }

    // MARK: What an export leaves out unless asked

    /// What the user did, as opposed to what the user set up: typed command lines, visited
    /// folders, search texts, the files renamed last.
    internal func isHistory(_ key: String) -> Bool {
        guard preferences[key] == nil else {
            return false
        }
        if declaredKind(key) == .history {
            return true
        }
        let lowered = key.lowercased()
        return lowered.contains("history") || lowered.contains("undo") || lowered.contains("lastserver")
    }

    /// Servers, user names and the certificates accepted for them.
    internal func isConnectionData(_ key: String) -> Bool {
        key == Self.connectionsKey || key == Self.lastConnectionKey
            || group(of: key, value: nil) == .trust
    }

    // MARK: What an import asks about

    /// The parts of a settings file that can make the program run something, change what a
    /// key does, or change whom it trusts.
    ///
    /// Each is imported only when the user says so.
    internal enum Group: String, CaseIterable {
        case commands, keys, programs, trust, connections, hotlist, tabs
    }

    /// The group a key belongs to; nil for an ordinary setting. `value` is the value in the
    /// file, where the group depends on it.
    internal func group(of key: String, value: Any?) -> Group? {
        if key == Self.userCommandsKey || key == Self.startMenuKey {
            return .commands
        }
        if key == keyBindingsKey {
            return .keys
        }
        if key == Self.hotlistKey {
            return .hotlist
        }
        if key == Self.connectionsKey || key == Self.lastConnectionKey {
            return .connections
        }
        // What its own plugin says a key is: a key that decides whom the program trusts is
        // asked about whatever it is called (the list of servers a password may be sent to
        // without protection has none of the words looked for below in its name), and so is
        // one that holds something that is run.
        switch declaredKind(key) {
        case .trust:
            return .trust

        case .connection:
            return .connections

        case .runsCode:
            return .programs

        default:
            break
        }
        let lowered = key.lowercased()
        if lowered.hasPrefix("network."), ["certificate", "trust", "tls"].contains(where: lowered.contains) {
            return .trust
        }
        if Self.tabKeys.contains(key) {
            // Tabs on this Mac's disks are ordinary; one on a server makes the program connect.
            guard let state = value as? [String: Any], let tabs = state["tabs"] as? [[String: Any]] else {
                return nil
            }
            let isRemote = tabs.contains { tab in
                (tab["location"] as? String).map { !$0.lowercased().hasPrefix("file:") } ?? false
            }
            return isRemote ? .tabs : nil
        }
        // A text that names a program, a command or a file the program then starts or writes to.
        if value is String {
            let name = lowered.split(separator: ".").last.map(String.init) ?? lowered
            let namesAProgram = ["editor", "terminal", "program", "command", "tool", "shell", "exec", "path", "file"]
                .contains(where: name.contains)
            if namesAProgram, !isHistory(key) {
                return .programs
            }
        }
        return nil
    }
}

/// A settings file read, checked and made harmless, before anything of it is stored.
///
/// Unchecked: `objects` holds only JSON values (texts, numbers, lists and dictionaries, as
/// `JSONSerialization` reads them), which nobody changes once the file is checked.
internal struct CheckedSettings: @unchecked Sendable {
    /// The values that may be stored, as the JSON they are stored as.
    internal var values: [String: Data] = [:]
    /// The same as objects, for describing them.
    internal var objects: [String: Any] = [:]
    /// Entries of the file whose key the program does not know; they are left out.
    internal var unknown: [String] = []
    /// How many numbers were out of every sensible range and were limited.
    internal var limited = 0

    /// The largest file that is read: a settings file is some hundred kilobytes.
    internal static let fileLimit = 16 * 1_024 * 1_024
    /// No number of a settings file may be larger: counters are counted on, sizes multiplied.
    internal static let numberLimit: Double = 1_000_000_000_000
    internal static let frequentCountLimit = 1_000_000
    internal static let userCommandLimit = 2_000
    internal static let startMenuLimit = 500
    internal static let textLimit = 65_536

    internal enum Problem: LocalizedError {
        case tooLarge
        case unreadable(String)

        internal var errorDescription: String? {
            switch self {
            case .tooLarge:
                "The file is larger than \(CheckedSettings.fileLimit / 1_024 / 1_024) MB; a settings file is never that large. Nothing was imported."

            case .unreadable(let key):
                "The value of “\(DisplayText.oneLine(key, limit: 80))” in this file cannot be read, so nothing was imported."
            }
        }
    }

    /// Reads at most `fileLimit` bytes of a file.
    internal static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: fileLimit + 1) ?? Data()
        guard data.count <= fileLimit else { throw Problem.tooLarge }
        return data
    }

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

    private static func isBoolean(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

    private static func limitingNumbers(_ object: Any, _ limited: inout Int) -> Any {
        if let list = object as? [Any] {
            return list.map { limitingNumbers($0, &limited) }
        }
        if let dictionary = object as? [String: Any] {
            return dictionary.mapValues { limitingNumbers($0, &limited) }
        }
        guard let number = object as? NSNumber, !isBoolean(number) else {
            return object
        }
        // (JSON has no NaN.)
        let value = number.doubleValue
        guard abs(value) > numberLimit else {
            return object
        }
        limited += 1
        return NSNumber(value: value < 0 ? -Int64(numberLimit) : Int64(numberLimit))
    }

    /// The visit counters of the frequently used folders are counted on with every visit.
    private static func limitingCounts(_ object: Any, _ limited: inout Int) -> Any {
        guard var frequent = object as? [String: Any], let counts = frequent["counts"] as? [String: Any] else {
            return object
        }
        frequent["counts"] = counts.mapValues { value -> Any in
            guard let number = value as? NSNumber, !isBoolean(number) else {
                return value
            }
            let count = number.doubleValue
            guard count < 0 || count > Double(frequentCountLimit) else {
                return value
            }
            limited += 1
            return NSNumber(value: count < 0 ? 0 : frequentCountLimit)
        }
        return frequent
    }

    private static func checkShape(of key: String, _ data: Data, _ object: Any, schema: SettingsSchema) throws {
        func decoded<Value: Decodable>(_ type: Value.Type) throws -> Value {
            guard let value = try? JSONDecoder().decode(type, from: data) else { throw Problem.unreadable(key) }
            return value
        }
        func require(_ condition: Bool) throws {
            if !condition { throw Problem.unreadable(key) }
        }
        if let kind = schema.preferences[key] {
            switch kind {
            case .flag:
                try require(object is NSNumber && isBoolean(object as! NSNumber))

            case .text:
                try require((object as? String).map { $0.utf8.count <= textLimit } ?? false)

            case .choice(let options, _):
                guard let number = object as? NSNumber, !isBoolean(number), let index = Int(exactly: number.doubleValue)
                else { throw Problem.unreadable(key) }
                try require(options.indices.contains(index))
            }
            return
        }
        func isShort(_ action: CommandAction) -> Bool {
            [action.command, action.parameters, action.startPath].allSatisfy { $0.utf8.count <= textLimit }
        }
        switch key {
        case SettingsSchema.userCommandsKey:
            let list = try decoded(LenientList<UserCommand>.self)
            try require(list.skipped == 0 && list.elements.count <= userCommandLimit)
            try require(
                list.elements.allSatisfy {
                    UserCommand.name(from: $0.name) == $0.name && $0.title.utf8.count <= textLimit && isShort($0.action)
                }
            )

        case SettingsSchema.startMenuKey:
            let list = try decoded(LenientList<StartMenuEntry>.self)
            try require(list.skipped == 0 && list.elements.count <= startMenuLimit)
            try require(list.elements.allSatisfy { $0.title.utf8.count <= textLimit && isShort($0.action) })

        case SettingsSchema.symbolsKey:
            _ = try decoded([String: String].self)

        case schema.keyBindingsKey:
            _ = try decoded([String: [String]].self)

        case SettingsSchema.connectionsKey:
            try require(object is [[String: Any]])

        default:
            if SettingsSchema.tabKeys.contains(key) { _ = try decoded(PanelTabs.State.self) }
        }
    }
}

/// What an import would do, worked out before anything is stored, so that the user can be
/// shown it and asked.
internal struct SettingsImportPlan {
    /// One part that needs the user's own word.
    internal struct Part {
        internal let group: SettingsSchema.Group
        /// What the checkbox says.
        internal let title: String
        /// What the part holds, line by line.
        internal let lines: [String]
        internal var keys: [String]
    }

    /// Ordinary settings: stored when the user confirms the import.
    internal var ordinary: [String: Data] = [:]
    /// Ordinary settings the program has and the file has not: removed, so that the import
    /// brings back the state of the export and not a mixture.
    internal var removed: [String] = []
    /// How many of the ordinary settings differ from what is stored now, and some of their names.
    internal var changed: [String] = []
    internal var parts: [Part] = []
    /// The values of the parts, already made harmless.
    internal var guarded: [String: Data] = [:]
    internal var unknown: [String] = []
    internal var limited = 0

    internal var isEmpty: Bool { changed.isEmpty && removed.isEmpty && parts.isEmpty }

    /// `current` is what is stored now under every key of the file and of `knownKeys`.
    internal init(_ checked: CheckedSettings, current: [String: Data], knownKeys: [String], schema: SettingsSchema) {
        unknown = checked.unknown
        limited = checked.limited
        func same(_ key: String, _ object: Any) -> Bool {
            guard let data = current[key],
                let stored = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            else { return false }
            return (stored as AnyObject).isEqual(object)
        }
        var grouped: [SettingsSchema.Group: [String]] = [:]
        var objects = checked.objects
        var values = checked.values

        // A connection keeps its number only when nothing of it differs from the one stored
        // under that number: the password in the keychain is found by the number alone, and
        // must never go to another server because a file reused it.
        if let imported = objects[SettingsSchema.connectionsKey] as? [[String: Any]] {
            let stored =
                (current[SettingsSchema.connectionsKey].flatMap { try? JSONSerialization.jsonObject(with: $0) }
                    as? [[String: Any]]) ?? []
            var renumbered: [String: String] = [:]
            let fresh = imported.map { connection -> [String: Any] in
                guard let id = connection["id"] as? String else {
                    return connection
                }
                if stored.contains(where: { ($0 as NSDictionary).isEqual(to: connection) }) {
                    return connection
                }
                var connection = connection
                let new = UUID().uuidString
                renumbered[id.uppercased()] = new
                connection["id"] = new
                return connection
            }
            objects[SettingsSchema.connectionsKey] = fresh
            values[SettingsSchema.connectionsKey] = try? JSONSerialization.data(
                withJSONObject: fresh,
                options: [.sortedKeys]
            )
            if let last = objects[SettingsSchema.lastConnectionKey] as? String, let new = renumbered[last.uppercased()]
            {
                objects[SettingsSchema.lastConnectionKey] = new
                values[SettingsSchema.lastConnectionKey] = try? JSONSerialization.data(
                    withJSONObject: new,
                    options: [.fragmentsAllowed]
                )
            }
        }

        // (The values and the objects have the same keys.)
        for (key, object) in objects {
            let isSame = same(key, object)
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
        // What an export leaves out by default is not removed for being absent, and neither
        // is anything the user is asked about separately.
        removed =
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

    private static func part(_ group: SettingsSchema.Group, keys: [String], objects: [String: Any]) -> Part {
        func show(_ text: Any?) -> String { DisplayText.oneLine(text as? String ?? "", limit: 300) }
        var lines: [String] = []
        let title: String
        switch group {
        case .commands:
            for key in keys {
                for entry in value(objects[key], or: [[String: Any]]()) {
                    let action = entry["action"] as? [String: Any] ?? [:]
                    let name =
                        key == SettingsSchema.userCommandsKey
                        ? show(entry["name"]) : "Start menu “\(show(entry["title"]))”"
                    guard show(entry["title"]) != "-" || key == SettingsSchema.userCommandsKey else { continue }
                    var line = "\(name):  \(show(action["command"]))"
                    if !show(action["parameters"]).isEmpty { line += "   parameters: \(show(action["parameters"]))" }
                    if !show(action["startPath"]).isEmpty { line += "   in: \(show(action["startPath"]))" }
                    lines.append(line)
                }
            }
            title = "Import the user commands and the Start menu (\(lines.count)). They run programs and shell lines."

        case .keys:
            for (command, keys) in value(objects[keys[0]], or: [String: [String]]()).sorted(by: { $0.key < $1.key }) {
                lines.append(
                    "\(DisplayText.oneLine(command, limit: 80)):  "
                        + (keys.isEmpty
                            ? "no key" : keys.map { DisplayText.oneLine($0, limit: 40) }.joined(separator: ", "))
                )
            }
            title = "Import the key bindings (\(lines.count) commands). They decide what every key does."

        case .programs:
            lines = keys.map { "\($0):  \(show(objects[$0]))" }
            title =
                "Import the programs and files other settings name (\(lines.count)): the editor, the terminal, files that are written."

        case .trust:
            for key in keys {
                if let hosts = objects[key] as? [String: Any] {
                    lines += hosts.keys.sorted().map { "\(key): \(DisplayText.oneLine($0, limit: 120))" }
                } else if let hosts = objects[key] as? [Any], !hosts.isEmpty {
                    // A plain list of servers (those a password may be sent to unprotected).
                    lines += hosts.map { "\(key): \(show($0))" }
                } else {
                    lines.append(key)
                }
            }
            title =
                "Import what is trusted of servers (\(lines.count)): certificates accepted for good, and servers a password may be sent to "
                + "without protection. Such a server is connected to, or sent the password, without a question."

        case .connections:
            for connection in value(objects[SettingsSchema.connectionsKey], or: [[String: Any]]()) {
                lines.append("\(show(connection["name"])):  \(show(connection["user"]))@\(show(connection["host"]))")
            }
            title =
                "Import the saved connections (\(lines.count)). Their passwords are not in the file and are asked for again."

        case .hotlist:
            func walk(_ object: Any) {
                if let list = object as? [Any] {
                    list.forEach(walk)
                    return
                }
                guard let entry = object as? [String: Any] else {
                    return
                }
                if let command = entry["command"] as? String, !command.isEmpty {
                    lines.append("\(show(entry["title"] ?? entry["name"])):  \(show(command))")
                }
                entry.values.forEach { if $0 is [Any] || $0 is [String: Any] { walk($0) } }
            }
            keys.forEach { walk(objects[$0] as Any) }
            title = "Import the directory hotlist (\(lines.count) entries). An entry can run a command of the program."

        case .tabs:
            for key in keys {
                for tab in value((objects[key] as? [String: Any])?["tabs"], or: [[String: Any]]()) {
                    let location = show(tab["location"])
                    if !location.lowercased().hasPrefix("file:") { lines.append("\(key):  \(location)") }
                }
            }
            title =
                "Import the panels' tabs. \(lines.count) of them are on servers, which the program then connects to."
        }
        let shownLimit = 200
        if lines.count > shownLimit {
            lines = Array(lines.prefix(shownLimit)) + ["… and \(lines.count - shownLimit) more"]
        }
        return Part(group: group, title: title, lines: lines, keys: keys)
    }

    /// What the user is told before the import, apart from the parts that are asked about.
    internal func summary(fileName: String) -> String {
        func listed(_ keys: [String]) -> String {
            let shown = keys.prefix(12).map { DisplayText.oneLine($0, limit: 60) }.joined(separator: ", ")
            return keys.count > 12 ? shown + ", … (\(keys.count - 12) more)" : shown
        }
        var lines = [
            "“\(DisplayText.oneLine(fileName, limit: 120))” holds \(ordinary.count + guarded.count) settings the program knows."
        ]
        lines.append(
            changed.isEmpty
                ? "None of the ordinary settings differs from the present ones."
                : "\(changed.count) ordinary settings differ from the present ones and are replaced: \(listed(changed))."
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

/// What an export holds.
internal struct SettingsExportOptions: Equatable {
    /// Typed command lines, visited folders, search texts.
    internal var includesHistory = false
    /// Saved connections (servers and user names) and the certificates trusted for them.
    internal var includesConnections = false

    internal static let historyNote = "typed command lines, visited folders, search texts and other histories"
    internal static let connectionsNote = "saved connections (servers and user names) and trusted certificates"

    /// The keys of `keys` that go into the file.
    internal func included(_ keys: [String], schema: SettingsSchema) -> [String] {
        keys.filter { key in
            if schema.isBackup(key) {
                return false
            }
            if schema.isConnectionData(key) {
                return includesConnections
            }
            if schema.isHistory(key) {
                return includesHistory
            }
            return true
        }
    }

    /// What is told about the file, before or after it is written.
    internal func description(count: Int) -> String {
        var left: [String] = []
        if !includesHistory { left.append(Self.historyNote) }
        if !includesConnections { left.append(Self.connectionsNote) }
        var text =
            "The file holds \(count) settings: the options of all pages, the key bindings, the button bar, the user commands, the Start menu, "
            + "the directory hotlist and the panels' tabs. Passwords are never in it. Only you can read the file."
        if !left.isEmpty { text += "\nLeft out: " + left.joined(separator: "; ") + "." }
        return text
    }
}

extension SettingsArchive {
    /// Writes the archive so that only the user can read it, beside the file and then over
    /// it: a failure leaves an earlier file whole.
    ///
    /// Blocks: not for the main thread.
    internal func write(to url: URL) throws {
        let data = try encoded()
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
            )
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
