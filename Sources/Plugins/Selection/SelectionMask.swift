import AFMKernel
import Foundation

/// The masks of Select group / Unselect group (spec 18 › File masks and selection types):
/// `includes | excludes` with several masks separated by spaces or `;`, masks in double quotes
/// for names with spaces, a trailing `/` (or the `\` of the specification) for masks that mean
/// folders, path-limited masks (`/sub/*.txt`, `sub/**/*.txt`), a leading `<` for a regular
/// expression and `A>B` for related files.
///
/// Names are compared without regard to case.
///
/// A value type without shared state: it may be used from any thread.
internal struct SelectionMask {
    /// One mask: an optional chain of folder patterns and the pattern of the name itself.
    private struct Token {
        /// Patterns of the folders leading to the entry; `**` stands for any number of levels.
        let folders: [[Character]]
        /// The pattern of the name, in lower case.
        let name: [Character]
        /// The same as a mask on bytes, for a pattern of plain ASCII (without a carriage return,
        /// which is a letter of its own to a `Character`) with no folder part; nil for any other.
        let byteToken: ByteToken?
        /// The mask began with a separator: the chain starts at the base directory.
        let isAnchored: Bool
        /// The mask ended with a separator: it means folders, not files.
        let foldersOnly: Bool

        /// Whether the mask says anything about the folders leading to the entry.
        var usesPath: Bool { isAnchored || !folders.isEmpty }

        /// Nil for a mask that names nothing in a list (a lone `\`, the base directory itself).
        init?(_ text: String) {
            let path = text.replacingOccurrences(of: "\\", with: "/").lowercased()
            var parts = path.split(separator: "/").map(String.init).filter { $0 != "." }
            guard let last = parts.popLast() else {
                return nil
            }
            folders = parts.map(Array.init)
            name = Array(last)
            isAnchored = path.hasPrefix("/") || path.hasPrefix("./")
            foldersOnly = path.hasSuffix("/")
            let isPlain = last.utf8.allSatisfy { $0 < 0x80 && $0 != 0x0D }
            byteToken =
                isPlain && !isAnchored && folders.isEmpty
                ? ByteToken(name: Array(last.utf8), foldersOnly: foldersOnly) : nil
        }

        /// Whether the folder patterns fit the folders from the first to the last; `**` stands
        /// for any number of them.
        ///
        /// The usual two-pointer match, going back to the last `**` only: linear in practice and
        /// never more than patterns times folders, where trying every number of levels for each
        /// `**` in turn grows with the power of their count.
        private static func chain(_ patterns: [[Character]], matches chain: [[Character]]) -> Bool {
            let anyLevels: [Character] = ["*", "*"]
            var (pattern, level) = (0, 0)
            var star: Int?
            var mark = 0
            while level < chain.count {
                if pattern < patterns.count, patterns[pattern] == anyLevels {
                    star = pattern
                    mark = level
                    pattern += 1
                } else if pattern < patterns.count, Wildcard.matches(patterns[pattern], chain[level]) {
                    pattern += 1
                    level += 1
                } else if let star {
                    pattern = star + 1
                    mark += 1
                    level = mark
                } else {
                    return false
                }
            }
            while pattern < patterns.count, patterns[pattern] == anyLevels { pattern += 1 }
            return pattern == patterns.count
        }

        /// Whether the entry of that name (in lower case) matches; `chain` is the folders leading to
        /// the entry, in lower case.
        func matches(_ name: [Character], isFolder: Bool, chain: [[Character]]) -> Bool {
            if foldersOnly, !isFolder {
                return false
            }
            guard Wildcard.matches(self.name, name) else {
                return false
            }
            guard usesPath else {
                return true
            }
            // Without a leading separator the chain may start below any subdirectory.
            let patterns = isAnchored ? folders : [Array("**")] + folders
            return Self.chain(patterns, matches: chain)
        }
    }

    /// A mask of plain ASCII with no folder part, matched on the bytes of a plain ASCII name.
    private struct ByteToken {
        /// The pattern of the name, in lower case.
        let name: [UInt8]
        /// The mask means folders, not files.
        let foldersOnly: Bool

        /// Whether the name, of plain ASCII bytes in any case, matches.
        func matches(_ entryName: UnsafeBufferPointer<UInt8>, isFolder: Bool) -> Bool {
            if foldersOnly, !isFolder {
                return false
            }
            return Wildcard.matches(ascii: name, entryName)
        }
    }

    /// The masks of both parts as `ByteToken`s, for a mask whose every part can be one.
    private struct ByteMasks {
        /// The masks before the `|`.
        let includes: [ByteToken]
        /// The masks after the `|`.
        let excludes: [ByteToken]

        /// Whether the name, of plain ASCII bytes in any case, is selected.
        func matches(_ name: UnsafeBufferPointer<UInt8>, isFolder: Bool) -> Bool {
            func matching(_ token: ByteToken) -> Bool { token.matches(name, isFolder: isFolder) }
            // An empty include part means everything.
            return (includes.isEmpty || includes.contains(where: matching)) && !excludes.contains(where: matching)
        }
    }

