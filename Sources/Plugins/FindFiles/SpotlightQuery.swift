public import AFMKernel
public import Foundation

/// Turns a search into a question for Spotlight's index (in place of the spec's *Everything*,
/// 09 › Everything integration).
///
/// Spotlight answers the parts it knows (names, plain text, sizes, dates) at once; whatever it
/// returns is then checked against all criteria, as the spec has it for Everything. Nothing here
/// touches a file system except `verify`.
public enum SpotlightQuery {
    /// Whether the index can be asked at all: the start directories are on local disks and
    /// the search is not limited to chosen items.
    public static func isAvailable(for query: SearchQuery) -> Bool {
        query.scope == .startDirectories && query.directories.allSatisfy(\.isFileURL)
    }

    /// Whether the index answers the text criterion.
    ///
    /// A regular expression, hex bytes and "NOT containing" are beyond it; the files it returns are
    /// then read like in a normal search.
    public static func handlesText(of query: SearchQuery) -> Bool {
        !query.text.isEmpty && !query.textOptions.regex && !query.textOptions.hex && !query.textOptions.notContaining
    }

    /// Whether the files the index returns are read for the text all the same.
    ///
    /// The index holds the words of a text, as Unicode, and does not tell upper from lower case
    /// reliably: a "Case sensitive" search, one in other encodings and one for more than a word (a
    /// phrase, punctuation) are only narrowed down by it.
    public static func recheckingText(of query: SearchQuery) -> Bool {
        guard handlesText(of: query) else {
            return false
        }
        return query.caseSensitive || query.textOptions.encodings.contains { $0 != .utf8 }
            || TextPattern.unescape(query.text).contains { !$0.isLetter && !$0.isNumber }
    }

    /// The question in Spotlight's own query language.
    ///
    /// It may find more than the search asks for (a `?` in a mask is asked as `*`), never less.
    public static func string(for query: SearchQuery, now: Date = Date()) -> String {
        var parts = query.namesAreRegex ? [] : nameParts(of: query)
        if handlesText(of: query) {
            let text = escape(TextPattern.unescape(query.text), keepingStars: false)
            let flags = query.caseSensitive ? "" : "cd"
            parts.append(
                query.textOptions.wholeWords
                    ? "kMDItemTextContent == \"\(text)\"\(flags)w" : "kMDItemTextContent == \"*\(text)*\"\(flags)"
            )
        }
        if let size = query.criteria.size {
            let bytes = size.bytes
            switch size.comparison {
            case .greater:
                parts.append("kMDItemFSSize > \(bytes)")

            case .less:
                parts.append("kMDItemFSSize < \(bytes)")

            case .equal:
                parts.append("(kMDItemFSSize >= \(bytes) && kMDItemFSSize < \(size.upperBytes))")
            }
        }
        parts += dateParts(of: query.criteria, now: now)
        return parts.isEmpty ? "kMDItemFSName == \"*\"" : parts.joined(separator: " && ")
    }

    /// Checks what the index returned against the whole search: location below a start
    /// directory within the depth, hidden files, and every criterion (the text only where the
    /// index could not answer it).
    ///
    /// Returns the hits in path order.
    ///
    /// **Threading.** Blocks on the file system and examines the files on all cores; meant for
    /// a background thread.
    public static func verify(
        _ paths: [String],
        with search: FileSearch,
        fileSystems: FileSystemRegistry
    ) -> [FileItem] {
        let query = search.query
        let checkingText = !handlesText(of: query) || recheckingText(of: query)
        // Spotlight answers with real paths and the volume may not tell upper from lower case:
        // a start directory typed in another case, or through a link, is still the same place.
        var roots: [String] = []
        for directory in query.directories {
            for path in [directory.standardizedFileURL.path, directory.resolvingSymlinksInPath().path]
            where !roots.contains(path) {
                roots.append(path)
            }
        }
        let prefixes = roots.map { ($0.hasSuffix("/") ? $0 : $0 + "/").lowercased() }
        let hits = Parallel.map(paths) { path -> FileItem? in
            guard !search.cancellation.isCancelled,
                let match = prefixes.firstIndex(where: { path.lowercased().hasPrefix($0) })
            else {
                return nil
            }
            // Cut at the `/` bytes, as the file system reads the path (a `/` with a combining
            // mark after it is one character that is not `/`).
            let below = Array(path.dropFirst(prefixes[match].count).utf8).split(separator: 0x2F)
            if let depth = query.maxDepth, below.count - 1 > depth {
                return nil
            }
            if !query.includeHidden, below.contains(where: { $0.first == 0x2E }) {
                return nil
            }
            guard let item = fileSystems.item(at: URL(fileURLWithPath: path, isDirectory: false)),
                query.includeHidden || !item.isHidden,
                search.accepts(item, checkingText: checkingText)
            else {
                return nil
            }
            return item
        }
        guard !search.cancellation.isCancelled else {
            return []
        }
        return Sorter.sorted(hits.compactMap(\.self), numeric: true) { $0.url.path }
    }

    /// The parts of the question that ask for the names: the masks, and the exclude masks.
    ///
    /// Masks that match every name ask nothing, and the masks are not asked at all when one of them also
    /// reaches names without an extension (the index would not return those); the exclude masks always are.
    private static func nameParts(of query: SearchQuery) -> [String] {
        let mask = SearchMask(query.names)
        func name(_ comparison: String, _ pattern: String) -> String {
            let asked = escape(pattern.replacingOccurrences(of: "?", with: "*"), keepingStars: true)
            return "kMDItemFSName \(comparison) \"\(asked)\"c"
        }
        var parts: [String] = []
        let included = mask.include.filter { $0 != "*.*" && $0 != "*" }
        // `name.*` also finds `name`, which the index would not return for it.
        let reachesBareNames = mask.include.contains { $0.hasSuffix(".*") || $0.hasSuffix(".") }
        if !included.isEmpty, included.count == mask.include.count, !reachesBareNames {
            parts.append("(" + included.map { name("==", $0) }.joined(separator: " || ") + ")")
        }
        return parts + mask.exclude.filter { $0 != "*.*" && $0 != "*" }.map { name("!=", $0) }
    }

    /// The parts of the question that ask for the dates of the Advanced tab, the ages counted back from `now`.
    private static func dateParts(of criteria: FileCriteria, now: Date) -> [String] {
        let formatter = ISO8601DateFormatter()
        func date(_ comparison: String, _ value: Date) -> String {
            "kMDItemFSContentChangeDate \(comparison) $time.iso(\(formatter.string(from: value)))"
        }
        var parts: [String] = []
        if let from = criteria.dateFrom {
            parts.append(date(">=", from))
        }
        if let until = criteria.dateTo {
            parts.append(date("<=", until))
        }
        if let age = criteria.notOlderThan {
            parts.append(date(">=", age.cutoff(before: now)))
        }
        if let age = criteria.olderThan {
            parts.append(date("<", age.cutoff(before: now)))
        }
        return parts
    }

    private static func escape(_ text: String, keepingStars: Bool) -> String {
        var result = ""
        for character in text {
            if character == "\\" || character == "\"" || (character == "*" && !keepingStars) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }
}
