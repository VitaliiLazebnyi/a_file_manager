import AFMContracts
import AFMKernel
import Foundation

/// What a line typed on the command line means (spec 02 › Executing a line). Deciding it
/// needs nothing but the text and the names of the registered commands.
enum CommandLineAction: Equatable {
    /// An empty line: Enter acts on the item under the cursor.
    case openCursorItem
    /// `cd <path>`, as the user typed the path.
    case changeDirectory(String)
    /// The name of a registered command, with what followed it as its parameter.
    case command(CommandID, CommandArgument)
    /// Anything else is for whoever runs programs (`afm_RunCommandLine`).
    case run(String)

    init(line: String, commands: CommandRegistry) {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else {
            self = .openCursorItem
            return
        }
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let word = parts[0], rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        if word.lowercased() == "cd" {
            // `cd` alone goes home, as it does in a shell.
            self = .changeDirectory(rest.isEmpty ? "~" : CommandLineAction.unquoted(rest))
        } else if let command = commands[CommandID(rawValue: word)] ?? commands.all.first(where: { $0.id.rawValue.lowercased() == word.lowercased() }) {
            self = .command(command.id, CommandLineAction.argument(from: rest))
        } else {
            self = .run(line)
        }
    }

    /// A path in quotes, as needed elsewhere for names with spaces, is taken without them.
    static func unquoted(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" else { return text }
        return String(text.dropFirst().dropLast())
    }

    /// A command's parameter (spec 17 › Parameters): a number is a position, other text is text.
    static func argument(from text: String) -> CommandArgument {
        if text.isEmpty { return .none }
        if let number = Int(text) { return .index(number) }
        return .text(unquoted(text))
    }

    /// A file name as it has to be written on the line: in quotes when it contains a space.
    static func quoted(_ name: String) -> String {
        name.contains(" ") ? "\"\(name)\"" : name
    }

    /// `line` with `text` added at its end, set off by a space (Ctrl+Enter, Ctrl+P).
    static func appending(_ text: String, to line: String) -> String {
        line.isEmpty || line.hasSuffix(" ") ? line + text : line + " " + text
    }
}

/// The lines the user ran, newest first (spec 02 › Limits and persistence: up to 20 entries,
/// kept between sessions). Main thread only.
///
/// A line may hold a password (`curl -u name:secret`). Two rules keep such a line out of the
/// settings, the same two the plugin that runs the lines has for its own history: a line that
/// begins with a blank is not remembered, as in a shell, and remembering can be switched off
/// altogether (`recordKey`, the plugin's switch, so there is one switch for both). Switched
/// off, what was remembered goes too.
final class CommandLineHistory {
    static let settingsKey = "window.commandLineHistory"
    /// "Remember the command lines that were run", as the command-line plugin names it.
    static let recordKey = "systemTools.recordHistory"
    static let limit = 20

    private let settings: SettingsStore
    private(set) var entries: [String]

    init(settings: SettingsStore) {
        self.settings = settings
        entries = Array((settings.value([String].self, forKey: CommandLineHistory.settingsKey) ?? []).prefix(CommandLineHistory.limit))
        forgetIfSwitchedOff()
    }

    /// Whether lines are remembered at all.
    var isRecording: Bool { settings.flag(CommandLineHistory.recordKey, default: true) }

    /// A line that is not for the history: it begins with a blank.
    static func isPrivate(_ line: String) -> Bool {
        line.unicodeScalars.first == " " || line.unicodeScalars.first == "\t"
    }

    /// Drops everything that was remembered when remembering was switched off since.
    /// Returns true when it is off.
    @discardableResult
    func forgetIfSwitchedOff() -> Bool {
        guard !isRecording else { return false }
        if !entries.isEmpty || settings.data(forKey: CommandLineHistory.settingsKey) != nil {
            entries = []
            settings.set(nil as Data?, forKey: CommandLineHistory.settingsKey)
        }
        return true
    }

    /// A line that is run again moves to the front instead of appearing twice. `line` is
    /// the line as it was typed, with the blank it may begin with.
    func add(_ line: String) {
        guard !forgetIfSwitchedOff(), !CommandLineHistory.isPrivate(line) else { return }
        let line = line.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        entries.removeAll { $0 == line }
        entries.insert(line, at: 0)
        entries = Array(entries.prefix(CommandLineHistory.limit))
        settings.set(entries, forKey: CommandLineHistory.settingsKey)
    }

    func remove(_ line: String) {
        entries.removeAll { $0 == line }
        settings.set(entries, forKey: CommandLineHistory.settingsKey)
    }
}
