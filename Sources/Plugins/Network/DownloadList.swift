public import Foundation

/// The download list (spec 11 › Download list and HTTP downloads): a text file with one
/// transfer per line, written by *Add to download list* and worked through by *FTP Download
/// From List*.
///
/// A list is a script: its lines say what is copied where, and the file may come from
/// anybody. Nothing here runs a list; whoever does shows the user what it says first.
public enum DownloadList {
    public enum Action: Equatable, Sendable {
        /// A plain line, `source` or `source -> target`: something to fetch from a server.
        case download(source: String, target: String?)
        /// `put:` or `copy:`: from one location to another, also from this Mac to a server.
        /// A nil target is the folder the list is run for.
        case copy(source: String, target: String?)
        /// `move:`: a copy that removes its source.
        case move(source: String, target: String?)
        /// `sleep:<ms>`
        case pause(TimeInterval)
        /// A line this program does not carry out (an HTTP header, copy flags), kept to say so.
        case unsupported(String)
    }

    public static let separator = " -> "
    public static let defaultName = "ftplist.txt"
    /// A list file larger than this is not read, and no more lines than this are carried out.
    public static let largestFile = 4 << 20
    public static let mostLines = 100_000
    /// The longest pause one line may ask for.
    public static let longestPause: TimeInterval = 60

    /// The lines of a list file. Empty lines are skipped; lines beyond `mostLines` are left out.
    public static func parse(_ text: String) -> [Action] {
        text.split(whereSeparator: \.isNewline).prefix(mostLines).compactMap { rawLine in
            // A byte-order mark starts files written by Windows programs.
            let line = rawLine.trimmingCharacters(
                in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
            guard !line.isEmpty else { return nil }
            let lowered = line.lowercased()
            func body(after prefix: String) -> String {
                String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            func pair(_ text: String) -> (String, String?) {
                guard let range = text.range(of: separator) else { return (text, nil) }
                return (
                    String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces),
                    String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                )
            }
            if lowered.hasPrefix("sleep:") {
                let milliseconds = TimeInterval(body(after: "sleep:")) ?? 0
                // Not a number, below zero, or longer than anyone would wait: clamped.
                return .pause(milliseconds.isFinite ? min(longestPause, max(0, milliseconds / 1_000)) : 0)
            }
            if lowered.hasPrefix("header:") || lowered.hasPrefix("copyflags:") { return .unsupported(line) }
            if lowered.hasPrefix("move:") {
                let (source, target) = pair(body(after: "move:"))
                return source.isEmpty ? .unsupported(line) : .move(source: source, target: target)
            }
            for prefix in ["put:", "copy:"] where lowered.hasPrefix(prefix) {
                let (source, target) = pair(body(after: prefix))
                return source.isEmpty ? .unsupported(line) : .copy(source: source, target: target)
            }
            let (source, target) = pair(line)
            return source.isEmpty ? .unsupported(line) : .download(source: source, target: target)
        }
    }

    /// Whether a location can stand in a line: a line break (of any kind) in it would start a
    /// line of its own when the list is read, and the separator in a source would cut it in
    /// two. Names on a server are the server's choice, so this is checked for every line written.
    public static func canHold(source: String, target: String?) -> Bool {
        func isOneLine(_ text: String) -> Bool {
            !text.isEmpty
                && !text.unicodeScalars.contains {
                    $0.properties.generalCategory == .control || $0 == "\u{2028}" || $0 == "\u{2029}"
                }
                && text == text.trimmingCharacters(in: .whitespaces)
        }
        guard isOneLine(source), !source.contains(separator), target.map(isOneLine) ?? true else { return false }
        // What is written must read back as the same download, not as a command of the list.
        return parse(line(source: source, target: target)) == [.download(source: source, target: target)]
    }

    /// One line for a file to fetch later. Only for what `canHold` accepts.
    public static func line(source: String, target: String?) -> String {
        target.map { source + separator + $0 } ?? source
    }
}
