import Foundation

/// A line typed on the command line, taken apart as far as the program needs to know it
/// (spec 02 › Executing a line).
///
/// The shell does the real parsing; this only finds out how the line is to be started. A value
/// without state: usable from any thread.
internal struct TypedCommand: Equatable {
    /// The PATH this process was started with.
    ///
    /// A program started from the Dock has a short one; the PATH of a terminal is
    /// `LoginShell.searchPath`.
    internal static var processPath: String { path(in: ProcessInfo.processInfo.environment) }

    /// The folders a bare application name is looked for in, in this order: the system's
    /// applications, its utilities, then those of this user.
    internal static let applicationFolders: [URL] = [
        URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"), URL(fileURLWithPath: "/Applications/Utilities"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    ]

    /// The line without surrounding blanks and without a trailing `&`.
    internal let command: String
    /// A trailing `&`: the command is started and left alone, its output is not collected.
    internal let isDetached: Bool
    /// The first word with quotes and backslash escapes resolved: the program to start.
    internal let firstWord: String
    /// What follows the first word, as typed.
    internal let arguments: String

    /// Takes `line` apart; nil for a line that is blank, or holds nothing but `&`.
    internal init?(_ line: String) {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // `&&` at the end is an unfinished line, not a request to run in the background.
        let detached = text.hasSuffix("&") && !text.hasSuffix("&&")
        if detached { text = String(text.dropLast()).trimmingCharacters(in: .whitespaces) }
        guard !text.isEmpty else {
            return nil
        }
        command = text
        isDetached = detached
        (firstWord, arguments) = Self.split(text)
    }

    /// The first word as a shell would read it (quotes group, a backslash keeps the next
    /// character), and what follows it.
    internal static func split(_ text: String) -> (word: String, rest: String) {
        var word = ""
        var quote: Character?
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                word.append(character)
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
            } else if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == " " || character == "\t" {
                break
            } else {
                word.append(character)
            }
            index = text.index(after: index)
        }
        return (word, text[index...].trimmingCharacters(in: .whitespaces))
    }

    /// A path as typed (`~/x`, `/x`, `x/y`) as a location; relative paths start at `directory`.
    internal static func location(of path: String, relativeTo directory: URL) -> URL {
        let expanded = expandingTilde(in: path)
        return (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : directory.appendingPathComponent(expanded))
            .standardizedFileURL
    }

    /// Whether an executable file of that name is in a folder of the PATH.
    internal static func isOnPath(_ name: String, path: String) -> Bool {
        path.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + name) }
    }

    /// `path` with a leading `~` or `~user` replaced by that user's home folder, as a shell reads it.
    ///
    /// A user nobody knows leaves the path as it is.
    internal static func expandingTilde(in path: String) -> String {
        guard path.hasPrefix("~") else {
            return path
        }
        let end = path.firstIndex(of: "/") ?? path.endIndex
        let user = String(path[path.index(after: path.startIndex)..<end])
        let home =
            user.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser : FileManager.default.homeDirectory(forUser: user)
        guard let home else {
            return path
        }
        return home.path + path[end...]
    }

    /// The PATH of `environment`; the system's usual one without.
    internal static func path(in environment: [String: String]) -> String {
        environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    }

    /// Where an application of that name would be, when the first word names one: a path ending
    /// in `.app`, or a bare name found in the usual application folders.
    ///
    /// Asks the disk, so it is for a background thread.
    ///
    /// A bare name (`Preview.app`) means the application of the system first: one of the same
    /// name that lies in the panel's folder (a downloaded folder, a memory stick) is opened
    /// only when no installed one has the name, or when it is asked for by path (`./Preview.app`).
    /// `path` is the PATH that decides whether a bare name is a program instead.
    internal func application(
        relativeTo directory: URL,
        searching folders: [URL],
        path: String
    ) -> URL? {
        let files = FileManager.default
        func bundle(at url: URL) -> URL? {
            var isDirectory: ObjCBool = false
            return files.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? url : nil
        }
        if firstWord.lowercased().hasSuffix(".app") {
            let here = Self.location(of: firstWord, relativeTo: directory)
            if firstWord.contains("/") || firstWord.hasPrefix("~") {
                return bundle(at: here)
            }
            return folders.lazy.compactMap { bundle(at: $0.appendingPathComponent(firstWord)) }.first
                ?? bundle(at: here)
        }
        // A bare name is an application only when nothing else is asked of it; `open -a` and
        // the like stay with the shell.
        guard arguments.isEmpty, !firstWord.contains("/"), !firstWord.isEmpty else {
            return nil
        }
        // A program of that name on the PATH wins: on a case-insensitive disk `mail` would
        // otherwise open Mail.app instead of /usr/bin/mail.
        if Self.isOnPath(firstWord, path: path) {
            return nil
        }
        return folders.lazy.compactMap { bundle(at: $0.appendingPathComponent(firstWord + ".app")) }.first
    }
}
