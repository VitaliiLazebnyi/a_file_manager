import AFMKernel
import Foundation

/// What a button, a Start-menu item or a user command does: the three fields the editors of
/// Total Commander share (spec 14 › The command language).
struct CommandAction: Codable, Equatable {
    /// A command of the program (`cm_…`, `em_…`), several of them separated by commas,
    /// `cd <path>`, or a program or shell line.
    var command = ""
    /// Parameters with placeholders (spec 18 › Button and command parameters).
    var parameters = ""
    /// The folder a program starts in; with `cd`, the folder the other panel shows.
    var startPath = ""
}

/// A command the user defined (spec 14 › User commands (`em_`)). It is registered like any
/// other command, so keys, the button bar, menus and the command line reach it by its name.
struct UserCommand: Codable, Equatable {
    static let prefix = "em_"

    /// The full name, `em_backup`.
    var name: String
    var title: String
    var action = CommandAction()
    /// A system symbol for the button bar; empty for none.
    var symbol = ""

    var id: CommandID { CommandID(rawValue: name) }
    /// What menus and lists show.
    var caption: String { title.isEmpty ? String(name.dropFirst(UserCommand.prefix.count)) : title }

    /// The name as it is stored: letters, digits and `_` after `em_`. Nil when nothing usable
    /// is left of what the user typed.
    static func name(from text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix(prefix) { text.removeFirst(prefix.count) }
        let allowed = text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
        return allowed && !text.isEmpty ? prefix + text : nil
    }
}

/// An entry of the Start menu (spec 14 › Start menu). The n-th entry runs as `cm_UserMenu<n>`.
struct StartMenuEntry: Codable, Equatable {
    /// A title of `-` makes a separator, as in Total Commander.
    var title: String
    var action = CommandAction()

    static let separator = StartMenuEntry(title: "-")
    var isSeparator: Bool { title == "-" }

    /// The name of the command that runs the entry at `index` (counted from 0).
    static func commandID(at index: Int) -> CommandID { CommandID(rawValue: "cm_UserMenu\(index + 1)") }
}

/// One thing a Command field asks for.
enum CommandStep: Equatable {
    /// A command of the program with what was written after its name.
    case perform(CommandID, parameter: String)
    /// `cd <path>`; an empty path stands for what the Parameters field holds.
    case changeDirectory(String)
    /// `cm_wait <ms>`: a pause between two commands of a chain.
    case wait(milliseconds: Int)
    /// A program or shell line, handed to whoever runs command lines.
    case external(String)
    /// Looks like a command of the program but no plugin provides it.
    case unknown(String)
}

/// Reads a Command field (spec 14 › The command language, Grammar and Rules). Pure.
///
/// Not taken over from Windows: `*`/`**` (run as administrator or as another user), subbars
/// (`.bar` files) and command numbers in place of names.
enum CommandLanguage {
    private static let internalPrefixes = ["cm_", "em_", "afm_"]

    /// The longest pause a `cm_wait` makes: a stored number may be anything.
    static let longestWait = 3_600_000

    /// `%NAME%` in a Command field is an environment variable (spec 14 › Rules). Its value is
    /// data: it stays apart from the text, so that a shell is handed it and never reads it.
    static func environmentPieces(_ text: String, _ environment: [String: String]) -> [ExpandedPiece] {
        var pieces: [ExpandedPiece] = []
        var written = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "%") {
            written += rest[..<open]
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: "%"), let value = environment[String(after[..<close])] else {
                written.append("%")
                rest = after
                continue
            }
            pieces.append(.text(written))
            pieces.append(.value(value))
            written = ""
            rest = after[after.index(after: close)...]
        }
        pieces.append(.text(written + rest))
        return ParameterExpander.trimmed(pieces)
    }

    /// The same as one readable text: each value written where it stands, as one word,
    /// whatever it holds. For commands of the program and for showing; never for a shell.
    static func expandingEnvironment(_ text: String, _ environment: [String: String]) -> String {
        ShellLine.display(environmentPieces(text, environment))
    }

    /// The steps of a Command field. `resolve` finds a registered command by its name, whatever
    /// its case. A field in which not every comma-separated item is a command of the program
    /// is one external line, commas included.
    static func steps(_ command: String, environment: [String: String] = [:], resolve: (String) -> CommandID?) -> [CommandStep] {
        let command = expandingEnvironment(command, environment).trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return [] }
        let items = ShellWords.split(command, at: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let steps = items.map { step($0, resolve: resolve) }
        return steps.contains(nil) ? [.external(command)] : steps.compactMap { $0 }
    }

    /// Nil when the item is not a command of the program.
    private static func step(_ item: String, resolve: (String) -> CommandID?) -> CommandStep? {
        let head = String(item.prefix { $0 != " " })
        let tail = String(item.dropFirst(head.count)).trimmingCharacters(in: .whitespaces)
        let lowered = head.lowercased()
        // `cd` alone takes its folder from the Parameters field.
        if lowered == "cd" { return .changeDirectory(ShellWords.unquoted(tail)) }
        if lowered == "cm_wait" { return .wait(milliseconds: min(max(0, Int(tail) ?? 0), longestWait)) }
        if let id = resolve(head) { return .perform(id, parameter: tail) }
        return internalPrefixes.contains(where: lowered.hasPrefix) ? .unknown(head) : nil
    }

    /// What a command of the program is given when a parameter is written after its name: a
    /// number is a position (`cm_SrcActivateTab 2`), a single path a location
    /// (`cm_List /etc/hosts`), anything else text. `location` turns a path into a location.
    static func argument(from parameter: String, location: (String) -> URL) -> CommandArgument {
        let text = parameter.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return .none }
        if let index = Int(text), text.allSatisfy(\.isNumber) { return .index(index) }
        let plain = ShellWords.unquoted(text)
        let isOneWord = ShellWords.split(text).count == 1
        if isOneWord, plain.hasPrefix("/") || plain.hasPrefix("~") || plain.contains("://") { return .location(location(plain)) }
        return .text(plain)
    }
}

// Stored data is read leniently: a missing key takes its default and an unknown one is ignored,
// so a field added or removed by another version never makes the whole list unreadable.
extension CommandAction {
    private enum Keys: String, CodingKey { case command, parameters, startPath }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        parameters = try container.decodeIfPresent(String.self, forKey: .parameters) ?? ""
        startPath = try container.decodeIfPresent(String.self, forKey: .startPath) ?? ""
    }
}

extension UserCommand {
    private enum Keys: String, CodingKey { case name, title, action, symbol }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        name = try container.decode(String.self, forKey: .name)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        action = try container.decodeIfPresent(CommandAction.self, forKey: .action) ?? CommandAction()
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? ""
    }
}

extension StartMenuEntry {
    private enum Keys: String, CodingKey { case title, action }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        title = try container.decode(String.self, forKey: .title)
        action = try container.decodeIfPresent(CommandAction.self, forKey: .action) ?? CommandAction()
    }
}
