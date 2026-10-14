import AFMKernel
import Foundation

/// What a mask is asked about: one entry of a list, with the folders that lead to it from the
/// directory the list belongs to (empty for an entry of that directory itself).
struct MaskEntry {
    let name: String
    let isFolder: Bool
    let directory: [String]

    init(name: String, isFolder: Bool = false, directory: [String] = []) {
        self.name = name
        self.isFolder = isFolder
        self.directory = directory
    }
}

/// The masks of Select group / Unselect group (spec 18 › File masks and selection types):
/// `includes | excludes` with several masks separated by spaces or `;`, masks in double quotes
/// for names with spaces, a trailing `/` (or the `\` of the specification) for masks that mean
/// folders, path-limited masks (`/sub/*.txt`, `sub/**/*.txt`), a leading `<` for a regular
/// expression and `A>B` for related files. Names are compared without regard to case.
///
/// A value type without shared state: it may be used from any thread.
struct SelectionMask {
    /// One mask: an optional chain of folder patterns and the pattern of the name itself.
    private struct Token {
        /// Patterns of the folders leading to the entry; `**` stands for any number of levels.
        let folders: [[Character]]
        let name: [Character]
        /// The same as ASCII bytes (without a carriage return, which is a letter of its own
        /// to a `Character`), for names that are plain ASCII too; nil for any other pattern.
        let nameBytes: [UInt8]?
        /// The mask began with a separator: the chain starts at the base directory.
        let isAnchored: Bool
        /// The mask ended with a separator: it means folders, not files.
        let foldersOnly: Bool

        /// Nil for a mask that names nothing in a list (a lone `\`, the base directory itself).
        init?(_ text: String) {
            let text = text.replacingOccurrences(of: "\\", with: "/").lowercased()
            var parts = text.split(separator: "/").map(String.init).filter { $0 != "." }
            guard let last = parts.popLast() else { return nil }
            folders = parts.map(Array.init)
            name = Array(last)
            nameBytes = last.utf8.allSatisfy { $0 < 0x80 && $0 != 0x0D } ? Array(last.utf8) : nil
            isAnchored = text.hasPrefix("/") || text.hasPrefix("./")
            foldersOnly = text.hasSuffix("/")
        }

        var usesPath: Bool { isAnchored || !folders.isEmpty }

        /// For a name of plain ASCII bytes and a mask with no folder part; nil when `nameBytes` is.
        func matches(bytes name: UnsafeBufferPointer<UInt8>, isFolder: Bool) -> Bool? {
            guard let nameBytes, !usesPath else { return nil }
            if foldersOnly && !isFolder { return false }
            return Wildcard.matches(ascii: nameBytes, name)
        }

        /// `chain` is the folders leading to the entry, in lower case.
        func matches(_ name: [Character], isFolder: Bool, chain: [[Character]]) -> Bool {
            if foldersOnly && !isFolder { return false }
            guard Wildcard.matches(self.name, name) else { return false }
            guard usesPath else { return true }
            // Without a leading separator the chain may start below any subdirectory.
            let patterns = isAnchored ? folders : [Array("**")] + folders
            return Token.chain(patterns, matches: chain)
        }

        /// Whether the folder patterns fit the folders from the first to the last; `**` stands
        /// for any number of them. The usual two-pointer match, going back to the last `**`
        /// only: linear in practice and never more than patterns times folders, where trying
        /// every number of levels for each `**` in turn grows with the power of their count.
        private static func chain(_ patterns: [[Character]], matches chain: [[Character]]) -> Bool {
            let anyLevels: [Character] = ["*", "*"]
            var (p, c) = (0, 0)
            var star: Int?
            var mark = 0
            while c < chain.count {
                if p < patterns.count, patterns[p] == anyLevels {
                    star = p
                    mark = c
                    p += 1
                } else if p < patterns.count, Wildcard.matches(patterns[p], chain[c]) {
                    p += 1
                    c += 1
                } else if let star {
                    p = star + 1
                    mark += 1
                    c = mark
                } else {
                    return false
                }
            }
            while p < patterns.count, patterns[p] == anyLevels { p += 1 }
            return p == patterns.count
        }
    }

    let text: String
    private var includes: [Token] = []
    private var excludes: [Token] = []
    private var expression: NSRegularExpression?
    /// Counts the names the regular expression ran out of time on.
    private let trip = SelectionRegexTrip()
    /// The `B` of `A>B`: a rename mask that turns the name of a matching file into the name of
    /// the file that belongs to it.
    private var related: String?
    /// False for a regular expression that cannot be read; such a mask matches nothing.
    private(set) var isValid = true

