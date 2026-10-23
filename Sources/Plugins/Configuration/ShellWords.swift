import Foundation

/// Quoting for reading and showing a command line.
///
/// Total Commander quotes names that contain a space; here everything a shell would read as
/// something else is quoted too. Everything works on Unicode scalars: a quote followed by a
/// combining mark is still a quote to a shell.
internal enum ShellWords {
    /// What may stand in a word without quotes.
    private static let plain = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789%+,-./:@_^"
    )
    /// What a backslash must stand in front of between double quotes.
    private static let quoteSpecial = CharacterSet(charactersIn: "\"\\$`")

    /// Whether a shell would read the text as something else than one plain word.
    ///
    /// Letters and digits of every script are plain; any other character outside ASCII is not.
    internal static func needsQuoting(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            if scalar.isASCII {
                return !plain.contains(scalar)
            }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .nonspacingMark,
                .spacingMark, .decimalNumber:
                return false

            default:
                return true
            }
        }
    }

    /// The text as it must be written between double quotes.
    internal static func escaped(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if quoteSpecial.contains(scalar) { result.append("\\") }
            result.append(scalar)
        }
        return String(result)
    }

    /// The text between double quotes, escaped where it must be.
    internal static func quoted(_ text: String) -> String { "\"" + escaped(text) + "\"" }

    /// The text as it must be written between single quotes.
    internal static func singleQuoteEscaped(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "'" { result.append(contentsOf: "'\\''".unicodeScalars) } else { result.append(scalar) }
        }
        return String(result)
    }

    /// The words of a line, between blanks; double quotes keep a word with spaces together and
    /// stay part of it.
    internal static func split(_ line: String) -> [String] {
        split(line, at: " ")
    }

    /// The parts of a line between the separators outside double quotes, which stay part of them.
    ///
    /// A blank as the separator drops empty parts (several blanks in a row); any other keeps them.
    internal static func split(_ line: String, at separator: Unicode.Scalar) -> [String] {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        var inQuotes = false
        var isEscaped = false
        for scalar in line.unicodeScalars {
            if isEscaped {
                isEscaped = false
            } else if scalar == "\\", inQuotes {
                isEscaped = true
            } else if scalar == "\"" {
                inQuotes.toggle()
            } else if scalar == separator, !inQuotes {
                if !current.isEmpty || separator != " " { words.append(String(current)) }
                current = String.UnicodeScalarView()
                continue
            }
            current.append(scalar)
        }
        if !current.isEmpty || (separator != " " && !words.isEmpty) { words.append(String(current)) }
        return words
    }

    /// The same for an expanded text: a value never ends a word, whatever it holds.
    internal static func split(_ pieces: [ExpandedPiece]) -> [[ExpandedPiece]] {
        var words: [[ExpandedPiece]] = []
        var current: [ExpandedPiece] = []
        var text = String.UnicodeScalarView()
        var inQuotes = false
        var isEscaped = false
        func flush() {
            if !text.isEmpty { current.append(.text(String(text))) }
            text = String.UnicodeScalarView()
        }
        for piece in pieces {
            guard case .text(let written) = piece else {
                flush()
                current.append(piece)
                isEscaped = false
                continue
            }
            for scalar in written.unicodeScalars {
                if isEscaped {
                    isEscaped = false
                } else if scalar == "\\", inQuotes {
                    isEscaped = true
                } else if scalar == "\"" {
                    inQuotes.toggle()
                } else if scalar == " ", !inQuotes {
                    flush()
                    if !current.isEmpty { words.append(current) }
                    current = []
                    continue
                }
                text.append(scalar)
            }
        }
        flush()
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// The first word of an expanded line and what follows it, blanks included.
    internal static func firstWord(of pieces: [ExpandedPiece]) -> (word: [ExpandedPiece], rest: [ExpandedPiece]) {
        var word: [ExpandedPiece] = []
        var inQuotes = false
        var isEscaped = false
        for (index, piece) in pieces.enumerated() {
            guard case .text(let written) = piece else {
                word.append(piece)
                isEscaped = false
                continue
            }
            var text = String.UnicodeScalarView()
            var position = written.unicodeScalars.startIndex
            while position < written.unicodeScalars.endIndex {
                let scalar = written.unicodeScalars[position]
                if isEscaped {
                    isEscaped = false
                } else if scalar == "\\", inQuotes {
                    isEscaped = true
                } else if scalar == "\"" {
                    inQuotes.toggle()
                } else if scalar == " ", !inQuotes {
                    if text.isEmpty, word.isEmpty {
                        // Blanks in front of the word.
                        position = written.unicodeScalars.index(after: position)
                        continue
                    }
                    if !text.isEmpty { word.append(.text(String(text))) }
                    let tail = String(written.unicodeScalars[position...])
                    return (word, [.text(tail)] + pieces[(index + 1)...])
                }
                text.append(scalar)
                position = written.unicodeScalars.index(after: position)
            }
            if !text.isEmpty { word.append(.text(String(text))) }
        }
        return (word, [])
    }

    /// A word without its double quotes and their escapes: what a command inside the program
    /// is given, since no shell reads it.
    internal static func unquoted(_ word: String) -> String {
        var result = String.UnicodeScalarView()
        var inQuotes = false
        var isEscaped = false
        for scalar in word.unicodeScalars {
            if isEscaped {
                if !quoteSpecial.contains(scalar) { result.append("\\") }
                result.append(scalar)
                isEscaped = false
            } else if scalar == "\\", inQuotes {
                isEscaped = true
            } else if scalar == "\"" {
                inQuotes.toggle()
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// The same for a word of an expanded text; its values are taken as they are.
    internal static func unquoted(_ word: [ExpandedPiece]) -> String {
        word.map { piece -> String in
            switch piece {
            case .text(let text):
                return unquoted(text)

            case .value(let value), .raw(let value):
                return value
            }
        }
        .joined()
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
}
