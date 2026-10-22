import Foundation

/// The words "First of each word uppercase (English in Titles)" leaves in lower case
/// (spec 18 › Case switches, the `LowercaseStrings` setting).
internal struct TitleCaseRule: Equatable {
    internal static let defaultSetting =
        "English in Titles:a,an,the,at,by,for,in,of,on,to,from,up,and,as,but,or,nor,yet,so,vs"
    internal static let standard = Self(setting: defaultSetting)

    internal let label: String
    internal let words: Set<String>
    /// A `!` at the end of the label: the last word may stay in lower case too.
    internal let allowsLowercaseLastWord: Bool

    /// `<description>:<word list>`.
    internal init(setting: String) {
        // Without a label the whole setting is the word list.
        let colon = setting.firstIndex(of: ":")
        var label = colon.map { String(setting[..<$0]) } ?? "English in Titles"
        allowsLowercaseLastWord = label.hasSuffix("!")
        if allowsLowercaseLastWord { label.removeLast() }
        self.label = label
        let list = colon.map { setting[setting.index(after: $0)...] } ?? Substring(setting)
        words = Set(
            list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter {
                    !$0.isEmpty
                }
        )
    }
}

/// The conversions of the Upper/lowercase box and of the case switches `[U] [L] [F] [f] [n]`
/// (spec 09 › Upper/lowercase).
internal enum LetterCase: Int, Codable, CaseIterable {
    case unchanged, lower, upper, firstUpper, words, titleWords

    /// The characters after which a new word starts, besides white space.
    ///
    /// A dot is not among them, so an extension stays in lower case.
    private static let wordBreaks: Set<Character> = ["/", "\\", "-", "_", "(", "[", "{", ",", ";", "+", "&"]

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
                if character.isWhitespace || wordBreaks.contains(character) { startsWord = true }
            }
        }
        return result
    }

    internal func apply(to text: String, rule: TitleCaseRule = .standard) -> String {
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
            var words = Self.capitalizingWords(text).split(separator: " ", omittingEmptySubsequences: false)
                .map(
                    String.init
                )
            let real = words.indices.filter { !words[$0].isEmpty }
            for index in real.dropFirst() where index != real.last || rule.allowsLowercaseLastWord {
                let core = words[index].trimmingCharacters(in: CharacterSet.letters.inverted)
                if rule.words.contains(core.lowercased()) { words[index] = words[index].lowercased() }
            }
            return words.joined(separator: " ")
        }
    }
}

/// Everything the fields of the tool hold: what "Save settings" stores under a name
/// (spec 09 › Saved settings and persistence).
internal struct RenameSettings: Codable, Equatable {
    /// The settings of `<default>`: no change.
    internal static let unchanged = Self()

    internal var nameMask = "[N]"
    internal var extensionMask = "[E]"
    internal var search = ""
    internal var replacement = ""
    /// `^`: respect upper and lower case.
    internal var caseSensitive = false
    /// `1x`: replace only the first occurrence.
    internal var firstOnly = false
    /// `[E]`: also search the extension.
    internal var searchesExtension = true
    internal var regularExpression = false
    /// Subst.: the whole name is replaced by the replacement, not just the matched part.
    internal var substitute = false
    internal var letterCase = LetterCase.unchanged
    internal var counter = CounterDefinition()
}

/// Search & Replace of the Multi-Rename Tool (spec 18 › Search & Replace in the Multi-Rename
/// Tool).
///
/// Compiled once per preview and then used from several threads.
///
/// A regular expression the user typed is run with a bound on its time and ends when the work
/// is cancelled (`RenameRegex`); the plain search with `*` and `?` is matched by hand
/// (`WildcardMatcher`), in time proportional to the name times the mask.
internal struct SearchReplace {
    internal enum Problem: Error, Equatable {
        case invalidExpression(String)
        /// A regular expression that takes too long for the names of the list.
        case tooSlow(String)
    }

    /// A piece of a regular-expression replacement: text, or a group in a letter case.
    private enum Part {
        case text(String)
        case group(Int, LetterCase)
    }

    private enum Finder {
        case regex(NSRegularExpression)
        case wildcard(WildcardMatcher)
    }

    private struct Pair {
        let finder: Finder
        let replacement: [Part]
    }