    init(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        self.text = text
        if text.hasPrefix("<") {
            expression = try? NSRegularExpression(pattern: String(text.dropFirst()), options: [.caseInsensitive])
            isValid = expression != nil
            return
        }
        let (primary, related) = SelectionMask.split(text, at: ">")
        self.related = related.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        let (included, excluded) = SelectionMask.split(primary, at: "|")
        includes = SelectionMask.tokens(included).compactMap(Token.init)
        excludes = SelectionMask.tokens(excluded ?? "").compactMap(Token.init)
    }

    /// Whether the folders leading to an entry matter; when not, callers need not work them out.
    var needsDirectories: Bool {
        related != nil || includes.contains(where: \.usesPath) || excludes.contains(where: \.usesPath)
    }

    /// Whether the mask is a regular expression, which can take any time on a name.
    var isRegex: Bool { expression != nil }

    /// Whether the mask takes the files that belong to the matching ones (`A>B`): its answer
    /// for an entry then depends on the other entries of the list.
    var pairsRelatedFiles: Bool { related != nil }

    /// Whether a regular expression of the mask ran out of time on some name: those were taken
    /// as not matching, and the mask's answer is not to be trusted.
    var timedOut: Bool { trip.hasTimedOut }

    /// Whether the entry matches the mask itself; related files (`A>B`) are found by `selected`.
    /// `cancelled` ends a regular expression that is still working.
    func matches(_ entry: MaskEntry, cancelled: () -> Bool = { false }) -> Bool {
        if let expression {
            return SelectionRegex.matches(expression, entry.name, trip: trip, cancelled: cancelled)
        }
        guard isValid else { return false }
        if !needsDirectories, let answer = quickAnswer(entry) { return answer }
        let name = Array(entry.name.lowercased())
        let chain = needsDirectories ? entry.directory.map { Array($0.lowercased()) } : []
        func matching(_ token: Token) -> Bool { token.matches(name, isFolder: entry.isFolder, chain: chain) }
        // An empty include part means everything.
        return (includes.isEmpty || includes.contains(where: matching)) && !excludes.contains(where: matching)
    }

    /// The answer for a plain ASCII name, worked out on its UTF-8 in place (no array of
    /// characters per name); nil when the name or a mask is not plain, or the name is not in
    /// one piece of UTF-8.
    private func quickAnswer(_ entry: MaskEntry) -> Bool? {
        entry.name.utf8.withContiguousStorageIfAvailable { name -> Bool? in
            for byte in name where byte >= 0x80 || byte == 0x0D { return nil }
            var failed = false
            func judge(_ token: Token) -> Bool {
                guard let answer = token.matches(bytes: name, isFolder: entry.isFolder) else {
                    failed = true
                    return false
                }
                return answer
            }
            let included = includes.isEmpty || includes.contains(where: judge)
            let excluded = !failed && excludes.contains(where: judge)
            return failed ? nil : included && !excluded
        } ?? nil
    }

    func matches(_ name: String, isFolder: Bool = false) -> Bool {
        matches(MaskEntry(name: name, isFolder: isFolder))
    }

    /// For every entry, whether the mask selects it: the entries that match, and with `A>B`
    /// the entries of the same folder whose names derive from them.
    func selected(_ entries: [MaskEntry], cancelled: () -> Bool = { false }) -> [Bool] {
        var result: [Bool] = []
        result.reserveCapacity(entries.count)
        for entry in entries {
            // A cancelled run has no use for the rest.
            result.append(!cancelled() && matches(entry, cancelled: cancelled))
        }
        guard let related else { return result }
        func key(_ directory: [String], _ name: String) -> String { directory.joined(separator: "/").lowercased() + "/" + name.lowercased() }
        var places: [String: [Int]] = [:]
        for (index, entry) in entries.enumerated() { places[key(entry.directory, entry.name), default: []].append(index) }
        for (index, entry) in entries.enumerated() where result[index] && !entry.isFolder {
            for partner in places[key(entry.directory, Wildcard.rename(entry.name, with: related))] ?? [] { result[partner] = true }
        }
        return result
    }

