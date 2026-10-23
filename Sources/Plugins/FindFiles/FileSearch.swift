public import AFMKernel
public import Foundation

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
    /// What tests make small.
    internal struct Tuning {
        /// The listed but not yet reported entries that hold back the listing of further folders.
        internal var budget = FileSearch.candidateBudget
        /// From this many entries of one folder on, the folder is reported in parts.
        internal var partialListingAfter = FileSearch.defaultPartialListingAfter
        /// How many threads list folders and test files: one walks in a fixed order.
        internal var threads = FileSearch.threadCount
        /// What tells that two locations are one folder: the device and file number of a local
        /// one, nil for others (which are never taken for each other).
        internal var identity: @Sendable (URL) -> FileIdentity? = { FileIdentity.of($0)?.identity }
    }

    /// The keys that tell whether a hit was reported already, when the roots of a run overlap.
    ///
    /// Roots that overlap (nested ones kept for their depth, files and folders chosen together) can reach a
    /// file twice: it is reported once. The same folder reached by two roads (a firmlink) is one place; two
    /// names for one file in one folder (hard links) are two files.
    private struct ReportedKeys {
        private var reported = Set<String>()
        private var parents: [String: FileIdentity?] = [:]

        /// Whether `item` is reported for the first time; it counts as reported from now on.
        mutating func insert(_ item: FileItem) -> Bool {
            reported.insert(key(of: item)).inserted
        }

        private mutating func key(of item: FileItem) -> String {
            guard item.url.isFileURL else {
                return FileSearch.locationKey(of: item.url)
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
    }

    /// File names that may be archives; only these are offered to the file systems.
    internal static let archiveExtensions: Set<String> = [
        "zip", "jar", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "7z", "rar", "cab", "lzh", "arj"
    ]

    /// The listed but not yet reported entries that hold back the listing of further folders.
    internal static let candidateBudget = 200_000
    /// The files a duplicate search collects before it stops and says so.
    internal static let duplicateCandidateLimit = 3_000_000

    /// The threads of a search: all cores, and at least four for a slow disk or server.
    internal static let threadCount = max(4, ProcessInfo.processInfo.activeProcessorCount)

    /// From this many entries seen in one folder on, what has passed the quick checks is
    /// reported in parts while the listing goes on (each part in name order).
    internal static let defaultPartialListingAfter = 100_000

    /// What the search was asked to find.
    public let query: SearchQuery
    /// Set by `cancel()`; the walk, the tests and the readers watch it.
    public let cancellation = CancellationFlag()
    /// Why the search cannot run as asked (a text that is no hex string, a broken regular
    /// expression); `run` then finds nothing.
    ///
    /// Whoever starts a search shows it first.
    public let problem: any Error?
    /// The budget this search works to; tests make it small.
    internal let budget: Int
    /// See `Tuning`.
    internal let threads: Int
    /// See `Tuning`.
    internal let folderIdentity: @Sendable (URL) -> FileIdentity?
    /// Tests make it small.
    internal let partialListingAfter: Int
    /// The file systems the search lists and reads through.
    internal let fileSystems: FileSystemRegistry
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

    /// Whether the files are searched for a text; then only files can match.
    internal var testsText: Bool { pattern != nil }

    /// A search for `query` through `fileSystems`; `columns` adds the columns of the plugins to the fields the
    /// rules of the Plugins tab can name, and "not older than" is measured from `now`.
    public convenience init(
        _ query: SearchQuery,
        fileSystems: FileSystemRegistry,
        columns: ColumnRegistry? = nil,
        now: Date = Date()
    ) {
        self.init(query, fileSystems: fileSystems, columns: columns, now: now, tuning: Tuning())
    }

    /// A search for `query` that works to `tuning`, without the columns of the plugins, measured from now.
    internal convenience init(_ query: SearchQuery, fileSystems: FileSystemRegistry, tuning: Tuning) {
        self.init(query, fileSystems: fileSystems, columns: nil, now: Date(), tuning: tuning)
    }

    /// A search for `query` that works to `tuning`.
    internal init(
        _ query: SearchQuery,
        fileSystems: FileSystemRegistry,
        columns: ColumnRegistry?,
        now: Date,
        tuning: Tuning
    ) {
        (budget, partialListingAfter) = (tuning.budget, tuning.partialListingAfter)
        (threads, folderIdentity) = (tuning.threads, tuning.identity)
        self.query = query
        self.fileSystems = fileSystems
        self.now = now
        mask = SearchMask(query.names, regex: query.namesAreRegex)
        criteria = query.criteria.prepared(now: now)
        let allFields = SearchField.all(fileSystems: fileSystems, columns: columns).map { ($0.id, $0) }
        fields = Dictionary(allFields) { first, _ in first }
        fieldRules = query.fieldRules.prepared(trip: fieldTrip)
        var found: (any Error)? = mask.isValid ? nil : TextPattern.Problem.badRegex(query.names)
        if found == nil, let rule = query.fieldRules.unusableRule {
            found = TextPattern.Problem.badRegex(rule.value)
        }
        var textPattern: TextPattern?
        if !query.text.isEmpty {
            do {
                textPattern = try TextPattern(
                    query.text,
                    caseSensitive: query.caseSensitive,
                    options: query.textOptions
                )
            } catch {
                found = found ?? error
            }
        }
        (pattern, problem) = (textPattern, found)
    }

    /// A place by its location, with the host in lower case and no trailing slash: two ways of
    /// writing the same remote place (`sftp://HOST/a`, `sftp://host/a/`) are one key.
    internal static func locationKey(of url: URL) -> String {
        var key = url.locationKey
        if let host = url.host, !host.isEmpty, let range = key.range(of: "://" + host) {
            key.replaceSubrange(range, with: "://" + host.lowercased())
        }
        return key
    }

    /// Cancels the run, from any thread: it ends soon and reports nothing more.
    public func cancel() {
        cancellation.cancel()
    }

    /// Walks the trees; the hits come in path order: the matching entries of a folder by name,
    /// then its subfolders one after the other.
    ///
    /// `onDirectory` reports the folder being searched, `onMatch` each hit. With a text to find,
    /// only files can match.
    public func run(
        onDirectory: (URL) -> Void = { _ in
            // Most callers only want the hits.
        },
        onMatch: (FileItem) -> Void
    ) {
        runWalk(limit: query.resultLimit, onDirectory: onDirectory, onMatch: onMatch)
    }

    /// Runs the search and returns the files that are duplicates of each other, in groups
    /// (spec 09 › Duplicate finder); empty when the search was cancelled.
    ///
    /// The files are all held while they are compared, so a search stops at
    /// `duplicateCandidateLimit` of them and says so (`reachedResultLimit`).
    @preconcurrency
    public func runForDuplicates(
        onDirectory: (URL) -> Void = { _ in
            // Most callers only want the groups.
        },
        onHashing: (@Sendable (Int, Int) -> Void)? = nil
    ) -> [[FileItem]] {
        var files: [FileItem] = []
        runWalk(
            limit: min(query.resultLimit ?? Int.max, Self.duplicateCandidateLimit),
            onDirectory: onDirectory
        ) { item in
            if !item.isDirectory {
                files.append(item)
            }
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
    internal func passesQuickChecks(_ item: FileItem) -> Bool {
        mask.matches(item.name) { self.cancellation.isCancelled } && (criteria?.matches(item) ?? true)
    }

    /// Field rules and text: both may read the file, so they run on all cores.
    internal func passesSlowChecks(_ item: FileItem) -> Bool {
        passesSlowChecks(item, checkingText: true)
    }

    /// Where the contents of an archive file are listed: the location another file system
    /// reads out of the file's own, if any does.
    ///
    /// Works on the text alone.
    internal func archiveRoot(of file: FileItem, in provider: any FileSystemProvider) -> URL? {
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

    private func runWalk(limit: Int?, onDirectory: (URL) -> Void, onMatch: (FileItem) -> Void) {
        guard problem == nil else {
            return
        }
        let walk = SearchWalk(self)
        var roots: [SearchNode] = []
        // The tree is let go of on another thread: a cancelled search may hold a million entries.
        defer {
            // This thread lets go of them here: nothing else holds them any more.
            let dropped = Handover((walk.close(), roots))
            DispatchQueue.global(qos: .utility)
                .async {
                    withExtendedLifetime(dropped) {
                        // The tree goes here, on this thread.
                    }
                }
        }
        switch query.scope {
        case .only(let items):
            roots = chosenRoots(for: items, in: walk)
            guard !cancellation.isCancelled else {
                return
            }

        case .startDirectories:
            roots = query.directories.map { walk.makeNode(directory: $0, depth: 0) }
        }
        walk.start(roots)
        var reported = ReportedKeys()
        let overlapping = query.scope != .startDirectories || roots.count > 1
        var count = 0
        for root in roots {
            walk.deliver(root, onDirectory: onDirectory) { item in
                if overlapping, !reported.insert(item) {
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
            if walk.isStopped {
                break
            }
        }
    }

    private func passesSlowChecks(_ item: FileItem, checkingText: Bool) -> Bool {
        guard !cancellation.isCancelled,
            fieldRules.matches(item, fields: fields, cancelled: { self.cancellation.isCancelled })
        else {
            return false
        }
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
        defer {
            withExtendedLifetime(token) {
                // The token interrupts the reader until here.
            }
        }
        return autoreleasepool { pattern.accepts(reader, cancellation: cancellation) }
    }

    deinit {
        // Nothing to release.
    }
}
