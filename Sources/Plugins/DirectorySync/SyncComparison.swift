public import AFMKernel
public import Foundation

/// The comparison of two directory trees (spec 09 › Comparison algorithm).
///
/// It knows nothing of windows: it reads through the file-system providers, so the two sides can be
/// on any file systems, and returns rows.
///
/// **Threading.** `run` blocks and is meant for a background thread. The two sides of every
/// folder are listed at the same time, the subfolders of a folder are walked on all cores at
/// once, and with "by content" the file pairs are read and compared on all cores, each pair
/// with its own two readers. The counters shared by those threads are behind a lock.
/// `progress` is called from whichever thread has news, one call at a time. An instance runs
/// once; `cancellation` may be set from any thread.
///
/// `counters`, `errors`, `topEntries` and `report` are guarded by `lock`; everything else is
/// fixed in `init`. The options the pairs are classified with are handed down the walk.
public final class SyncComparison: @unchecked Sendable {
    // MARK: Walking the trees

    /// A folder on one side: where it is, and whether it is there at all.
    private struct Side {
        /// Where the folder is, or would be.
        let url: URL
        /// Whether the folder is there.
        let exists: Bool
    }

    /// A folder of the walk on both sides, and where it is relative to the start directories.
    private struct Level {
        /// The folder on the left.
        let left: Side
        /// The folder on the right.
        let right: Side
        /// The folder's path relative to the start directories, with a trailing slash; empty at the top.
        let relative: String

        /// The subfolder `name` of a pair, on both sides.
        func below(_ pair: Pair, named name: String) -> Self {
            Self(
                left: Side(url: pair.left?.url ?? left.url.appending(name: name), exists: pair.left != nil),
                right: Side(url: pair.right?.url ?? right.url.appending(name: name), exists: pair.right != nil),
                relative: relative + name + "/"
            )
        }

        /// The row of a pair of this folder.
        func row(_ pair: Pair, _ state: SyncState, isDirectory: Bool, asymmetric: Bool) -> SyncRow {
            SyncRow(
                directory: relative,
                isDirectory: isDirectory,
                left: pair.left,
                right: pair.right,
                leftDirectory: left.url,
                rightDirectory: right.url,
                state: state,
                asymmetric: asymmetric
            )
        }
    }

    /// What the pairs of one folder make.
    private struct Found {
        /// The rows of files, and of pairs that are never synchronized.
        var rows: [SyncRow] = []
        /// The rows of folders on one side only (with "Empty directories").
        var folderRows: [SyncRow] = []
        /// The subfolders to walk into.
        var folders: [Level] = []
    }

    /// The entries of the same name in two folders; either side may be missing.
    internal struct Pair {
        /// The name the pair is sorted by: the left one's, else the right one's.
        internal var name: String
        /// The entry on the left.
        internal var left: FileItem?
        /// The entry on the right.
        internal var right: FileItem?
        /// False when the two names differ in case.
        internal var isExactMatch = true
        /// A name alone on its side whose lower-case form belongs to a name that has a partner: its twin in
        /// the other folder is already paired with another name.
        internal var collides = false
    }

    /// The size of the blocks files are compared in.
    internal static let blockSize = 256 * 1_024

    /// What is compared and how.
    public let options: SyncOptions
    /// Set from any thread to stop the comparison; what it found until then is returned.
    public let cancellation: CancellationFlag
    /// The file systems both sides are read through.
    internal let fileSystems: FileSystemRegistry
    /// The masks of `options`.
    private let mask: SyncMask
    /// The names asked for (`SyncOptions.onlyNames`) as exact bytes; empty for every name.
    private let onlyNames: Set<[UInt8]>
    /// The names asked for as Strings, which compare equal to the other spelling of a name.
    private let onlyAlike: Set<String>

    /// Guards `counters`, `errors`, `report` and `topEntries`.
    private let lock = NSLock()
    /// How far the comparison is (under `lock`).
    private var counters = SyncProgress()
    /// What could not be read or compared (under `lock`).
    private var errors: [String] = []
    /// Told every change of `counters` (under `lock`); let go when the run ends.
    private var report: (@Sendable (SyncProgress) -> Void)?
    /// The unfiltered sizes of the two start directories' listings (under `lock`).
    private var topEntries: [Int?] = [nil, nil]

    /// A comparison by `options` through `fileSystems`, stopped by `cancellation`.
    public init(
        options: SyncOptions,
        fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag = CancellationFlag()
    ) {
        self.options = options
        self.fileSystems = fileSystems
        self.cancellation = cancellation
        mask = SyncMask(options.mask)
        onlyNames = Set(options.onlyNames.map { name in Array(name.utf8) })
        onlyAlike = Set(options.onlyNames)
    }

    /// Compares the trees below `left` and `right`; blocks until done or cancelled.
    ///
    /// `progress` is told how far it is, from whichever thread has news, one call at a time.
    @preconcurrency
    public func run(left: URL, right: URL, progress: (@Sendable (SyncProgress) -> Void)? = nil) -> SyncResult {
        lock.lock()
        report = progress
        lock.unlock()
        // The options the pairs are classified with. The dates of two file systems that keep them
        // exactly are compared exactly; the tolerance is for the ones that round (see
        // `toleranceSeconds`). Otherwise a file changed two seconds after its copy would count as unchanged.
        var classifying = options
        classifying.toleranceSeconds =
            Self.needsTolerance(left, right, fileSystems: fileSystems) ? options.toleranceSeconds : 0
        var rows = walk(
            Level(left: Side(url: left, exists: true), right: Side(url: right, exists: true), relative: ""),
            classifying: classifying,
            isTop: true
        )
        compareContents(of: &rows)
        lock.lock()
        defer { lock.unlock() }
        // The comparison runs once: whatever the caller's closure holds is let go.
        report = nil
        var result = SyncResult(
            rows: rows,
            leftDirectories: counters.leftDirectories,
            rightDirectories: counters.rightDirectories,
            errors: errors,
            wasCancelled: cancellation.isCancelled
        )
        result.topEntries = (topEntries[0], topEntries[1])
        result.toleranceSeconds = classifying.toleranceSeconds
        return result
    }

