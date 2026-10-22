public import AFMKernel
public import Foundation

/// The "Search for" field of Find Files (spec 09 › "Search for"): masks separated by spaces,
/// exclude masks after `|`.
///
/// A word without wildcards and without a dot matches anywhere in the name; a name with a dot must
/// match exactly. A name with spaces is written in quotes, or as it is when nothing else is in the
/// field. With `regex`, the whole field is one regular expression for the name, without regard to
/// case. Unchecked: immutable, and `NSRegularExpression` may match on several threads at once.
public struct SearchMask: @unchecked Sendable {
    /// The masks in wildcard form (`*` and `?` only), lowercased.
    let include: [String]
    let exclude: [String]
    private let includeCharacters: [[Character]]
    private let excludeCharacters: [[Character]]
    private let expression: NSRegularExpression?
    /// Counts the names a regular expression ran out of time on.
    let trip = RegexTrip()
    /// False when the field was to be a regular expression and is not one; nothing matches then.
    public let isValid: Bool

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
            let token = token.lowercased()
            let isPlainWord = !token.contains("*") && !token.contains("?") && !token.contains(".")
            return isPlainWord ? "*\(token)*" : token
        }
        func patterns(_ part: Substring?) -> [String] {
            Self.tokens(String(part ?? "")).map(pattern)
        }
        var included = patterns(parts.first)
        // `Letter to Mr. Smith.doc` typed as it is: the whole field is tried as one name too.
        let whole = text.trimmingCharacters(in: .whitespaces)
        if parts.count == 1, included.count > 1, !whole.contains("\"") { included.append(pattern(whole)) }
        include = included
        exclude = patterns(parts.count > 1 ? parts[1] : nil)
        includeCharacters = include.map { Array($0) }
        excludeCharacters = exclude.map { Array($0) }
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
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    public func matches(_ name: String) -> Bool {
        matches(name, cancelled: { false })
    }

    /// `cancelled` ends a regular expression that is still working on a name.
    ///
    /// A name the expression takes too long for does not match.
    func matches(_ name: String, cancelled: () -> Bool) -> Bool {
        guard isValid else {
            return false
        }
        if let expression {
            return FindRegex.matches(expression, in: name, trip: trip, cancelled: cancelled)
        }
        let name = Array(name.lowercased())
        func hit(_ pattern: [Character]) -> Bool { Self.wildcard(pattern, name) }
        return (includeCharacters.isEmpty || includeCharacters.contains(where: hit))
            && !excludeCharacters.contains(where: hit)
    }

    /// `*` and `?` as file masks use them, character by character (so a composed and a
    /// decomposed `é` are the same, and `[` is just a bracket). `*.*` matches every name;
    /// `name.*` and `name.` also match `name` without an extension, as under DOS.
    static func wildcard(_ pattern: [Character], _ name: [Character]) -> Bool {
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
}

/// Everything a search is told (spec 09 › General tab, Advanced tab, Plugins tab).
///
/// All criteria that are set must hold.
public struct SearchQuery: Sendable {
    /// The first (and usually only) start directory.
    public var directory: URL
    /// Further start directories: "Search in" takes several, separated by `;`.
    public var moreDirectories: [URL] = []
    /// "Only search in selected directories/files" and "Search in found files": when set, the
    /// search covers these items instead of the start directories.
    ///
    /// Files are tested themselves; folders are searched inside, or, with a depth of 0, tested
    /// themselves.
    public var onlyItems: [URL]?
    /// "Search for"; empty finds everything.
    public var names: String
    /// "Search for" is one regular expression.
    public var namesAreRegex = false
    /// "Find text"; empty means no content search.
    public var text: String
    public var caseSensitive: Bool
    public var textOptions = TextSearchOptions()
    /// Hidden files are found, and hidden folders searched, only while the panels show them.
    public var includeHidden: Bool
    /// `nil` = all subdirectories, 0 = the start directory only.
    public var maxDepth: Int?
    public var criteria = FileCriteria()
    public var fieldRules = FieldRules()
    /// Archives are searched like folders, as far as a file system offers their contents.
    public var searchArchives = false
    public var duplicates = DuplicateOptions()
    /// The most hits a run reports; it stops there and says so (`FileSearch.reachedResultLimit`).
    ///
    /// `nil` takes all. A search of a whole disk with an open mask would otherwise keep every file
    /// of it in memory.
    public var resultLimit: Int?

