import AFMKernel
import Foundation
import Testing

/// The memory of slow folders: what it keeps, and what it lets go of to stay within its limits.
@Suite
internal struct RememberedListingStoreTests {
    private let bench = ListingCacheBench()

    /// A stored folder is found again, also written with a trailing slash; another one is not.
    @Test
    internal func hitAndMiss() {
        let cache = bench.cache()
        #expect(cache.entry(for: bench.url("/a"), showHidden: false) == nil)
        #expect(bench.remember(bench.listing("/a", ["x.txt", "y.txt"]), in: cache))
        let entry = cache.entry(for: bench.url("/a"), showHidden: false)
        #expect(entry?.listing.items.map(\.name) == ["x.txt", "y.txt"])
        #expect(entry?.order == bench.name)
        #expect(entry?.readAt == bench.clock.time)
        // The same place written with a trailing slash; another place.
        #expect(cache.entry(for: bench.url("/a/"), showHidden: false) != nil)
        #expect(cache.entry(for: bench.url("/b"), showHidden: false) == nil)
        #expect(cache.folderCount == 1)
        #expect(cache.entryCount == 2)
    }

    /// A local folder is kept only when it took long to read; on a share every folder is kept,
    /// and a kept folder is brought up to date by every later reading.
    @Test
    internal func localFoldersAreKeptOnlyWhenTheyWereSlowToRead() {
        let cache = bench.cache()
        let (disk, share) = (bench.disk, bench.share)
        #expect(
            !bench.remember(bench.listing("/quick", ["x"], volume: disk), in: cache, showHidden: false, readTime: 0.02)
        )
        #expect(
            bench.remember(bench.listing("/slow", ["x"], volume: disk), in: cache, showHidden: false, readTime: 0.2)
        )
        // On a share every folder is kept, however quickly it came.
        #expect(
            bench.remember(bench.listing("/share", ["x"], volume: share), in: cache, showHidden: false, readTime: 0.001)
        )
        #expect(cache.folderCount == 2)
        // A folder that is remembered is brought up to date by every later reading, also a quick one.
        bench.clock.time += 5
        #expect(
            bench.remember(
                bench.listing("/slow", ["x", "y"], volume: disk),
                in: cache,
                showHidden: false,
                readTime: 0.01
            )
        )
        #expect(cache.entry(for: bench.url("/slow"), showHidden: false)?.listing.items.count == 2)
        #expect(cache.age(of: bench.url("/slow"), showHidden: false) == 0)
    }

    /// When the folders are too many, the one used longest ago makes room.
    @Test
    internal func theLeastRecentlyUsedFolderGoesFirst() {
        let cache = bench.cache(folders: 3, entries: 300_000)
        for path in ["/1", "/2", "/3"] {
            bench.remember(bench.listing(path, ["x"]), in: cache)
        }
        // /1 is used again, so /2 is the one that makes room.
        #expect(cache.entry(for: bench.url("/1"), showHidden: false) != nil)
        bench.remember(bench.listing("/4", ["x"]), in: cache)
        #expect(cache.folderCount == 3)
        #expect(cache.age(of: bench.url("/2"), showHidden: false) == nil)
        #expect(["/1", "/3", "/4"].allSatisfy { cache.age(of: bench.url($0), showHidden: false) != nil })
    }

    /// The entries of all folders together stay within the limit; a folder larger than the
    /// limit is not kept, and what was kept of it is dropped.
    @Test
    internal func theTotalNumberOfEntriesIsLimited() {
        let cache = bench.cache(folders: 20, entries: 100)
        bench.remember(bench.listing("/1", bench.files(40)), in: cache)
        bench.remember(bench.listing("/2", bench.files(40)), in: cache)
        #expect(cache.entryCount == 80)
        // 40 more do not fit: the oldest folder goes.
        bench.remember(bench.listing("/3", bench.files(40)), in: cache)
        #expect(cache.entryCount == 80)
        #expect(cache.age(of: bench.url("/1"), showHidden: false) == nil)
        // A folder that is larger than the whole limit is not remembered, and what was
        // remembered of it before is dropped rather than left out of date.
        #expect(!bench.remember(bench.listing("/huge", bench.files(101)), in: cache))
        #expect(cache.folderCount == 2)
        #expect(!bench.remember(bench.listing("/2", bench.files(101)), in: cache))
        #expect(cache.age(of: bench.url("/2"), showHidden: false) == nil)
        #expect(cache.entryCount == 40)
        // Exactly the limit fits, alone.
        #expect(bench.remember(bench.listing("/full", bench.files(100)), in: cache))
        #expect(cache.folderCount == 1)
        #expect(cache.entryCount == 100)
    }

    /// A folder read with hidden files and the same folder read without them are kept apart.
    @Test
    internal func withAndWithoutHiddenFilesAreTwoListings() {
        let cache = bench.cache()
        bench.remember(bench.listing("/a", ["x.txt"]), in: cache)
        #expect(cache.entry(for: bench.url("/a"), showHidden: true) == nil)
        bench.remember(bench.listing("/a", [".secret", "x.txt"]), in: cache, showHidden: true, readTime: 0)
        #expect(cache.entry(for: bench.url("/a"), showHidden: false)?.listing.items.count == 1)
        #expect(cache.entry(for: bench.url("/a"), showHidden: true)?.listing.items.count == 2)
        #expect(cache.entry(for: bench.url("/a"), showHidden: true)?.showHidden == true)
        #expect(cache.folderCount == 2)
    }

    /// A listing older than ten minutes is dropped for good, even if the clock goes back.
    @Test
    internal func anOldListingIsNotHandedOut() {
        let cache = bench.cache()
        bench.remember(bench.listing("/a", ["x.txt"]), in: cache)
        bench.clock.time += 10 * 60
        #expect(cache.entry(for: bench.url("/a"), showHidden: false) != nil)
        bench.clock.time += 1
        #expect(cache.entry(for: bench.url("/a"), showHidden: false) == nil)
        // It is gone for good, not only hidden.
        #expect(cache.folderCount == 0)
        bench.clock.time -= 60
        #expect(cache.entry(for: bench.url("/a"), showHidden: false) == nil)
    }
}
