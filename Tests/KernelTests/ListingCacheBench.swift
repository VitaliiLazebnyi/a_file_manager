import AFMKernel
import Foundation

/// What the tests of the listing cache share: a clock moved by hand, a share and a local disk,
/// listings of `mem:` folders, and storing a listing the way a panel does after reading it.
internal struct ListingCacheBench {
    /// The cache's clock, moved by the test.
    ///
    /// Unchecked: the time is guarded by `lock`.
    internal final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = Date(timeIntervalSince1970: 1_000_000)

        /// The time the cache sees now; the test moves it on (or back) by setting it.
        internal var time: Date {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The clock of every cache made here.
    internal let clock = Clock()
    /// A network share: every folder read there is kept.
    internal let share = VolumeInfo(name: "Share", isLocal: false)
    /// A local disk: only folders that were slow to read are kept.
    internal let disk = VolumeInfo(name: "Disk", isLocal: true)
    /// The order every listing made here is sorted in.
    internal let name = ListOrder(key: .name)

    /// A cache of at most 20 folders and 300,000 entries on `clock`.
    internal func cache() -> ListingCache {
        cache(folders: 20, entries: 300_000)
    }

    /// A cache of at most `folders` folders and `entries` entries on `clock`.
    internal func cache(folders: Int, entries: Int) -> ListingCache {
        var limits = ListingCache.Limits()
        limits.maxFolders = folders
        limits.maxEntries = entries
        return ListingCache(limits: limits) { [clock] in clock.time }
    }

    /// The `mem:` location of `path`.
    internal func url(_ path: String) -> URL {
        guard let url = URL(string: "mem://" + path) else {
            preconditionFailure("\(path) is not a path")
        }
        return url
    }

    /// The listing of `path` on the share with files called `names`, sized by their position.
    internal func listing(_ path: String, _ names: [String]) -> Listing {
        listing(path, names, volume: share)
    }

    /// The listing of `path` on `volume` with files called `names`, sized by their position.
    internal func listing(_ path: String, _ names: [String], volume: VolumeInfo) -> Listing {
        let directory = url(path)
        let items = names.enumerated()
            .map { index, name in
                FileItem(url: directory.appending(name: name), name: name, stat: .init(size: Int64(index)))
            }
        return Listing(
            directory: directory,
            items: Sorter.sort(items, by: name),
            parent: nil,
            root: url("/"),
            volume: volume
        )
    }

    /// The names `f0.txt` … of `count` files.
    internal func files(_ count: Int) -> [String] { (0..<count).map { "f\($0).txt" } }

    /// Stores `listing` without hidden files, read in no time, as a panel does after reading it.
    ///
    /// Returns whether the cache kept it.
    @discardableResult
    internal func remember(_ listing: Listing, in cache: ListingCache) -> Bool {
        remember(listing, in: cache, showHidden: false, readTime: 0)
    }

    /// Stores `listing`, read just now in `readTime` seconds, as a panel does after reading it.
    ///
    /// Returns whether the cache kept it.
    @discardableResult
    internal func remember(_ listing: Listing, in cache: ListingCache, showHidden: Bool, readTime: TimeInterval)
        -> Bool
    {
        cache.store(listing, sortedBy: name, showHidden: showHidden, readTime: readTime, since: cache.startReading())
    }
}