    public init(
        directory: URL,
        names: String = "",
        text: String = "",
        caseSensitive: Bool = false,
        includeHidden: Bool = false,
        maxDepth: Int? = nil
    ) {
        self.directory = directory
        self.names = names
        self.text = text
        self.caseSensitive = caseSensitive
        self.includeHidden = includeHidden
        self.maxDepth = maxDepth
    }

    /// The start directories without those that are searched anyway: a repeated one, and, when
    /// all subdirectories are searched, one that lies inside another.
    public var directories: [URL] {
        let all = [directory] + moreDirectories
        return all.enumerated()
            .filter { index, url in
                !all.enumerated()
                    .contains { other, outer in
                        other != index
                            && (url.isSameLocation(as: outer) ? other < index : maxDepth == nil && url.isInside(outer))
                    }
            }
            .map(\.element)
    }
}

/// One Find Files run (spec 09 › Running a search).
///
/// **Threading.** `run` blocks and is meant for a background thread; its callbacks are called
/// on that thread, one at a time and in path order. The work is spread over a few threads of
/// the search's own: they list the folders, apply the name mask before anything is sorted, and
/// test the files of all folders together for text and field values; the hits are reported in
/// order as the files become ready (the tested start of a folder's list is reported while the
/// rest is still being tested). A folder met twice (same device and inode) is searched once,
/// whichever of the start directories comes first. Everything the search holds is immutable
/// after `init` (except counters behind their own locks), so `accepts` may be called from
/// several threads at once. `cancel()` may be called from any thread.
///
/// **Memory.** The listing of folders ahead of the one being reported is held back while a
/// budget of listed but not yet reported entries is used up, so that a slow front job (a huge
/// file, a stalled share) does not let the other threads read the whole tree into memory.
///
/// Safe to share as said above: `limitReached` is guarded by `limitLock`; the rest is fixed in
/// `init`.
public final class FileSearch: @unchecked Sendable {
    public let query: SearchQuery
    public let cancellation = CancellationFlag()
    /// Why the search cannot run as asked (a text that is no hex string, a broken regular
    /// expression); `run` then finds nothing.
    ///
    /// Whoever starts a search shows it first.
    public let problem: any Error?
    private let fileSystems: FileSystemRegistry
    private let mask: SearchMask
    private let pattern: TextPattern?
    private let fields: [String: SearchField]
    private let fieldRules: PreparedFieldRules
    private let fieldTrip = RegexTrip()
    /// The criteria of the Advanced tab with their moments worked out; nil when none is set.
    private let criteria: PreparedCriteria?
    /// The moment the search was made: "not older than" is measured from here for every file.
    private let now: Date
    private let limitLock = NSLock()
    private var limitReached = false

    /// File names that may be archives; only these are offered to the file systems.
    static let archiveExtensions: Set<String> = [
        "zip", "jar", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "7z", "rar", "cab", "lzh", "arj"
    ]

    /// The listed but not yet reported entries that hold back the listing of further folders.
    static let candidateBudget = 200_000
    /// The budget this search works to; tests make it small.
    let budget: Int
    /// The files a duplicate search collects before it stops and says so.
    static let duplicateCandidateLimit = 3_000_000

    public convenience init(
        _ query: SearchQuery,
        fileSystems: FileSystemRegistry,
        columns: ColumnRegistry? = nil,
        now: Date = Date()
    ) {
        self.init(query, fileSystems: fileSystems, columns: columns, now: now, tuning: Tuning())
    }

