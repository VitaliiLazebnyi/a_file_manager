public import AFMKernel
public import Foundation

/// Turns a search into a question for Spotlight's index (in place of the spec's *Everything*,
/// 09 › Everything integration). Spotlight answers the parts it knows (names, plain text,
/// sizes, dates) at once; whatever it returns is then checked against all criteria, as the
/// spec has it for Everything. Nothing here touches a file system except `verify`.
public enum SpotlightQuery {
    /// Whether the index can be asked at all: the start directories are on local disks and
    /// the search is not limited to chosen items.
    public static func isAvailable(for query: SearchQuery) -> Bool {
        query.onlyItems == nil && query.directories.allSatisfy(\.isFileURL)
    }

    /// Whether the index answers the text criterion. A regular expression, hex bytes and "NOT
    /// containing" are beyond it; the files it returns are then read like in a normal search.
    public static func handlesText(of query: SearchQuery) -> Bool {
        !query.text.isEmpty && !query.textOptions.regex && !query.textOptions.hex && !query.textOptions.notContaining
    }

    /// Whether the files the index returns are read for the text all the same. The index
    /// holds the words of a text, as Unicode, and does not tell upper from lower case reliably: a
    /// "Case sensitive" search, one in other encodings and one for more than a word (a phrase,
    /// punctuation) are only narrowed down by it.
    public static func recheckingText(of query: SearchQuery) -> Bool {
        guard handlesText(of: query) else { return false }
        return query.caseSensitive || query.textOptions.encodings.contains { $0 != .utf8 }
            || TextPattern.unescape(query.text).contains { !$0.isLetter && !$0.isNumber }
    }

    /// The question in Spotlight's own query language. It may find more than the search asks
    /// for (a `?` in a mask is asked as `*`), never less.
    public static func string(for query: SearchQuery, now: Date = Date()) -> String {
        var parts: [String] = []
        if !query.namesAreRegex {
            let mask = SearchMask(query.names)
            func name(_ comparison: String, _ pattern: String) -> String {
                "kMDItemFSName \(comparison) \"\(escape(pattern.replacingOccurrences(of: "?", with: "*"), keepingStars: true))\"c"
            }
            let included = mask.include.filter { $0 != "*.*" && $0 != "*" }
            // `name.*` also finds `name`, which the index would not return for it.
            let reachesBareNames = mask.include.contains { $0.hasSuffix(".*") || $0.hasSuffix(".") }
            if !included.isEmpty, included.count == mask.include.count, !reachesBareNames {
                parts.append("(" + included.map { name("==", $0) }.joined(separator: " || ") + ")")
            }
            parts += mask.exclude.filter { $0 != "*.*" && $0 != "*" }.map { name("!=", $0) }
        }
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
            case .greater: parts.append("kMDItemFSSize > \(bytes)")
            case .less: parts.append("kMDItemFSSize < \(bytes)")

            case .equal:
                parts.append("(kMDItemFSSize >= \(bytes) && kMDItemFSSize < \(size.upperBytes))")
            }
        }
        let formatter = ISO8601DateFormatter()
        func date(_ comparison: String, _ value: Date) -> String {
            "kMDItemFSContentChangeDate \(comparison) $time.iso(\(formatter.string(from: value)))"
        }
        if let from = query.criteria.dateFrom { parts.append(date(">=", from)) }
        if let to = query.criteria.dateTo { parts.append(date("<=", to)) }
        if let age = query.criteria.notOlderThan { parts.append(date(">=", age.cutoff(before: now))) }
        if let age = query.criteria.olderThan { parts.append(date("<", age.cutoff(before: now))) }
        return parts.isEmpty ? "kMDItemFSName == \"*\"" : parts.joined(separator: " && ")
    }

    private static func escape(_ text: String, keepingStars: Bool) -> String {
        var result = ""
        for character in text {
            if character == "\\" || character == "\"" || (character == "*" && !keepingStars) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// Checks what the index returned against the whole search: location below a start
    /// directory within the depth, hidden files, and every criterion (the text only where the
    /// index could not answer it). Returns the hits in path order.
    ///
    /// **Threading.** Blocks on the file system and examines the files on all cores; meant for
    /// a background thread.
    public static func verify(_ paths: [String], with search: FileSearch, fileSystems: FileSystemRegistry) -> [FileItem]
    {
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
            else { return nil }
            // Cut at the `/` bytes, as the file system reads the path (a `/` with a combining
            // mark after it is one character that is not `/`).
            let below = Array(path.dropFirst(prefixes[match].count).utf8).split(separator: 0x2F)
            if let depth = query.maxDepth, below.count - 1 > depth { return nil }
            if !query.includeHidden, below.contains(where: { $0.first == 0x2E }) { return nil }
            guard let item = fileSystems.item(at: URL(fileURLWithPath: path, isDirectory: false)),
                query.includeHidden || !item.isHidden,
                search.accepts(item, checkingText: checkingText)
            else { return nil }
            return item
        }
        guard !search.cancellation.isCancelled else { return [] }
        return Sorter.sorted(hits.compactMap { $0 }, numeric: true) { $0.url.path }
    }
}

