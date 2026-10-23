import Foundation

/// The conversions of the Upper/lowercase box and of the case switches `[U] [L] [F] [f] [n]`
/// (spec 09 › Upper/lowercase).
///
/// Stored by its number in saved settings; `allCases` is the order of the menu.
internal enum LetterCase: Int, Codable, CaseIterable {
    /// "First letter uppercase".
    case firstUpper = 3
    /// "All lowercase".
    case lower = 1
    /// "First of each word uppercase (English in Titles)".
    case titleWords = 5
    /// "Unchanged".
    case unchanged = 0
    /// "All UPPERCASE".
    case upper = 2
    /// "First of each word uppercase".
    case words = 4

    /// The conversions in the order of the menu, which is the order of their numbers.
    internal static let allCases: [Self] = [.unchanged, .lower, .upper, .firstUpper, .words, .titleWords]

    /// The characters after which a new word starts, besides white space.
    ///
    /// A dot is not among them, so an extension stays in lower case.
    private static let wordBreaks: Set<Character> = ["/", "\\", "-", "_", "(", "[", "{", ",", ";", "+", "&"]

    /// The title in the menu.
    internal var title: String {
        switch self {
        case .unchanged:
            return "Unchanged"

        case .lower:
            return "All lowercase"

        case .upper:
            return "All UPPERCASE"

        case .firstUpper:
            return "First letter uppercase"

        case .words:
            return "First of each word uppercase"

        case .titleWords:
            return "First of each word uppercase (English in Titles)"
        }
    }

    private static func capitalizingWords(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var startsWord = true
        for character in text {
            if character.isLetter || character.isNumber {
                result += startsWord ? character.uppercased() : character.lowercased()
                startsWord = false
            } else {
                result.append(character)
                if character.isWhitespace || wordBreaks.contains(character) {
                    startsWord = true
                }
            }
        }
        return result
    }

    /// `text` converted, the words of titles kept in lower case by the standard rule.
    internal func apply(to text: String) -> String {
        apply(to: text, rule: .standard)
    }

    /// `text` converted; `rule` says which words titles keep in lower case.
    internal func apply(to text: String, rule: TitleCaseRule) -> String {
        switch self {
        case .unchanged:
            return text

        case .lower:
            return text.lowercased()

        case .upper:
            return text.uppercased()

        case .firstUpper:
            guard let first = text.firstIndex(where: { $0.isLetter || $0.isNumber }) else {
                return text
            }
            return String(text[..<first]) + text[first...first].uppercased()
                + text[text.index(after: first)...].lowercased()

        case .words:
            return Self.capitalizingWords(text)

        case .titleWords:
            var words =
                Self.capitalizingWords(text)
                .split(separator: " ", omittingEmptySubsequences: false)
                .map(String.init)
            let real = words.indices.filter { !words[$0].isEmpty }
            for index in real.dropFirst() where index != real.last || rule.allowsLowercaseLastWord {
                let core = words[index].trimmingCharacters(in: CharacterSet.letters.inverted)
                if rule.words.contains(core.lowercased()) {
                    words[index] = words[index].lowercased()
                }
            }
            return words.joined(separator: " ")
        }
    }
}
