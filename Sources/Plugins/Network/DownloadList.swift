public import Foundation

/// The download list (spec 11 › Download list and HTTP downloads): a text file with one
/// transfer per line, written by *Add to download list* and worked through by *FTP Download
/// From List*.
///
/// A list is a script: its lines say what is copied where, and the file may come from
/// anybody. Nothing here runs a list; whoever does shows the user what it says first.
public enum DownloadList {
    /// What one line of a list asks for.
    public enum Action: Equatable, Sendable {
        /// `put:` or `copy:`: from one location to another, also from this Mac to a server.
        ///
        /// A nil target is the folder the list is run for.
        case copy(source: String, target: String?)
        /// A plain line, `source` or `source -> target`: something to fetch from a server.
        case download(source: String, target: String?)
        /// `move:`: a copy that removes its source.
        case move(source: String, target: String?)
        /// `sleep:<ms>`, kept as the pause in seconds.
        case pause(TimeInterval)
        /// A line this program does not carry out (an HTTP header, copy flags), kept to say so.
        case unsupported(String)
    }

    /// What stands between the source and the target of a line.
    public static let separator = " -> "
    /// The file name a new list gets when the user does not choose one.
    public static let defaultName = "ftplist.txt"
    /// A list file larger than this is not read.
    public static let largestFile = 4 << 20
    /// No more lines than this are carried out.
    public static let mostLines = 100_000
    /// The longest pause one line may ask for.
    public static let longestPause: TimeInterval = 60

    /// The lines of a list file.
    ///
    /// Empty lines are skipped; lines beyond `mostLines` are left out.
    public static func parse(_ text: String) -> [Action] {
        text.split(whereSeparator: \.isNewline)
            .prefix(mostLines)
            .compactMap(action(for:))
    }

    /// Whether a location can stand in a line: a line break (of any kind) in it would start a
    /// line of its own when the list is read, and the separator in a source would cut it in
    /// two.
    ///
    /// Names on a server are the server's choice, so this is checked for every line written.
    public static func canHold(source: String, target: String?) -> Bool {
        func isOneLine(_ text: String) -> Bool {
            !text.isEmpty
                && !text.unicodeScalars.contains { scalar in
                    scalar.properties.generalCategory == .control || scalar == "\u{2028}" || scalar == "\u{2029}"
                }
                && text == text.trimmingCharacters(in: .whitespaces)
        }
        guard isOneLine(source), !source.contains(separator), target.map(isOneLine) ?? true else {
            return false
        }
        // What is written must read back as the same download, not as a command of the list.
        return parse(line(source: source, target: target)) == [.download(source: source, target: target)]
    }

    /// One line for a file to fetch later.
    ///
    /// Only for what `canHold` accepts.
    public static func line(source: String, target: String?) -> String {
        target.map { source + separator + $0 } ?? source
    }

    /// What one line of a list file asks for, or nil for a blank line.
    private static func action(for rawLine: Substring) -> Action? {
        // A byte-order mark starts files written by Windows programs.
        let text = rawLine.trimmingCharacters(
            in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}"))
        )
        guard !text.isEmpty else {
            return nil
        }
        let lowered = text.lowercased()
        func body(after prefix: String) -> String {
            String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        if lowered.hasPrefix("sleep:") {
            let milliseconds = TimeInterval(body(after: "sleep:")) ?? 0
            // Not a number, below zero, or longer than anyone would wait: clamped.
            return .pause(milliseconds.isFinite ? min(longestPause, max(0, milliseconds / 1_000)) : 0)
        }
        if lowered.hasPrefix("header:") || lowered.hasPrefix("copyflags:") {
            return .unsupported(text)
        }
        if lowered.hasPrefix("move:") {
            let (source, target) = pair(body(after: "move:"))
            return source.isEmpty ? .unsupported(text) : .move(source: source, target: target)
        }
        for prefix in ["put:", "copy:"] where lowered.hasPrefix(prefix) {
            let (source, target) = pair(body(after: prefix))
            return source.isEmpty ? .unsupported(text) : .copy(source: source, target: target)
        }
        // Never an empty source: the line is trimmed, and the separator starts with a space.
        let (source, target) = pair(text)
        return .download(source: source, target: target)
    }

    /// A line cut at the separator into a source and a target, both trimmed; no separator, no target.
    private static func pair(_ text: String) -> (String, String?) {
        guard let range = text.range(of: separator) else {
            return (text, nil)
        }
        return (
            String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces),
            String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        )
    }
}