    /// What tests make small.
    struct Tuning {
        var budget = FileSearch.candidateBudget
        var partialListingAfter = FileSearch.defaultPartialListingAfter
        /// How many threads list folders and test files: one walks in a fixed order.
        var threads = FileSearch.threadCount
        /// What tells that two locations are one folder: the device and file number of a local
        /// one, nil for others (which are never taken for each other).
        var identity: @Sendable (URL) -> FileIdentity? = { FileIdentity.of($0)?.identity }
    }

    /// The threads of a search: all cores, and at least four for a slow disk or server.
    static let threadCount = max(4, ProcessInfo.processInfo.activeProcessorCount)
    /// See `Tuning`.
    let threads: Int
    /// See `Tuning`.
    let folderIdentity: @Sendable (URL) -> FileIdentity?

    init(
        _ query: SearchQuery,
        fileSystems: FileSystemRegistry,
        columns: ColumnRegistry? = nil,
        now: Date = Date(),
        tuning: Tuning
    ) {
        (budget, partialListingAfter) = (tuning.budget, tuning.partialListingAfter)
        (threads, folderIdentity) = (tuning.threads, tuning.identity)
        self.query = query
        self.fileSystems = fileSystems
        self.now = now
        mask = SearchMask(query.names, regex: query.namesAreRegex)
        criteria = query.criteria.prepared(now: now)
        fields = Dictionary(
            SearchField.all(fileSystems: fileSystems, columns: columns).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        fieldRules = query.fieldRules.prepared(trip: fieldTrip)
        var problem: any Error? = mask.isValid ? nil : TextPattern.Problem.badRegex(query.names)
        if problem == nil, let rule = query.fieldRules.unusableRule {
            problem = TextPattern.Problem.badRegex(rule.value)
        }
        var pattern: TextPattern?
        if !query.text.isEmpty {
            do {
                pattern = try TextPattern(query.text, caseSensitive: query.caseSensitive, options: query.textOptions)
            } catch {
                problem = problem ?? error
            }
        }
        (self.pattern, self.problem) = (pattern, problem)
    }

    public func cancel() {
        cancellation.cancel()
    }

    /// Whether a regular expression of the search (the name, the text, a rule of the Plugins
    /// tab) ran out of time on some name or file: those were taken as not matching.
    public var regexTimedOut: Bool {
        mask.trip.hasTimedOut || fieldTrip.hasTimedOut || pattern?.trip.hasTimedOut == true
    }

    /// Whether the run stopped at `query.resultLimit`; more hits would have followed.
    public var reachedResultLimit: Bool {
        limitLock.lock()
        defer { limitLock.unlock() }
        return limitReached
    }

    /// Walks the trees; the hits come in path order: the matching entries of a folder by name,
    /// then its subfolders one after the other.
    ///
    /// `onDirectory` reports the folder being searched, `onMatch` each hit. With a text to find,
    /// only files can match.
    public func run(onDirectory: (URL) -> Void = { _ in }, onMatch: (FileItem) -> Void) {
        runWalk(limit: query.resultLimit, onDirectory: onDirectory, onMatch: onMatch)
    }

    private func runWalk(limit: Int?, onDirectory: (URL) -> Void, onMatch: (FileItem) -> Void) {
        guard problem == nil else {
            return
        }
        let walk = Walk(self)
        var roots: [Walk.Node] = []
        // The tree is let go of on another thread: a cancelled search may hold a million entries.
        defer {
            // This thread lets go of them here: nothing else holds them any more.
            let dropped = Handover((walk.close(), roots))
            DispatchQueue.global(qos: .utility).async { withExtendedLifetime(dropped) {} }
        }
        if let only = query.onlyItems {
            let items =
                Parallel.map(only) { url -> FileItem? in
                    guard !self.cancellation.isCancelled else {
                        return nil
                    }
                    return (try? self.fileSystems.provider(for: url))?.item(at: url, cancellation: self.cancellation)
                }
                .compactMap { $0 }
            guard !cancellation.isCancelled else {
                return
            }
            let searchedInside = { (item: FileItem) in item.isRealDirectory && self.query.maxDepth != 0 }
            let folders = items.filter(searchedInside)
            // A file listed beside a folder that holds it is found by searching the folder. With
            // a depth limit only the folder's own files are sure to be reached; what lies deeper
            // may be (the results are told apart below). The folders are looked up as a set and
            // each item's parents are walked up, not every item compared with every folder.
            let folderKeys = Set(folders.map { $0.url.locationKey })
            let reached = { (item: FileItem) -> Bool in
                guard !folderKeys.isEmpty else {
                    return false
                }
                var url = item.url
                for _ in 0..<(self.query.maxDepth == nil ? max(url.pathComponents.count, 1) : 1) {
                    url = url.deletingLastPathComponent()
                    if folderKeys.contains(url.locationKey) {
                        return true
                    }
                }
                return false
            }
            var own: [FileItem] = []
            for item in items where !cancellation.isCancelled {
                // The name goes first, it rejects most and costs least.
                if !searchedInside(item), passesQuickChecks(item), !reached(item) { own.append(item) }
            }
            roots.append(walk.makeNode(files: pattern == nil ? own : own.filter { !$0.isDirectory }))
            roots += folders.map { walk.makeNode(directory: $0.url, depth: 1) }
        } else {
            roots = query.directories.map { walk.makeNode(directory: $0, depth: 0) }
        }
        walk.start(roots)
        // Roots that overlap (nested ones kept for their depth, files and folders chosen
        // together) can reach a file twice: it is reported once. The same folder reached by two
        // roads (a firmlink) is one place; two names for one file in one folder (hard links)
        // are two files.
        var reported = Set<String>()
        var parents: [String: FileIdentity?] = [:]
        func reportKey(_ item: FileItem) -> String {
            guard item.url.isFileURL else {
                return Self.locationKey(of: item.url)
            }
            let parent = item.url.deletingLastPathComponent()
            let identity: FileIdentity?
            if let known = parents[parent.path] {
                identity = known
            } else {
                identity = FileIdentity.of(parent)?.identity
                parents[parent.path] = .some(identity)
            }
            guard let identity else {
                return item.url.locationKey
            }
            return "\(identity.device):\(identity.inode)/\(item.url.lastPathComponent)"
        }
        let overlapping = query.onlyItems != nil || roots.count > 1
        var count = 0
        for root in roots {
            walk.deliver(root, onDirectory: onDirectory) { item in
                if overlapping, !reported.insert(reportKey(item)).inserted {
                    return
                }
                if let limit, count >= limit {
                    limitLock.lock()
                    limitReached = true
                    limitLock.unlock()
                    walk.stop()
                    return
                }
                count += 1
                onMatch(item)
            }
            if walk.isStopped { break }
        }
    }

    /// A place by its location, with the host in lower case and no trailing slash: two ways of
    /// writing the same remote place (`sftp://HOST/a`, `sftp://host/a/`) are one key.
    static func locationKey(of url: URL) -> String {
        var key = url.locationKey
        if let host = url.host, !host.isEmpty, let range = key.range(of: "://" + host) {
            key.replaceSubrange(range, with: "://" + host.lowercased())
        }
        return key
    }

    /// From this many entries seen in one folder on, what has passed the quick checks is
    /// reported in parts while the listing goes on (each part in name order).
    static let defaultPartialListingAfter = 100_000
    /// Tests make it small.
    let partialListingAfter: Int

    /// Runs the search and returns the files that are duplicates of each other, in groups
    /// (spec 09 › Duplicate finder); empty when the search was cancelled.
    ///
    /// The files are all held while they are compared, so a search stops at
    /// `duplicateCandidateLimit` of them and says so (`reachedResultLimit`).
    public func runForDuplicates(
        onDirectory: (URL) -> Void = { _ in },
        onHashing: (@Sendable (Int, Int) -> Void)? = nil
    )
        -> [[FileItem]]
    {
        var files: [FileItem] = []
        runWalk(
            limit: min(query.resultLimit ?? Int.max, Self.duplicateCandidateLimit),
            onDirectory: onDirectory
        ) {
            if !$0.isDirectory { files.append($0) }
        }
        return DuplicateFinder.groups(
            of: files,
            options: query.duplicates,
            fileSystems: fileSystems,
            cancellation: cancellation,
            onProgress: onHashing
        )
    }

    /// Whether an item found by other means (Spotlight) passes the criteria.
    ///
    /// Without `checkingText` the text criterion is taken as met. Blocks like the search itself.
    public func accepts(_ item: FileItem, checkingText: Bool = true) -> Bool {
        problem == nil && passesQuickChecks(item) && (checkingText && pattern != nil ? !item.isDirectory : true)
            && passesSlowChecks(item, checkingText: checkingText)
    }

    /// What can be told from the directory entry alone; the name is tried first, it is the
    /// cheapest and rejects most.
    private func passesQuickChecks(_ item: FileItem) -> Bool {
        mask.matches(item.name, cancelled: { self.cancellation.isCancelled }) && (criteria?.matches(item) ?? true)
    }

    /// Field rules and text: both may read the file, so they run on all cores.
    private func passesSlowChecks(_ item: FileItem, checkingText: Bool = true) -> Bool {
        guard !cancellation.isCancelled,
            fieldRules.matches(item, fields: fields, cancelled: { self.cancellation.isCancelled })
        else { return false }
        guard checkingText, let pattern else {
            return true
        }
        // A FIFO would block the open for good, /dev/zero would never end, a cloud stub would
        // be downloaded; a local file is opened without waiting and looked at once opened.
        guard !item.isSpecial, let reader = fileSystems.searchReader(for: item.url, cancellation: cancellation) else {
            return false
        }
        defer { reader.close() }
        // A read blocked on a server ends when the search is cancelled.
        let token = cancellation.interrupting(reader)
        defer { withExtendedLifetime(token) {} }
        return autoreleasepool { pattern.accepts(reader, cancellation: cancellation) }
    }

    /// The walk of one `run`: a few threads list folders and test the files found, all from
    /// one stack of jobs (the job that comes last in path order is on the bottom), while the
    /// calling thread hands the results out in path order as they become ready.
    ///
    /// The shared state is the folder tree below, which the walk's condition protects.
    private final class Walk {
        /// One folder (or, without a URL, a plain list of files): what it holds that passed
        /// the quick checks, which of these passed the slow ones, and its subfolders.
        final class Node {
            let url: URL?
            let depth: Int
            var isListed = false
            /// Nothing more will be added to `candidates` (a listing that is reported in parts
            /// is complete); set together with `isListed` for a folder that is not.
            var isFinal = false
            var candidates: [FileItem] = []
            /// Per candidate: 0 not tested yet, 1 not a hit, 2 a hit. `nil` while every candidate is a hit.
            var state: [UInt8]?
            var children: [Node] = []
            /// Jobs not yet done: the listing, then the tests.
            var pending = 1
            /// A start directory that is a place another start directory covers (see `start`).
            var isDuplicateRoot = false
            var isClaimed = false

            init(url: URL?, depth: Int) {
                self.url = url
                self.depth = depth
            }
        }

        private let search: FileSearch
        private let condition = NSCondition()
        private let jobs = JobStack()
        private var visited: [FileIdentity: Int] = [:]
        private let visitedLock = NSLock()
        /// Counts what is listed and not yet reported, and what the reporting thread waits for.
        ///
        /// A leaf lock: nothing else is taken while it is held (the job stack and `deliver` ask it
        /// from inside their own).
        private let budgetLock = NSLock()
        private var undelivered = 0
        private var needed: Node?
        private var stopped = false

        init(_ search: FileSearch) {
            self.search = search
            jobs.shouldHold = { [weak self] job in self?.shouldHold(job) == true }
        }

        /// Ends the walk early (the result limit): what is left is dropped.
        func stop() {
            budgetLock.lock()
            stopped = true
            budgetLock.unlock()
            _ = jobs.close()
            condition.lock()
            condition.broadcast()
            condition.unlock()
        }

        var isStopped: Bool {
            if search.cancellation.isCancelled {
                return true
            }
            budgetLock.lock()
            defer { budgetLock.unlock() }
            return stopped
        }

        /// Drops the jobs that are left and returns them, to be let go of on another thread.
        func close() -> Any {
            jobs.close()
        }

        /// A folder listing waits while a lot is listed and unreported already, unless the
        /// reporting thread is waiting for exactly this one.
        private func shouldHold(_ job: JobStack.Job) -> Bool {
            guard job.isListing else {
                return false
            }
            budgetLock.lock()
            defer { budgetLock.unlock() }
            return undelivered >= search.budget && job.node !== needed
        }

        private func adjust(undelivered change: Int) {
            budgetLock.lock()
            undelivered += change
            budgetLock.unlock()
        }

        private func setNeeded(_ node: Node?) {
            budgetLock.lock()
            needed = node
            budgetLock.unlock()
        }

        func makeNode(directory: URL, depth: Int) -> Node {
            Node(url: directory, depth: depth)
        }

        func makeNode(files: [FileItem]) -> Node {
            let node = Node(url: nil, depth: 0)
            node.candidates = files
            return node
        }

        func start(_ roots: [Node]) {
            // The start directories claim their places in order, so that of two that are one
            // place (a firmlink), the first is searched, whichever thread is quicker.
            for root in roots {
                guard let url = root.url else { continue }
                root.isDuplicateRoot = !claim(url, depth: root.depth)
                root.isClaimed = true
            }
            jobs.start(threads: search.threads)
            var first: [JobStack.Job] = []
            for root in roots {
                if root.url == nil {
                    first += publish(root, candidates: root.candidates, children: [])
                } else {
                    first.append(JobStack.Job(node: root, isListing: true) { self.list(root) })
                }
            }
            jobs.push(first)
        }

        /// Reports each folder in turn: the folder, then what of its entries is ready, in
        /// order, while the rest is still being tested, then its subfolders.
        ///
        /// Returns early when cancelled or stopped.
        func deliver(_ root: Node, onDirectory: (URL) -> Void, onMatch: (FileItem) -> Void) {
            var stack = [root]
            while let node = stack.popLast() {
                condition.lock()
                setNeeded(node)
                while !node.isListed, node.pending > 0, !isStopped {
                    condition.wait(until: Date(timeIntervalSinceNow: 0.05))
                }
                setNeeded(nil)
                let isListed = node.isListed
                condition.unlock()
                guard !isStopped, isListed else {
                    if isStopped {
                        return
                    }
                    continue
                }
                if let url = node.url { onDirectory(url) }
                var index = 0
                while true {
                    condition.lock()
                    // A folder that is listed in parts grows while it is reported.
                    let total = node.candidates.count
                    var end = index
                    var flags: [UInt8] = []
                    if let state = node.state {
                        while end < total, state[end] != 0 { end += 1 }
                        flags = Array(state[index..<end])
                    } else {
                        end = total
                    }
                    let batch = end > index ? Array(node.candidates[index..<end]) : []
                    if end == index {
                        let finished = node.isFinal && index >= total
                        if !finished, !isStopped { condition.wait(until: Date(timeIntervalSinceNow: 0.05)) }
                        condition.unlock()
                        if isStopped {
                            return
                        }
                        if finished { break }
                        continue
                    }
                    condition.unlock()
                    adjust(undelivered: -(end - index))
                    for offset in 0..<(end - index) where flags.isEmpty || flags[offset] == 2 {
                        if isStopped {
                            return
                        }
                        onMatch(batch[offset])
                    }
                    index = end
                }
                condition.lock()
                node.candidates = []
                node.state = nil
                let children = node.children
                node.children = []
                condition.unlock()
                stack.append(contentsOf: children.reversed())
            }
        }

        /// Whether this folder is still to be searched; a folder met a second time by another
        /// road (a firmlink, an overlapping start directory) is left out, unless it is met
        /// nearer to a start directory, where a depth limit lets the search go deeper.
        private func claim(_ url: URL, depth: Int) -> Bool {
            guard let identity = search.folderIdentity(url) else {
                return true
            }
            visitedLock.lock()
            defer { visitedLock.unlock() }
            guard let before = visited[identity], search.query.maxDepth != nil else {
                return visited.updateValue(depth, forKey: identity) == nil
            }
            // Met nearer to a start directory: searched again, deeper.
            if depth < before {
                visited[identity] = depth
                return true
            }
            return false
        }

        private func finishJob(of node: Node) {
            condition.lock()
            node.pending -= 1
            if node.pending == 0 { condition.broadcast() }
            condition.unlock()
        }

        private func list(_ node: Node) {
            guard let url = node.url, !isStopped, !node.isDuplicateRoot,
                node.isClaimed || claim(url, depth: node.depth),
                let provider = try? search.fileSystems.provider(for: url)
            else {
                finishJob(of: node)
                return
            }
            let descend = search.query.maxDepth.map { node.depth < $0 } ?? true
            var wanted: [FileItem] = []
            var subfolders: [(name: String, url: URL)] = []
            // A folder of very many entries is reported in parts, as the listing comes in, each part
            // in name order, so that the first hit does not wait for the last entry.
            var seen = 0
            var isStreaming = false
            func sortedByName(_ items: inout [FileItem]) {
                items = Sorter.sorted(items, byName: \.name)
            }
            // Each batch is looked at as it arrives, so the whole listing of a big folder is
            // never in memory at once; only what passed the quick checks is kept.
            do {
                try provider.list(url, showHidden: search.query.includeHidden, cancellation: search.cancellation) {
                    batch in
                    for entry in batch {
                        if search.passesQuickChecks(entry), search.pattern == nil || !entry.isDirectory {
                            wanted.append(entry)
                        }
                        guard descend else { continue }
                        // Links to folders are found but not followed, so the search cannot run in circles.
                        if entry.isRealDirectory {
                            subfolders.append((entry.name, entry.url))
                        } else if search.query.searchArchives, !entry.isDirectory,
                            let inside = search.archiveRoot(of: entry, in: provider)
                        {
                            subfolders.append((entry.name, inside))
                        }
                    }
                    seen += batch.count
                    if isStreaming || seen >= search.partialListingAfter, !wanted.isEmpty, !isStopped {
                        isStreaming = true
                        sortedByName(&wanted)
                        jobs.push(publish(node, candidates: wanted, children: [], isFinal: false))
                        wanted = []
                    }
                    return !isStopped
                }
            } catch {
                guard isStreaming else {
                    return finishJob(of: node)
                }
                // What was reported stays; the folder ends here.
                jobs.push(publish(node, candidates: [], children: []))
                return
            }
            guard !isStopped else {
                isStreaming ? jobs.push(publish(node, candidates: [], children: [])) : finishJob(of: node)
                return
            }
            // Only what is reported needs an order, and only the matches are sorted.
            sortedByName(&wanted)
            subfolders = Sorter.sorted(subfolders, byName: \.name)
            let children = subfolders.map { Node(url: $0.url, depth: node.depth + 1) }
            // The tests of this folder go first: they are needed first.
            jobs.push(
                publish(node, candidates: wanted, children: children)
                    + children.map { child in JobStack.Job(node: child, isListing: true) { self.list(child) } }
            )
        }

        /// Makes a node's candidates and subfolders known, all at once under the lock (the
        /// reporting thread must never see them without the state that goes with them), and
        /// returns the jobs that test the candidates; the node's pending count is the number of
        /// them.
        ///
        /// Without slow criteria nothing is left to do.
        private func publish(_ node: Node, candidates: [FileItem], children: [Node], isFinal: Bool = true) -> [JobStack
            .Job]
        {
            let needed = search.pattern != nil || search.query.fieldRules.isActive
            let size = search.pattern == nil ? 32 : 4
            let ranges =
                needed
                ? stride(from: 0, to: candidates.count, by: size).map { $0..<min($0 + size, candidates.count) } : []
            adjust(undelivered: candidates.count)
            condition.lock()
            // The first part of a folder takes the place of the listing job in the count; later ones add to it.
            let isFirst = !node.isListed
            let base = isFirst ? 0 : node.candidates.count
            if isFirst { node.candidates = candidates } else { node.candidates.append(contentsOf: candidates) }
            if isFinal { node.children = children }
            if needed {
                if isFirst {
                    node.state = [UInt8](repeating: 0, count: candidates.count)
                } else {
                    node.state?.append(contentsOf: [UInt8](repeating: 0, count: candidates.count))
                }
            } else {
                node.state = nil
            }
            node.pending = (isFirst ? 0 : node.pending) + ranges.count
            node.isListed = true
            node.isFinal = isFinal
            condition.broadcast()
            condition.unlock()
            return ranges.map { range in
                JobStack.Job(node: node, isListing: false) {
                    let results = range.map { !self.isStopped && self.search.passesSlowChecks(candidates[$0]) }
                    self.condition.lock()
                    for (offset, index) in range.enumerated() { node.state?[base + index] = results[offset] ? 2 : 1 }
                    node.pending -= 1
                    self.condition.broadcast()
                    self.condition.unlock()
                }
            }
        }
    }

    /// Jobs for a few threads, taken from the top of a stack so that the work follows the
    /// order the results are wanted in.
    ///
    /// Closing drops what is left, and anything pushed after. `stack` and `isClosed` are guarded by
    /// `condition`; `shouldHold` is set once, before `start`.
    private final class JobStack: @unchecked Sendable {
        struct Job {
            let node: Node?
            /// Lists a folder (as opposed to testing entries).
            let isListing: Bool
            let run: () -> Void

            typealias Node = Walk.Node

            init(node: Node?, isListing: Bool, run: @escaping () -> Void) {
                self.node = node
                self.isListing = isListing
                self.run = run
            }
        }

        private let condition = NSCondition()
        private var stack: [Job] = []
        private var isClosed = false
        /// Asked about the job on top: true leaves it there for a while (the memory budget).
        var shouldHold: ((Job) -> Bool)?

        func start(threads: Int) {
            for _ in 0..<threads {
                let thread = Thread { [self] in work() }
                thread.qualityOfService = .userInitiated
                // The workers keep their stack frames small, but a regular expression or a
                // decoder deserves more than a thread's default.
                thread.stackSize = 4 << 20
                thread.start()
            }
        }

        /// `jobs[0]` is taken first.
        ///
        /// After `close` nothing is kept: a worker that was still listing a folder must not bring
        /// the walk back to life.
        func push(_ jobs: [Job]) {
            guard !jobs.isEmpty else {
                return
            }
            condition.lock()
            if !isClosed {
                stack.append(contentsOf: jobs.reversed())
                condition.broadcast()
            }
            condition.unlock()
        }

        /// Returns the jobs that were left.
        func close() -> Any {
            condition.lock()
            isClosed = true
            let dropped = stack
            stack = []
            condition.broadcast()
            condition.unlock()
            return dropped
        }

        private func work() {
            while let next = take() {
                autoreleasepool { next.run() }
            }
        }

        /// The next job, once there is one that is not held back; nil when the stack is closed.
        private func take() -> Job? {
            condition.lock()
            defer { condition.unlock() }
            while !isClosed {
                guard let top = stack.last else {
                    condition.wait()
                    continue
                }
                guard let shouldHold, shouldHold(top) else {
                    return stack.removeLast()
                }
                condition.wait(until: Date(timeIntervalSinceNow: 0.02))
            }
            return nil
        }
    }

    /// Where the contents of an archive file are listed: the location another file system
    /// reads out of the file's own, if any does.
    ///
    /// Works on the text alone.
    private func archiveRoot(of file: FileItem, in provider: any FileSystemProvider) -> URL? {
        guard Self.archiveExtensions.contains(FileItem.split(file.name).ext.lowercased()) else {
            return nil
        }
        let notations = [provider.displayPath(file.url), file.url.absoluteString]
        for other in fileSystems.all where other !== provider {
            if let url = notations.lazy.compactMap({ other.location(from: $0) }).first {
                return url
            }
        }
        return nil
    }
}
