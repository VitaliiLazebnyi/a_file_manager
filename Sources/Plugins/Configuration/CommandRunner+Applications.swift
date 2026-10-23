import Foundation

/// Lines whose program is an application, which are opened with `open`.
extension CommandRunner {
    /// Where applications are looked for by their bare name.
    nonisolated private static let applicationFolders: [URL] = [
        "/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
        NSHomeDirectory() + "/Applications"
    ]
    .map { URL(fileURLWithPath: $0) }

    /// The line as it is started: one whose program is an application (`Safari.app`, or the bare
    /// name of an installed application) is opened with `open`, any other line stays as it is.
    ///
    /// For a bare name the shell decides: a program of that name on the user's PATH, which only
    /// the login shell knows, comes first. Asks the disk: background only.
    nonisolated internal static func startLine(for line: [ExpandedPiece]) -> [ExpandedPiece] {
        // The first word as a whole, also when it is quoted and has a space in it.
        let (word, rest) = ShellWords.firstWord(of: line)
        let first = ShellWords.unquoted(word)
        guard !first.isEmpty, first.unicodeScalars.first != "-" else {
            return line
        }
        let manager = FileManager.default
        if first.lowercased().hasSuffix(".app") {
            let path = ShellWords.expandingTilde(in: first)
            let exists =
                first.contains("/")
                ? manager.fileExists(atPath: path)
                : applicationFolders.contains { manager.fileExists(atPath: $0.appendingPathComponent(first).path) }
            return exists ? [.text("/usr/bin/open -a "), .value(path)] + rest : line
        }
        let isAlone = rest.allSatisfy { piece in
            if case .text(let text) = piece {
                return text.unicodeScalars.allSatisfy { $0 == " " || $0 == "\t" }
            }
            return false
        }
        guard isAlone, !first.contains("/") else {
            return line
        }
        let installed = applicationFolders.contains { folder in
            manager.fileExists(atPath: folder.appendingPathComponent(first + ".app").path)
        }
        guard installed else {
            return line
        }
        return [.text("if command -v "), .value(first), .text(" >/dev/null 2>&1\nthen ")] + line
            + [.text("\nelse /usr/bin/open -a "), .value(first), .text("\nfi")]
    }

    /// The line an application is opened with, for a line as text, as text; nil for a line that
    /// is no application.
    nonisolated internal static func applicationLine(for line: String) -> String? {
        let started = startLine(for: [.text(line)])
        return started == [.text(line)] ? nil : ShellLine.display(started)
    }
}