    /// Changes the counters and reports them.
    internal func update(_ change: (inout SyncProgress) -> Void) {
        lock.lock()
        change(&counters)
        let snapshot = counters
        // Reported under the lock, so the calls arrive one at a time and in order.
        report?(snapshot)
        lock.unlock()
    }

    /// Adds a folder that could not be read or a file that could not be compared to the errors.
    internal func note(_ error: String) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }

    /// The entries of one side that take part; throws when the folder cannot be read (noted as an error unless
    /// the comparison was cancelled).
    private func list(_ side: Side, isTop: Bool, index: Int) throws -> [FileItem] {
        guard side.exists else {
            return []
        }
        do {
            let items = try fileSystems.provider(for: side.url)
                .list(
                    side.url,
                    showHidden: options.includeHidden,
                    cancellation: cancellation
                )
            // A listing that was ended by the cancel is not an error of the folder.
            if cancellation.isCancelled {
                throw CancellationError()
            }
            if isTop {
                lock.lock()
                topEntries[index] = items.count
                lock.unlock()
            }
            return (isTop ? asked(among: items) : items)
                .filter { item in
                    // Links are never followed or copied, so the walk cannot run in circles; they
                    // are listed so that a name that is a link on one side can be kept out of the pairs.
                    item.isDirectory ? !mask.excludesFolder(item.name) : mask.matchesFile(item.name)
                }
        } catch {
            if !cancellation.isCancelled {
                note("\(fileSystems.displayPath(side.url)): \(error.localizedDescription)")
            }
            throw error
        }
    }

    /// The entries that were asked for.
    ///
    /// A name asked for in one spelling also stands for the other spelling of it (NFC, NFD) when
    /// the folder holds only that one.
    private func asked(among items: [FileItem]) -> [FileItem] {
        guard !onlyNames.isEmpty else {
            return items
        }
        let exact = Set(items.filter { item in onlyNames.contains(Array(item.name.utf8)) }.map(\.name))
        return items.filter { item in
            onlyNames.contains(Array(item.name.utf8)) || (onlyAlike.contains(item.name) && !exact.contains(item.name))
        }
    }

    /// The rows of a folder and of everything below it; the subfolders are walked on all cores.
    private func walk(_ level: Level, classifying: SyncOptions, isTop: Bool) -> [SyncRow] {
        guard !cancellation.isCancelled else {
            return []
        }
        let listings = Parallel.map([(level.left, 0), (level.right, 1)]) { side, index in
            Result { try self.list(side, isTop: isTop, index: index) }
        }
        guard let leftItems = try? listings[0].get(), let rightItems = try? listings[1].get() else {
            return []
        }
        update { counts in
            counts.leftDirectories += level.left.exists ? 1 : 0
            counts.rightDirectories += level.right.exists ? 1 : 0
        }
        var found = Found()
        for pair in Self.sorted(Self.pair(leftItems, rightItems)) {
            take(pair, at: level, classifying: classifying, into: &found)
        }
        let below = Parallel.map(found.folders) { folder in
            self.walk(folder, classifying: classifying, isTop: false)
        }
        return found.rows + found.folderRows + below.flatMap(\.self)
    }

    /// What one pair of a folder makes: a row, a folder to walk into (and its row with "Empty directories"), or
    /// nothing.
    private func take(_ pair: Pair, at level: Level, classifying: SyncOptions, into found: inout Found) {
        func row(_ state: SyncState, isDirectory: Bool) -> SyncRow {
            level.row(pair, state, isDirectory: isDirectory, asymmetric: options.asymmetric)
        }
        if pair.left?.isSymlink == true || pair.right?.isSymlink == true {
            // A link is neither followed nor replaced: facing another entry it is shown, but nothing is done
            // with it.
            if pair.left != nil, pair.right != nil {
                found.rows.append(row(.excluded, isDirectory: false))
            }
            return
        }
        let (leftIsFolder, rightIsFolder) = (pair.left?.isDirectory, pair.right?.isDirectory)
        if let leftIsFolder, let rightIsFolder, leftIsFolder != rightIsFolder {
            found.rows.append(row(.excluded, isDirectory: false))
        } else if let item = pair.left ?? pair.right, item.isDirectory {
            guard options.subdirectories else {
                return
            }
            found.folders.append(level.below(pair, named: item.name))
            if options.emptyDirectories, pair.left == nil || pair.right == nil {
                found.folderRows.append(row(pair.left == nil ? .rightOnly : .leftOnly, isDirectory: true))
            }
        } else if let leftFile = pair.left, let rightFile = pair.right {
            let state =
                pair.isExactMatch
                ? Self.classify(left: leftFile, right: rightFile, options: classifying).state : .excluded
            found.rows.append(row(state, isDirectory: false))
        } else {
            // A name that differs only in case from one that is paired elsewhere is not "only here": on a
            // file system that ignores case, copying it would replace the other.
            found.rows.append(
                row(pair.collides ? .excluded : pair.left == nil ? .rightOnly : .leftOnly, isDirectory: false)
            )
        }
    }
}
