public import AFMKernel
import Foundation

/// What the command of a hotlist entry asks for (spec 12 › Command and target path).
public enum HotlistAction: Equatable {
    /// `cd <path>`. With `focusingOnIt` (the path ended in `/:`), the parent is shown with the
    /// cursor on the named folder.
    case changeDirectory(path: String, focusingOnIt: Bool)
    /// The name of a command (`cm_…`, `afm_…` or a user command `em_…`), with what followed it as its argument.
    case command(CommandID, CommandArgument)
    /// An empty command: choosing the entry does nothing.
    case nothing

    /// Reads what a command field holds: a command name, `cd <path>` or a bare path, or nothing.
    public init(_ command: String) {
        let text = command.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            self = .nothing
        } else if ["cm_", "afm_", "em_"].contains(where: text.lowercased().hasPrefix) {
            let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            self = .command(
                CommandID(rawValue: parts[0]),
                argument.isEmpty ? .nothing : Int(argument).map(CommandArgument.index) ?? .text(argument)
            )
        } else {
            // A bare path is taken as `cd <path>`.
            var path =
                text.lowercased().hasPrefix("cd ")
                ? String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces) : text
            // A quoted path is the path as it stands: spaces at its ends and a final `:` are its own.
            var isQuoted = false
            if path.count > 1, path.hasPrefix("\""), path.hasSuffix("\"") {
                path = String(path.dropFirst().dropLast())
                isQuoted = true
            }
            if !isQuoted, let suffix = ["//:", "/:", "\\\\:", "\\:"].first(where: path.hasSuffix),
                path.count > suffix.count
            {
                self = .changeDirectory(path: String(path.dropLast(suffix.count)), focusingOnIt: true)
            } else {
                self = .changeDirectory(path: path, focusingOnIt: false)
            }
        }
    }

    /// The command that changes to `path`: `cd <path>`, with the path in quotes when it would be
    /// read differently as it stands (spaces at its ends, a final colon, quotes around it).
    public static func changeDirectoryCommand(to path: String) -> String {
        let edge = { (character: Character?) in character.map { $0.isWhitespace || $0 == ":" || $0 == "\"" } ?? false }
        let needsQuotes = edge(path.first) || edge(path.last)
        return "cd " + (needsQuotes ? "\"" + path + "\"" : path)
    }

    /// The path of a target-path field, which may be written plain or as `cd path`.
    public static func targetPath(_ text: String) -> String? {
        guard case .changeDirectory(let path, _) = Self(text), !path.isEmpty else {
            return nil
        }
        return path
    }
}