    /// The mask as typed, without the spaces around it.
    internal let text: String
    private var includes: [Token] = []
    private var excludes: [Token] = []
    /// The same as masks on bytes, when every mask of both parts can be one and there is no `A>B`.
    private var byteMasks: ByteMasks?
    private var expression: NSRegularExpression?
    /// Counts the names the regular expression ran out of time on.
    private let trip = SelectionRegexTrip()
    /// The `B` of `A>B`: a rename mask that turns the name of a matching file into the name of
    /// the file that belongs to it.
    private var related: String?
    /// False for a regular expression that cannot be read; such a mask matches nothing.
    internal private(set) var isValid = true

    /// Whether the folders leading to an entry matter; when not, callers need not work them out.
    internal var needsDirectories: Bool {
        related != nil || includes.contains(where: \.usesPath) || excludes.contains(where: \.usesPath)
    }

    /// Whether the mask is a regular expression, which can take any time on a name.
    internal var isRegex: Bool { expression != nil }

    /// Whether the mask takes the files that belong to the matching ones (`A>B`): its answer
    /// for an entry then depends on the other entries of the list.
    internal var pairsRelatedFiles: Bool { related != nil }

    /// Whether a regular expression of the mask ran out of time on some name: those were taken
    /// as not matching, and the mask's answer is not to be trusted.
    internal var timedOut: Bool { trip.hasTimedOut }

    /// Reads a mask; one that cannot be read is not `isValid` and matches nothing.
    internal init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        self.text = trimmed
        if trimmed.hasPrefix("<") {
            expression = try? NSRegularExpression(pattern: String(trimmed.dropFirst()), options: [.caseInsensitive])
            isValid = expression != nil
            return
        }
        let (primary, relatedPart) = Self.split(trimmed, at: ">")
        related = relatedPart.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        let (included, excluded) = Self.split(primary, at: "|")
        includes = Self.tokens(included).compactMap(Token.init)
        excludes = Self.tokens(excluded ?? "").compactMap(Token.init)
        let (includeBytes, excludeBytes) = (includes.compactMap(\.byteToken), excludes.compactMap(\.byteToken))
        if related == nil, includeBytes.count == includes.count, excludeBytes.count == excludes.count {
            byteMasks = ByteMasks(includes: includeBytes, excludes: excludeBytes)
        }
    }

    /// Splits at the first `separator` outside double quotes.
    private static func split(_ text: String, at separator: Character) -> (String, String?) {
        var quoted = false
        for index in text.indices {
            if text[index] == "\"" { quoted.toggle() }
            if text[index] == separator, !quoted {
                return (String(text[..<index]), String(text[text.index(after: index)...]))
            }
        }
        return (text, nil)
    }

    /// The masks of one part, separated by spaces or semicolons; double quotes keep spaces.
    private static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
            } else if !quoted, character == " " || character == ";" {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Whether the entry matches the mask itself; related files (`A>B`) are found by `selected`.
    /// `cancelled` ends a regular expression that is still working.
    internal func matches(_ entry: MaskEntry, cancelled: () -> Bool) -> Bool {
        if let expression {
            return SelectionRegex.matches(expression, entry.name, trip: trip, cancelled: cancelled)
        }
        guard isValid else {
            return false
        }
        guard let byteMasks else {
            return matchesCharacters(entry)
        }
        // A plain ASCII name is worked out on its UTF-8 in place (no array of characters per
        // name); any other, or one that is not in one piece of UTF-8, by its characters.
        return entry.name.utf8.withContiguousStorageIfAvailable { name in
            name.allSatisfy { $0 < 0x80 && $0 != 0x0D }
                ? byteMasks.matches(name, isFolder: entry.isFolder) : matchesCharacters(entry)
        } ?? matchesCharacters(entry)
    }

    /// The answer of `matches` worked out on the characters of the name, in lower case.
    private func matchesCharacters(_ entry: MaskEntry) -> Bool {
        let name = Array(entry.name.lowercased())
        let chain = needsDirectories ? entry.directory.map { Array($0.lowercased()) } : []
        func matching(_ token: Token) -> Bool { token.matches(name, isFolder: entry.isFolder, chain: chain) }
        // An empty include part means everything.
        return (includes.isEmpty || includes.contains(where: matching)) && !excludes.contains(where: matching)
    }

    /// Whether an entry of that name matches the mask, with no folders leading to it.
    internal func matches(_ name: String, isFolder: Bool) -> Bool {
        matches(MaskEntry(name: name, isFolder: isFolder)) { false }
    }

    /// For every entry, whether the mask selects it: the entries that match, and with `A>B`
    /// the entries of the same folder whose names derive from them.
    internal func selected(_ entries: [MaskEntry], cancelled: () -> Bool) -> [Bool] {
        var result: [Bool] = []
        result.reserveCapacity(entries.count)
        for entry in entries {
            // A cancelled run has no use for the rest.
            result.append(!cancelled() && matches(entry, cancelled: cancelled))
        }
        guard let related else {
            return result
        }
        func key(_ directory: [String], _ name: String) -> String {
            directory.joined(separator: "/").lowercased() + "/" + name.lowercased()
        }
        var places: [String: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            places[key(entry.directory, entry.name), default: []].append(index)
        }
        for (index, entry) in entries.enumerated() where result[index] && !entry.isFolder {
            for partner in places[key(entry.directory, Wildcard.rename(entry.name, with: related))] ?? [] {
                result[partner] = true
            }
        }
        return result
    }
}