    private let pairs: [Pair]
    private let firstOnly: Bool
    private let substitute: Bool
    /// Counts the names a regular expression ran out of time on.
    private let guardian = RenameRegexGuard()
    internal let search: String

    /// Whether the regular expression took too long for some names: those got no new name.
    internal var timedOut: Bool { guardian.hasTimedOut }

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
        var pattern = pattern
        for (from, to) in [("(?P<", "(?<"), ("(?g)", ""), ("(?-g)", "")] {
            pattern = pattern.replacingOccurrences(of: from, with: to)
        }
        // `(?P=name)` is `\k<name>`, `(?'name'` is `(?<name>`.
        pattern = pattern.replacing(#/\(\?P=(\w+)\)/#) { "\\k<" + $0.1 + ">" }
        pattern = pattern.replacing(#/\(\?'(\w+)'/#) { "(?<" + $0.1 + ">" }
        // The pattern the spec singles out as rewritten to avoid a crash.
        if pattern.hasPrefix("^??") { pattern = "^?" + pattern.dropFirst(3) }
        return pattern
    }

    /// Reads "Replace with" of a regular expression: `$1`…`$89` are groups, and `\U`, `\L`,
    /// `\F`, `\n` directly before one convert that group only.
    private static func template(_ text: String, groups: Int) -> [Part] {
        var parts: [Part] = []
        var literal = ""
        var pending = LetterCase.unchanged
        let characters = Array(text)
        var position = 0
        /// The value of the digit at `index`; nil where there is none.
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
                if !literal.isEmpty { parts.append(.text(literal)) }
                literal = ""
                parts.append(.group(number, pending))
                pending = .unchanged
                position += length
            } else {
                literal.append(character)
                position += 1
            }
        }
        if !literal.isEmpty { parts.append(.text(literal)) }
        return parts
    }

    /// The name after the replacements; a name the regular expression takes too long for is
    /// left as it is (use `replacing` to know).
    internal func apply(to text: String) -> String {
        replacing(in: text, cancelled: { false }) ?? text
    }

    /// The name after the replacements, or nil when the regular expression ran out of time or
    /// the work was cancelled: the preview then shows `<Error!>`.
    internal func replacing(in text: String, cancelled: () -> Bool) -> String? {
        var text = text
        for pair in pairs {
            let source = text as NSString
            let whole = NSRange(location: 0, length: source.length)
            switch pair.finder {
            case .regex(let expression):
                guard
                    let matches = RenameRegex.matches(
                        expression,
                        in: text,
                        firstOnly: firstOnly || substitute,
                        guardian: guardian,
                        cancelled: cancelled
                    )
                else {
                    return nil
                }
                if substitute {
                    if let match = matches.first { text = expand(pair.replacement, match, source) }
                    continue
                }
                guard !matches.isEmpty else { continue }
                var result = ""
                var position = 0
                for match in matches {
                    result += source.substring(
                        with: NSRange(location: position, length: match.range.location - position)
                    )
                    result += expand(pair.replacement, match, source)
                    position = match.range.location + match.range.length
                }
                text = result + source.substring(from: position)

            case .wildcard(let matcher):
                // Bounded like a regular expression: a long search in a long name is the name times the search.
                guard
                    let ranges = matcher.matches(
                        in: text,
                        firstOnly: firstOnly,
                        guardian: guardian,
                        cancelled: cancelled
                    )
                else { return nil }
                guard !ranges.isEmpty, case .text(let replacement)? = pair.replacement.first else { continue }
                var result = ""
                var position = 0
                for range in ranges {
                    result += source.substring(with: NSRange(location: position, length: range.location - position))
                    result += replacement
                    position = range.location + range.length
                }
                text = result + source.substring(from: min(position, whole.length))
            }
        }
        return text
    }

    private func expand(_ parts: [Part], _ match: NSTextCheckingResult, _ source: NSString) -> String {
        parts.map { part -> String in
            switch part {
            case .text(let text):
                return text

            case .group(let number, let letterCase):
                guard number < match.numberOfRanges, match.range(at: number).location != NSNotFound else {
                    return ""
                }
                return letterCase.apply(to: source.substring(with: match.range(at: number)))
            }
        }
        .joined()
    }
}

