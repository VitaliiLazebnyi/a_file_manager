import AFMKernel
import Foundation

/// The command list of the *Choose command* dialog, the keyboard page and the keyboard help
/// (spec 14 › The Choose command dialog).
///
/// The categories are the menus the commands are in, since that is where the user knows them from.
internal enum CommandCatalog {
    /// One row per command, in the commands' order, with the keys `shortcuts` gives it and the
    /// first menu it is in.
    internal static func rows(commands: [Command], menus: [MenuRegistry.Menu], shortcuts: (CommandID) -> [Shortcut])
        -> [CommandRow]
    {
        var menuOf: [CommandID: String] = [:]
        for menu in menus {
            for case let id? in menu.items where menuOf[id] == nil { menuOf[id] = menu.title }
        }
        return commands.map { command in
            let isUser = command.id.rawValue.hasPrefix(UserCommand.prefix)
            return CommandRow(
                id: command.id,
                title: command.title,
                keys: ShortcutText.display(shortcuts(command.id)),
                category: isUser ? CommandRow.userCategory : menuOf[command.id] ?? CommandRow.otherCategory
            )
        }
    }

    /// The categories in menu order, the two general groups last.
    internal static func categories(of rows: [CommandRow], menus: [MenuRegistry.Menu]) -> [String] {
        let present = Set(rows.map(\.category))
        return (menus.map(\.title) + [CommandRow.userCategory, CommandRow.otherCategory]).filter(present.contains)
    }

    /// The rows of a category (nil = all) that contain every word of the filter in their
    /// name, title or keys.
    internal static func filter(_ rows: [CommandRow], text: String, category: String?) -> [CommandRow] {
        let words = text.lowercased().split(separator: " ")
        return rows.filter { row in
            guard category == nil || row.category == category else {
                return false
            }
            let haystack = (row.id.rawValue + " " + row.title + " " + row.keys).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// The keyboard help: every command that has a key, grouped by menu (spec 17 › Help,
    /// `cm_Keyboard`), generated from the bindings in force.
    internal static func shortcutSheet(_ rows: [CommandRow], menus: [MenuRegistry.Menu]) -> String {
        var text = ""
        for category in categories(of: rows, menus: menus) {
            let bound = rows.filter { $0.category == category && !$0.keys.isEmpty }
            guard !bound.isEmpty else { continue }
            text += category + "\n"
            for row in bound {
                text +=
                    "    " + row.keys.padding(toLength: max(22, row.keys.count + 2), withPad: " ", startingAt: 0)
                    + row.title.replacingOccurrences(of: "…", with: "") + "\n"
            }
            text += "\n"
        }
        return text
    }
}
