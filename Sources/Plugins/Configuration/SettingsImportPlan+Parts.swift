import Foundation

/// The parts of an import the user is asked about: their checkbox titles and what they hold.
extension SettingsImportPlan {
    /// The part of `group` made of `keys`, with at most 200 lines of what it holds.
    internal static func part(_ group: SettingsSchema.Group, keys: [String], objects: [String: Any]) -> Part {
        var held = holdings(of: group, keys: keys, objects: objects)
        let checkbox = title(of: group, count: held.count)
        let shownLimit = 200
        if held.count > shownLimit {
            held = Array(held.prefix(shownLimit)) + ["… and \(held.count - shownLimit) more"]
        }
        return Part(group: group, title: checkbox, lines: held, keys: keys)
    }

    /// What the checkbox of a part says; `count` is the number of its lines.
    private static func title(of group: SettingsSchema.Group, count: Int) -> String {
        switch group {
        case .commands:
            "Import the user commands and the Start menu (\(count)). They run programs and shell lines."

        case .keys:
            "Import the key bindings (\(count) commands). They decide what every key does."

        case .programs:
            "Import the programs and files other settings name (\(count)): the editor, the terminal, "
                + "files that are written."

        case .trust:
            "Import what is trusted of servers (\(count)): certificates accepted for good, and servers a "
                + "password may be sent to without protection. Such a server is connected to, or sent the "
                + "password, without a question."

        case .connections:
            "Import the saved connections (\(count)). Their passwords are not in the file and are asked for again."

        case .hotlist:
            "Import the directory hotlist (\(count) entries). An entry can run a command of the program."

        case .tabs:
            "Import the panels' tabs. \(count) of them are on servers, which the program then connects to."
        }
    }

    /// What a part holds, one line per command, key binding, program, server, connection,
    /// hotlist entry or tab.
    private static func holdings(of group: SettingsSchema.Group, keys: [String], objects: [String: Any]) -> [String] {
        switch group {
        case .commands:
            commandLines(keys, objects: objects)

        case .keys:
            keyLines(objects[keys[0]])

        case .programs:
            keys.map { "\($0):  \(show(objects[$0]))" }

        case .trust:
            trustLines(keys, objects: objects)

        case .connections:
            value(objects[SettingsSchema.connectionsKey], or: [[String: Any]]())
                .map { connection in
                    "\(show(connection["name"])):  \(show(connection["user"]))@\(show(connection["host"]))"
                }

        case .hotlist:
            hotlistLines(keys, objects: objects)

        case .tabs:
            tabLines(keys, objects: objects)
        }
    }

    /// A text of the file on one line and shortened; empty for anything but a text.
    private static func show(_ text: Any?) -> String { DisplayText.oneLine(text as? String ?? "", limit: 300) }

    /// The user commands by name and the Start menu's entries by title (separators left out),
    /// with what they run.
    private static func commandLines(_ keys: [String], objects: [String: Any]) -> [String] {
        var lines: [String] = []
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
        return lines
    }

    /// Each command of the key bindings with its keys, by command name.
    private static func keyLines(_ object: Any?) -> [String] {
        value(object, or: [String: [String]]()).sorted { $0.key < $1.key }
            .map { binding in
                "\(DisplayText.oneLine(binding.key, limit: 80)):  "
                    + (binding.value.isEmpty
                        ? "no key" : binding.value.map { DisplayText.oneLine($0, limit: 40) }.joined(separator: ", "))
            }
    }

    /// The servers trusted under each key: those with an accepted certificate, those a
    /// password may be sent to unprotected, or the key alone when it holds neither.
    private static func trustLines(_ keys: [String], objects: [String: Any]) -> [String] {
        var lines: [String] = []
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
        return lines
    }

    /// The hotlist's entries that run a command, at any depth of its submenus.
    private static func hotlistLines(_ keys: [String], objects: [String: Any]) -> [String] {
        var lines: [String] = []
        for key in keys {
            collectCommands(in: objects[key] as Any, into: &lines)
        }
        return lines
    }

    /// Adds a line for every entry with a command in `object` and in the lists and
    /// dictionaries it holds.
    private static func collectCommands(in object: Any, into lines: inout [String]) {
        if let list = object as? [Any] {
            for element in list {
                collectCommands(in: element, into: &lines)
            }
            return
        }
        guard let entry = object as? [String: Any] else {
            return
        }
        if let command = entry["command"] as? String, !command.isEmpty {
            lines.append("\(show(entry["title"] ?? entry["name"])):  \(show(command))")
        }
        for inner in entry.values where inner is [Any] || inner is [String: Any] {
            collectCommands(in: inner, into: &lines)
        }
    }

    /// The panels' tabs that are on servers.
    private static func tabLines(_ keys: [String], objects: [String: Any]) -> [String] {
        var lines: [String] = []
        for key in keys {
            for tab in value((objects[key] as? [String: Any])?["tabs"], or: [[String: Any]]()) {
                let location = show(tab["location"])
                if !location.lowercased().hasPrefix("file:") { lines.append("\(key):  \(location)") }
            }
        }
        return lines
    }
}