/// The whole rename pipeline for one set of settings (spec 09 › Rename pipeline): masks, then
/// Search & Replace, then the case conversion.
///
/// Built once, on any thread; `newName` may then be called from several threads at once.
internal struct RenameEngine {
    /// The text the preview shows where a name could not be made.
    internal static let errorText = "<Error!>"

    internal let settings: RenameSettings
    internal let context: RenameContext
    private let nameMask: RenameMask
    private let extensionMask: RenameMask
    private let searchReplace: SearchReplace?
    private let formats: RenameFormats
    /// Ends a regular expression that is still working on a name (the preview was overtaken, the run cancelled).
    private let cancelled: @Sendable () -> Bool
    /// What is wrong with the settings as a whole, if anything: then no item gets a name.
    internal let problem: any Error?

    /// Set once names were computed: a regular expression that took too long for some of them.
    internal var tooSlow: any Error? {
        searchReplace?.timedOut == true ? SearchReplace.Problem.tooSlow(settings.search) : nil
    }

    internal init(
        _ settings: RenameSettings,
        context: RenameContext,
        cancelled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.settings = settings
        self.cancelled = cancelled
        var context = context
        context.counter = settings.counter
        self.context = context
        nameMask = RenameMask(settings.nameMask)
        extensionMask = RenameMask(settings.extensionMask)
        formats = RenameFormats(locale: context.locale, timeZone: context.timeZone)
        do {
            searchReplace = try SearchReplace(settings)
            problem = nameMask.error ?? extensionMask.error
        } catch {
            searchReplace = nil
            problem = error
        }
    }

    /// Control characters become spaces and slashes at the end are dropped.
    internal static func tidied(_ name: String) -> String {
        var name = String(
            name.map { character in
                character.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } ? " " : character
            }
        )
        while name.hasSuffix("/") { name.removeLast() }
        return name
    }

    /// Why a name cannot be given to a file; nil when it can.
    ///
    /// A slash inside the name is fine: it moves the item into that folder.
    internal static func invalidity(of name: String) -> String? {
        if name.isEmpty {
            return "The name is empty."
        }
        // Cut at the `/` byte, not at the character: a combining mark after a slash makes one
        // character with it, and the file system reads the slash all the same.
        let components = name.utf8.split(separator: 0x2F, omittingEmptySubsequences: false)
            .dropFirst(
                name.utf8.first == 0x2F ? 1 : 0
            )
        for component in components {
            if component.isEmpty {
                return "A folder name is empty."
            }
            if component.elementsEqual(".".utf8) || component.elementsEqual("..".utf8) {
                return "\(String(decoding: component, as: UTF8.self)) is not a name."
            }
            if component.count > 255 {
                return "The name is too long."
            }
        }
        return nil
    }

    /// The new name of the item at `index` of the list.
    ///
    /// With `given`, that name (loaded from a file or typed by the user) takes the place of the
    /// masks' result. Nil is `<Error!>`.
    internal func newName(for subject: RenameSubject, index: Int, given: String? = nil) -> String? {
        guard let searchReplace else {
            return nil
        }
        var name: String
        var ext: String
        if let given {
            // Everything from the last dot on is the extension of a given name.
            if let dot = given.lastIndex(of: "."), dot != given.startIndex, given.index(after: dot) != given.endIndex {
                (name, ext) = (String(given[..<dot]), String(given[given.index(after: dot)...]))
            } else {
                (name, ext) = (given, "")
            }
        } else {
            var state = MaskState()
            do {
                name = try nameMask.evaluate(subject, index: index, context: context, formats: formats, state: &state)
                ext = try extensionMask.evaluate(
                    subject,
                    index: index,
                    context: context,
                    formats: formats,
                    state: &state
                )
            } catch {
                return nil
            }
        }
        func joined(_ name: String, _ ext: String) -> String { ext.isEmpty ? name : name + "." + ext }
        var full: String
        if settings.searchesExtension {
            guard let replaced = searchReplace.replacing(in: joined(name, ext), cancelled: cancelled) else {
                return nil
            }
            full = replaced
        } else {
            guard let replaced = searchReplace.replacing(in: name, cancelled: cancelled) else {
                return nil
            }
            full = joined(replaced, ext)
        }
        full = settings.letterCase.apply(to: full, rule: context.titleRule)
        return Self.tidied(full)
    }
}
