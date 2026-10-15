import AFMContracts
import AFMKernel
import Foundation

/// What a line typed on the command line means (spec 02 › Executing a line).
///
/// Deciding it needs nothing but the text and the names of the registered commands.
internal enum CommandLineAction: Equatable {
    /// `cd <path>`, as the user typed the path.
    case changeDirectory(String)
    /// The name of a registered command, with what followed it as its parameter.
    case command(CommandID, CommandArgument)
    /// An empty line: Enter acts on the item under the cursor.
    case openCursorItem
    /// Anything else is for whoever runs programs (`afm_RunCommandLine`).
    case run(String)

    /// What `line` means with the commands of `commands`; main thread.
    ///
    /// A command's name is found whatever its case.
    @MainActor
    internal init(line: String, commands: CommandRegistry) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            self = .openCursorItem
            return
        }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let word = parts[0]
        let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        if word.lowercased() == "cd" {
            // `cd` alone goes home, as it does in a shell.
            self = .changeDirectory(rest.isEmpty ? "~" : Self.unquoted(rest))
        } else if let command = commands[CommandID(rawValue: word)]
            ?? commands.all.first(where: { $0.id.rawValue.lowercased() == word.lowercased() })
        {
            self = .command(command.id, Self.argument(from: rest))
        } else {
            self = .run(trimmed)
        }
    }

    /// A path in quotes, as needed elsewhere for names with spaces, is taken without them.
    internal static func unquoted(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" else {
            return text
        }
        return String(text.dropFirst().dropLast())
    }

    /// A command's parameter (spec 17 › Parameters): a number is a position, other text is text.
    internal static func argument(from text: String) -> CommandArgument {
        if text.isEmpty {
            return .nothing
        }
        if let number = Int(text) {
            return .index(number)
        }
        return .text(unquoted(text))
    }

    /// A file name as it has to be written on the line: in quotes when it contains a space.
    internal static func quoted(_ name: String) -> String {
        name.contains(" ") ? "\"\(name)\"" : name
    }

    /// `line` with `text` added at its end, set off by a space (Ctrl+Enter, Ctrl+P).
    internal static func appending(_ text: String, to line: String) -> String {
        line.isEmpty || line.hasSuffix(" ") ? line + text : line + " " + text
    }
}
