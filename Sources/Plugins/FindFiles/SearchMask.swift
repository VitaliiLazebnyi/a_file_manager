import Foundation

/// The "Search for" field of Find Files (spec 09 › "Search for"): masks separated by spaces,
/// exclude masks after `|`.
///
/// A word without wildcards and without a dot matches anywhere in the name; a name with a dot must
/// match exactly. A name with spaces is written in quotes, or as it is when nothing else is in the
/// field. With `regex`, the whole field is one regular expression for the name, without regard to
/// case. Unchecked: immutable, and `NSRegularExpression` may match on several threads at once.
public struct SearchMask: @unchecked Sendable {
    /// The masks in wildcard form (`*` and `?` only), lowercased.
    internal let include: [String]
    /// The exclude masks (after `|`) in wildcard form, lowercased; a name that matches one is not found.
    internal let exclude: [String]
    private let includeCharacters: [[Character]]
    private let excludeCharacters: [[Character]]
    private let expression: NSRegularExpression?
    /// Counts the names a regular expression ran out of time on.
    internal let trip = RegexTrip()
    /// False when the field was to be a regular expression and is not one; nothing matches then.
    public let isValid: Bool

    /// The mask the field `text` stands for; with `regex`, the trimmed text is one regular expression.
    public init(_ text: String, regex: Bool = false) {
        if regex {
            (include, exclude) = ([], [])
            (includeCharacters, excludeCharacters) = ([], [])
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            expression = trimmed.isEmpty ? nil : try? NSRegularExpression(pattern: trimmed, options: .caseInsensitive)
            isValid = trimmed.isEmpty || expression != nil
            return
        }
        expression = nil
        isValid = true
        let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        func pattern(_ token: String) -> String {
            let lowered = token.lowercased()
            let isPlainWord = !lowered.contains("*") && !lowered.contains("?") && !lowered.contains(".")
            return isPlainWord ? "*\(lowered)*" : lowered
        }
        func patterns(_ part: Substring?) -> [String] {
            Self.tokens(String(part ?? "")).map(pattern)
        }
        var included = patterns(parts.first)
        // `Letter to Mr. Smith.doc` typed as it is: the whole field is tried as one name too.
        let whole = text.trimmingCharacters(in: .whitespaces)
        if parts.count == 1, included.count > 1, !whole.contains("\"") {
            included.append(pattern(whole))
        }
        include = included
        exclude = patterns(parts.count > 1 ? parts[1] : nil)
        includeCharacters = include.map { Array($0) }
        excludeCharacters = exclude.map { Array($0) }
    }

    /// `*` and `?` as file masks use them, character by character (so a composed and a
    /// decomposed `é` are the same, and `[` is just a bracket).
    ///
    /// `*.*` matches every name; `name.*` and `name.` also match `name` without an extension, as under DOS.
    internal static func wildcard(_ pattern: [Character], _ name: [Character]) -> Bool {
        if pattern.count == 3, pattern == ["*", ".", "*"] {
            return true
        }
        if glob(ArraySlice(pattern), ArraySlice(name)) {
            return true
        }
        guard !name.contains(".") else {
            return false
        }
        if pattern.count >= 2, pattern.suffix(2) == [".", "*"] {
            return glob(pattern.dropLast(2), ArraySlice(name))
        }
        if pattern.last == "." {
            return glob(pattern.dropLast(), ArraySlice(name))
        }
        return false
    }

    /// Splits at spaces; a part in double quotes stays together.
    private static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in text {
            if character == "\"" {
                inQuotes.toggle()
            } else if character == " ", !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    /// The usual two-pointer match: linear in practice, without recursion.
    private static func glob(_ pattern: ArraySlice<Character>, _ name: ArraySlice<Character>) -> Bool {
        var (inPattern, inName) = (pattern.startIndex, name.startIndex)
        var star: Int?
        var mark = inName
        while inName < name.endIndex {
            if inPattern < pattern.endIndex, pattern[inPattern] == "?" || pattern[inPattern] == name[inName] {
                inPattern += 1
                inName += 1
            } else if inPattern < pattern.endIndex, pattern[inPattern] == "*" {
                star = inPattern
                mark = inName
                inPattern += 1
            } else if let star {
                inPattern = star + 1
                mark += 1
                inName = mark
            } else {
                return false
            }
        }
        while inPattern < pattern.endIndex, pattern[inPattern] == "*" {
            inPattern += 1
        }
        return inPattern == pattern.endIndex
    }

    /// Whether `name` matches: one of the masks (or the regular expression) and none of the exclude masks.
    public func matches(_ name: String) -> Bool {
        matches(name) { false }
    }

    /// Whether `name` matches; `cancelled` ends a regular expression that is still working on it.
    ///
    /// A name the expression takes too long for does not match.
    internal func matches(_ name: String, cancelled: () -> Bool) -> Bool {
        guard isValid else {
            return false
        }
        if let expression {
            return FindRegex.matches(expression, in: name, trip: trip, cancelled: cancelled)
        }
        let characters = Array(name.lowercased())
        func hit(_ pattern: [Character]) -> Bool { Self.wildcard(pattern, characters) }
        return (includeCharacters.isEmpty || includeCharacters.contains(where: hit))
            && !excludeCharacters.contains(where: hit)
    }
}