/// One question to Spotlight. The question is started on the main thread; the system then
/// gathers the answer on its own and delivers it on a queue of ours, where the paths are read
/// out of the result (a million of them take seconds), and `completion` is called on the main
/// thread with the paths found. Reading and checking the files afterwards is the caller's
/// business and belongs in the background.
///
/// `completion` and `isStopped` are guarded by `lock`. The metadata query is set up in `init`
/// and started on the main thread; after that only `queue` touches it.
final class SpotlightSearch: NSObject, SpotlightQuestion, @unchecked Sendable {
    /// The most paths read out of one answer.
    static let resultLimit = 1_000_000

    private let metadataQuery = NSMetadataQuery()
    private let queue: OperationQueue
    private let lock = NSLock()
    private var completion: (@MainActor @Sendable ([String], Bool) -> Void)?
    private var isStopped = false

    /// The most paths read out of this answer.
    let limit: Int

    /// `string` is a question in Spotlight's language, as `SpotlightQuery.string` makes it (the
    /// system stops the program at one it cannot read). The answer is read on `queue` (tests hold
    /// it, to choose what comes first).
    init(
        _ string: String,
        scopes: [URL],
        limit: Int = SpotlightSearch.resultLimit,
        queue: OperationQueue = OperationQueue()
    ) {
        let predicate = NSPredicate(fromMetadataQueryString: string)
        self.queue = queue
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        metadataQuery.predicate = predicate
        metadataQuery.searchScopes = scopes
        // The answer is delivered, and read, on this queue and not on the main run loop.
        metadataQuery.operationQueue = queue
        self.limit = limit
        super.init()
    }

    /// `completion` gets the paths and whether the answer was cut at `resultLimit`. A question
    /// that was stopped is not started again.
    func start(completion: @escaping @MainActor @Sendable ([String], Bool) -> Void) {
        lock.lock()
        self.completion = completion
        lock.unlock()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(finished),
            name: .NSMetadataQueryDidFinishGathering,
            object: metadataQuery
        )
        if !metadataQuery.start() { queue.addOperation { [weak self] in self?.finished() } }
    }

    /// Ends the question without an answer. May be called from the main thread while the paths
    /// are being read: the reading notices at its next piece.
    func stop() {
        lock.lock()
        isStopped = true
        completion = nil
        lock.unlock()
        NotificationCenter.default.removeObserver(self)
        // On the queue the answer is read on, after any reading in progress.
        // Handed to `queue`, the only one that touches the query once it has started.
        let metadataQuery = Handover(metadataQuery)
        queue.addOperation { metadataQuery.value.stop() }
    }

    private var stopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopped
    }

    /// Runs on `queue`.
    @objc private func finished() {
        metadataQuery.disableUpdates()
        var paths: [String] = []
        let total = metadataQuery.resultCount
        let count = min(total, limit)
        paths.reserveCapacity(count)
        var index = 0
        while index < count, !stopped {
            // The attribute values are autoreleased objects: a piece at a time.
            autoreleasepool {
                for item in index..<min(index + 5_000, count) {
                    if let path = (metadataQuery.result(at: item) as? NSMetadataItem)?
                        .value(
                            forAttribute: NSMetadataItemPathKey
                        ) as? String
                    {
                        paths.append(path)
                    }
                }
            }
            index += 5_000
        }
        lock.lock()
        // Nil once stopped (`stop` lets go of it) or told already.
        let completion = self.completion
        self.completion = nil
        isStopped = true
        lock.unlock()
        NotificationCenter.default.removeObserver(self)
        metadataQuery.stop()
        guard let completion else { return }
        DispatchQueue.main.async { [paths] in completion(paths, total > count) }
    }
}
