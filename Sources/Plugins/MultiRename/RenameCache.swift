import AFMKernel
import Foundation

/// What a session works out once for its list and reuses for every preview: the subjects the
/// masks look at, the folders the items are in, which folders tell letter case apart, what
/// the folders hold and the dates inside pictures.
///
/// A session replaces its cache whenever the list changes and after a run, so nothing in it
/// outlives the list it was made for. Folder contents are as they were when first looked at; a run
/// lists them afresh. Safe to use from several threads.
///
/// Unchecked `Sendable`: all mutable state is guarded by `lock`; `dates` does not change.
internal final class RenameCache: @unchecked Sendable {
    /// What the rows of the list are, worked out once per list.
    internal struct Rows {
        /// What the masks look at, per row.
        internal var subjects: [RenameSubject]
        /// The folder of each row.
        internal var folders: [URL]
        /// The `locationKey` of each row's folder.
        internal var folderKeys: [String]
    }

    /// What a folder held when it was listed.
    internal struct FolderContents {
        /// The keys of its entries, as the planner makes them.
        internal var keys: Set<String>
    }

    /// One row as it is worked out on the cores.
    private struct Row {
        var subject: RenameSubject
        var folder: URL
        var folderKey: String
    }

    private let lock = NSLock()
    private var rows: Rows?
    private var foldings: [String: CaseFolding]
    private var keys: [String: Set<String>]
    private let dates: ContentDateStore

    /// An empty cache.
    internal convenience init() {
        self.init(dates: ContentDateStore(), foldings: [:], keys: [:])
    }

    private init(dates: ContentDateStore, foldings: [String: CaseFolding], keys: [String: Set<String>]) {
        self.dates = dates
        self.foldings = foldings
        self.keys = keys
    }

    /// A cache for the same items in another order, or with some of them taken out: what the
    /// folders hold, which of them tell letter case apart and the dates in pictures stay; the
    /// rows are made again.
    ///
    /// Previews under way keep the cache they have.
    internal func forChangedOrder() -> RenameCache {
        lock.lock()
        defer { lock.unlock() }
        return RenameCache(dates: dates, foldings: foldings, keys: keys)
    }

    /// The rows of `entries`, made on all cores the first time they are asked for.
    internal func rows(for entries: [RenameEntry], fileSystems: FileSystemRegistry) -> Rows {
        lock.lock()
        let known = rows
        lock.unlock()
        if let known, known.subjects.count == entries.count {
            return known
        }
        let built = Parallel.map(entries, serialBelow: RenameComputation.parallelThreshold) { entry -> Row in
            let directory = entry.directory
            return Row(
                subject: RenameComputation.subject(for: entry, directory: directory, fileSystems: fileSystems),
                folder: directory,
                folderKey: directory.locationKey
            )
        }
        let result = Rows(
            subjects: built.map(\.subject),
            folders: built.map(\.folder),
            folderKeys: built.map(\.folderKey)
        )
        lock.lock()
        rows = result
        lock.unlock()
        return result
    }

    /// How the folder of `folderKey` treats letter case, when that was found out.
    internal func folding(folderKey: String) -> CaseFolding? {
        lock.lock()
        defer { lock.unlock() }
        return foldings[folderKey]
    }

    /// Notes how the folder of `folderKey` treats letter case.
    internal func setFolding(_ folding: CaseFolding, folderKey: String) {
        lock.lock()
        defer { lock.unlock() }
        foldings[folderKey] = folding
    }

    /// What the folder of `folderKey` held when it was listed; nil when it was not.
    internal func contents(folderKey: String) -> FolderContents? {
        lock.lock()
        defer { lock.unlock() }
        return keys[folderKey].map(FolderContents.init)
    }

    /// Notes the keys of what the folder of `folderKey` holds.
    internal func setExistingKeys(_ found: Set<String>, folderKey: String) {
        lock.lock()
        defer { lock.unlock() }
        keys[folderKey] = found
    }

    /// `[T4]` for a file: read once, however often the preview is computed.
    internal func contentDate(of url: URL) -> Date? {
        dates.date(of: url)
    }

    deinit {
        // Nothing to release.
    }
}
