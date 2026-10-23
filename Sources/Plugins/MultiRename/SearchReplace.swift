import Foundation

/// Search & Replace of the Multi-Rename Tool (spec 18 › Search & Replace in the Multi-Rename
/// Tool).
///
/// Compiled once per preview and then used from several threads.
///
/// A regular expression the user typed is run with a bound on its time and ends when the work
/// is cancelled (`RenameRegex`); the plain search with `*` and `?` is matched by hand
/// (`WildcardMatcher`), in time proportional to the name times the mask.
internal struct SearchReplace {
    /// Why Search & Replace cannot be used.
    internal enum Problem: Error, Equatable {
        /// The search is to be a regular expression and is not one.
        case invalidExpression(String)
        /// A regular expression that takes too long for the names of the list.
        case tooSlow(String)
    }

    /// A piece of a regular-expression replacement: text, or a group in a letter case.
    private enum Part {
        case group(Int, LetterCase)
        case text(String)
    }

    private enum Finder {
        case regex(NSRegularExpression)
        case wildcard(WildcardMatcher)
    }

    private struct Pair {
        let finder: Finder
        let replacement: [Part]
    }

    /// The text searched for, as typed.
    internal let search: String
    private let pairs: [Pair]
    private let firstOnly: Bool
    private let substitute: Bool
    /// Counts the names a regular expression ran out of time on.
    private let guardian = RenameRegexGuard()

    /// Whether the regular expression took too long for some names: those got no new name.
    internal var timedOut: Bool { guardian.hasTimedOut }