    /// Splits at the first `separator` outside double quotes.
    private static func split(_ text: String, at separator: Character) -> (String, String?) {
        var quoted = false
        for index in text.indices {
            if text[index] == "\"" { quoted.toggle() }
            if text[index] == separator && !quoted { return (String(text[..<index]), String(text[text.index(after: index)...])) }
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
            } else if !quoted && (character == " " || character == ";") {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

/// `*` and `?` matching as file masks use it (spec 18 › Core syntax).
enum Wildcard {
    /// Both sides are expected in lower case. `*.*` matches every name, `name.*` and `name.`
    /// also match `name` without an extension, as they do under DOS.
    static func matches(_ pattern: [Character], _ name: [Character]) -> Bool {
        if glob(pattern[...], name[...]) { return true }
        guard !name.contains(".") else { return false }
        if pattern.count >= 2, pattern.suffix(2) == [".", "*"] { return glob(pattern.dropLast(2), name[...]) }
        if pattern.last == "." { return glob(pattern.dropLast(), name[...]) }
        return false
    }

    static func matches(_ pattern: String, _ name: String) -> Bool {
        matches(Array(pattern.lowercased()), Array(name.lowercased()))
    }

    /// The same for a plain ASCII pattern in lower case and a plain ASCII name (of any case).
    static func matches(ascii pattern: [UInt8], _ name: UnsafeBufferPointer<UInt8>) -> Bool {
        if glob(pattern[...], name) { return true }
        guard !name.contains(UInt8(ascii: ".")) else { return false }
        if pattern.count >= 2, pattern[pattern.count - 2] == UInt8(ascii: "."), pattern[pattern.count - 1] == UInt8(ascii: "*") {
            return glob(pattern.dropLast(2), name)
        }
        if pattern.last == UInt8(ascii: ".") { return glob(pattern.dropLast(), name) }
        return false
    }

    private static func glob(_ pattern: ArraySlice<UInt8>, _ name: UnsafeBufferPointer<UInt8>) -> Bool {
        func lower(_ byte: UInt8) -> UInt8 { byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte }
        var (p, n) = (pattern.startIndex, 0)
        var star: Int?
        var mark = n
        while n < name.count {
            if p < pattern.endIndex, pattern[p] == UInt8(ascii: "?") || pattern[p] == lower(name[n]) {
                p += 1
                n += 1
            } else if p < pattern.endIndex, pattern[p] == UInt8(ascii: "*") {
                star = p
                mark = n
                p += 1
            } else if let star {
                p = star + 1
                mark += 1
                n = mark
            } else {
                return false
            }
        }
        while p < pattern.endIndex, pattern[p] == UInt8(ascii: "*") { p += 1 }
        return p == pattern.endIndex
    }

    /// The usual two-pointer match: linear in practice, without recursion.
    private static func glob(_ pattern: ArraySlice<Character>, _ name: ArraySlice<Character>) -> Bool {
        var (p, n) = (pattern.startIndex, name.startIndex)
        var star: Int?
        var mark = n
        while n < name.endIndex {
            if p < pattern.endIndex, pattern[p] == "?" || pattern[p] == name[n] {
                p += 1
                n += 1
            } else if p < pattern.endIndex, pattern[p] == "*" {
                star = p
                mark = n
                p += 1
            } else if let star {
                p = star + 1
                mark += 1
                n = mark
            } else {
                return false
            }
        }
        while p < pattern.endIndex, pattern[p] == "*" { p += 1 }
        return p == pattern.endIndex
    }

    /// Applies a rename mask to a name, part by part (name and extension): a letter replaces
    /// the letter at its place, `?` keeps it and `*` keeps the rest. `*.cr2` turns
    /// `IMG_1057.JPG` into `IMG_1057.cr2`, `crw*.cr2` into `crw_1057.cr2`.
    static func rename(_ name: String, with mask: String) -> String {
        func apply(_ mask: String, to source: String) -> String {
            let source = Array(source)
            var result = ""
            var position = 0
            for character in mask {
                switch character {
                case "*":
                    if position < source.count { result += String(source[position...]) }
                    position = source.count
                case "?":
                    if position < source.count { result.append(source[position]) }
                    position += 1
                default:
                    result.append(character)
                    position += 1
                }
            }
            return result
        }
        let (maskBase, maskExt) = FileItem.split(mask)
        let (base, ext) = FileItem.split(name)
        let newExt = apply(maskExt, to: ext)
        return apply(maskBase, to: base) + (newExt.isEmpty ? "" : "." + newExt)
    }
}