    /// The search and replacement of `settings`; throws `Problem.invalidExpression` for a regular
    /// expression the system cannot read.
    internal init(_ settings: RenameSettings) throws {
        firstOnly = settings.firstOnly
        substitute = settings.regularExpression && settings.substitute
        search = settings.search
        let options: NSRegularExpression.Options = settings.caseSensitive ? [] : [.caseInsensitive]
        guard !settings.search.isEmpty else {
            pairs = []
            return
        }
        if settings.regularExpression {
            let pattern = Self.systemPattern(settings.search)
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
                throw Problem.invalidExpression(settings.search)
            }
            pairs = [
                Pair(
                    finder: .regex(expression),
                    replacement: Self.template(
                        settings.replacement,
                        groups: expression.numberOfCaptureGroups
                    )
                )
            ]
        } else {
            // Several pairs are separated by `|` in both fields and matched up by position.
            let searches = settings.search.components(separatedBy: "|")
            let replacements = settings.replacement.components(separatedBy: "|")
            pairs = searches.enumerated()
                .compactMap { index, search in
                    guard !search.isEmpty else {
                        return nil
                    }
                    return Pair(
                        finder: .wildcard(WildcardMatcher(search, caseSensitive: settings.caseSensitive)),
                        replacement: [.text(replacements.indices.contains(index) ? replacements[index] : "")]
                    )
                }
        }
    }

    /// The regular expression that means what the plain search means: `*` stands for any run
    /// of characters and `?` for one.
    ///
    /// A run is as short as possible, except at the end of the text searched for, where it takes
    /// the rest of the name. A `*` in front starts at the beginning of the name: `*x` is everything
    /// up to and including the first x, once. **Not used for matching**: made of many stars it
    /// takes time that grows with the power of their number; `WildcardMatcher` finds the same
    /// matches by hand. This is its definition, which the tests compare it with.
    internal static func wildcardPattern(_ search: String) -> String {
        let characters = Array(search)
        return characters.enumerated()
            .map { index, character -> String in
                switch character {
                case "*":
                    return index == characters.count - 1 ? ".*" : index == 0 ? "^.*?" : ".*?"

                case "?":
                    return "."

                default:
                    return NSRegularExpression.escapedPattern(for: String(character))
                }
            }
            .joined()
    }

    /// Turns the spec's dialect (18 › Regular expressions, the TRegExpr library) into the
    /// system's: named groups are written differently, the greedy switch does not exist.
    ///
    /// Subroutine calls `(?1)` and recursion `(?R)` have no counterpart; such an expression is
    /// reported as invalid.
    internal static func systemPattern(_ pattern: String) -> String {
        var system = pattern
        for (spec, replacement) in [("(?P<", "(?<"), ("(?g)", ""), ("(?-g)", "")] {
            system = system.replacingOccurrences(of: spec, with: replacement)
        }
        // `(?P=name)` is `\k<name>`, `(?'name'` is `(?<name>`.
        system = system.replacing(#/\(\?P=(\w+)\)/#) { "\\k<" + $0.1 + ">" }
        system = system.replacing(#/\(\?'(\w+)'/#) { "(?<" + $0.1 + ">" }
        // The pattern the spec singles out as rewritten to avoid a crash.
        if system.hasPrefix("^??") {
            system = "^?" + system.dropFirst(3)
        }
        return system
    }

    /// Reads "Replace with" of a regular expression: `$1`…`$89` are groups, and `\U`, `\L`,
    /// `\F`, `\n` directly before one convert that group only.
    private static func template(_ text: String, groups: Int) -> [Part] {
        var parts: [Part] = []
        var literal = ""
        var pending = LetterCase.unchanged
        let characters = Array(text)
        var position = 0
        // The value of the digit at `index`; nil where there is none.
        func digit(_ index: Int) -> Int? {
            guard characters.indices.contains(index), characters[index].isASCII else {
                return nil
            }
            return characters[index].wholeNumberValue
        }
        while position < characters.count {
            let character = characters[position]
            if character == "\\", position + 1 < characters.count {
                let next = characters[position + 1]
                let cases: [Character: LetterCase] = ["U": .upper, "L": .lower, "F": .words, "n": .unchanged]
                if let letterCase = cases[next], position + 2 < characters.count, characters[position + 2] == "$",
                    digit(position + 3) != nil
                {
                    pending = letterCase
                } else {
                    literal.append(next)
                }
                position += 2
            } else if character == "$", let first = digit(position + 1) {
                var number = first
                var length = 2
                if let second = digit(position + 2), first * 10 + second <= groups {
                    number = first * 10 + second
                    length = 3
                }
                if !literal.isEmpty {
                    parts.append(.text(literal))
                }
                literal = ""
                parts.append(.group(number, pending))
                pending = .unchanged
                position += length
            } else {
                literal.append(character)
                position += 1
            }
        }
        if !literal.isEmpty {
            parts.append(.text(literal))
        }
        return parts
    }

    /// The UTF-16 range `range` of `text`.
    private static func piece(of text: String, _ range: NSRange) -> String {
        let start = text.utf16.index(text.utf16.startIndex, offsetBy: range.location)
        let end = text.utf16.index(start, offsetBy: range.length)
        return String(text[start..<end])
    }

    /// `text` from the UTF-16 offset `location` on.
    private static func rest(of text: String, from location: Int) -> String {
        String(text[text.utf16.index(text.utf16.startIndex, offsetBy: location)...])
    }

    /// The name after the replacements; a name the regular expression takes too long for is
    /// left as it is (use `replacing` to know).
    internal func apply(to text: String) -> String {
        replacing(in: text) { false } ?? text
    }

    /// The name after the replacements, or nil when the regular expression ran out of time or
    /// the work was cancelled: the preview then shows `<Error!>`.
    internal func replacing(in text: String, cancelled: () -> Bool) -> String? {
        var result = text
        for pair in pairs {
            let replaced: String?
            switch pair.finder {
            case .regex(let expression):
                replaced = replacing(expression, with: pair.replacement, in: result, cancelled: cancelled)

            case .wildcard(let matcher):
                replaced = replacing(matcher, with: pair.replacement, in: result, cancelled: cancelled)
            }
            guard let replaced else {
                return nil
            }
            result = replaced
        }
        return result
    }

    /// `text` with the matches of a regular expression replaced (with Subst., the whole name by the
    /// first match's replacement); nil when the expression gave up.
    private func replacing(
        _ expression: NSRegularExpression,
        with replacement: [Part],
        in text: String,
        cancelled: () -> Bool
    ) -> String? {
        let found = RenameRegex.matches(
            expression,
            in: text,
            firstOnly: firstOnly || substitute,
            guardian: guardian,
            cancelled: cancelled
        )
        guard case .found(let matches) = found else {
            return nil
        }
        if substitute {
            return matches.first.map { expand(replacement, $0, text) } ?? text
        }
        guard !matches.isEmpty else {
            return text
        }
        var result = ""
        var position = 0
        for match in matches {
            result += Self.piece(of: text, NSRange(location: position, length: match.range.location - position))
            result += expand(replacement, match, text)
            position = match.range.location + match.range.length
        }
        return result + Self.rest(of: text, from: position)
    }

    /// `text` with the matches of a plain search replaced; nil when the search gave up.
    private func replacing(
        _ matcher: WildcardMatcher,
        with replacement: [Part],
        in text: String,
        cancelled: () -> Bool
    ) -> String? {
        // Bounded like a regular expression: a long search in a long name is the name times the search.
        let found = matcher.matches(in: text, firstOnly: firstOnly, guardian: guardian, cancelled: cancelled)
        guard case .found(let ranges) = found else {
            return nil
        }
        guard !ranges.isEmpty, case .text(let replacementText)? = replacement.first else {
            return text
        }
        var result = ""
        var position = 0
        for range in ranges {
            result += Self.piece(of: text, NSRange(location: position, length: range.location - position))
            result += replacementText
            position = range.location + range.length
        }
        return result + Self.rest(of: text, from: min(position, text.utf16.count))
    }

    private func expand(_ parts: [Part], _ match: NSTextCheckingResult, _ text: String) -> String {
        parts.map { part -> String in
            switch part {
            case .text(let literal):
                return literal

            case .group(let number, let letterCase):
                guard number < match.numberOfRanges, match.range(at: number).location != NSNotFound else {
                    return ""
                }
                return letterCase.apply(to: Self.piece(of: text, match.range(at: number)))
            }
        }
        .joined()
    }
}
