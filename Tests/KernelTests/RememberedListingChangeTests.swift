import AFMKernel
import Foundation
import TestSupport
import Testing

/// The memory of slow folders: other orders, changes to folders, readings that overlap,
/// switching it off, and many threads at once.
@Suite
internal struct RememberedListingChangeTests {
    private let bench = ListingCacheBench()

    /// Does one of the things a panel does with the cache, chosen by `step`, and tells whether what came back was
    /// right: a whole listing in `order`, and the cache within its limits of 8 folders and 2,000 entries.
    ///
    /// Safe from any thread.
    private static func exercise(
        _ cache: ListingCache,
        of bench: ListingCacheBench,
        with listing: Listing,
        in order: ListOrder,
        step: Int
    ) -> Bool {
        let showHidden = step.isMultiple(of: 2)
        var isRight = true
        switch step % 7 {
        case 0, 1:
            bench.remember(listing, in: cache, showHidden: showHidden, readTime: 0)

        case 2:
            _ = cache.entry(for: listing.directory, showHidden: showHidden)

        case 3, 4:
            // Whatever is handed out is one whole listing in the order that was asked for.
            if let entry = cache.entry(for: listing.directory, showHidden: showHidden, sortedBy: order) {
                isRight = isWhole(entry, of: listing, in: order)
            }

        case 5:
            cache.invalidate([listing.directory])

        default:
            _ = cache.age(of: listing.directory, showHidden: false)
        }
        return isRight
    }

    /// Whether `entry` holds every item of `listing`, sorted by `order`.
    private static func isWhole(_ entry: ListingCache.Entry, of listing: Listing, in order: ListOrder) -> Bool {
        let items = entry.listing.items
        guard entry.order == order, items.count == listing.items.count else {
            return false
        }
        return zip(items, items.dropFirst())
            .allSatisfy { earlier, later in !panelsInOrder(later, earlier, by: order) }
    }

    /// The cheap lookup hands out the order that is kept; asking for another sorts once and
    /// keeps that order, without changing when the folder was read.
    @Test
    internal func anotherOrderIsSortedOnRequestAndKept() {
        let cache = bench.cache()
        bench.remember(bench.listing("/a", ["b.txt", "a.txt", "c.txt"]), in: cache)
        let reversed = ListOrder(key: .name, descending: true)
        // The cheap lookup hands out what is there, in the order it is in.
        #expect(cache.entry(for: bench.url("/a"), showHidden: false)?.order == bench.name)
        let sorted = cache.entry(for: bench.url("/a"), showHidden: false, sortedBy: reversed)
        #expect(sorted?.order == reversed)
        #expect(sorted?.listing.items.map(\.name) == ["c.txt", "b.txt", "a.txt"])
        // From then on it is kept that way; when it was read stays what it was.
        bench.clock.time += 30
        let kept = cache.entry(for: bench.url("/a"), showHidden: false)
        #expect(kept?.order == reversed)
        #expect(kept?.listing.items.map(\.name) == ["c.txt", "b.txt", "a.txt"])
        #expect(cache.age(of: bench.url("/a"), showHidden: false) == 30)
        let bySize = cache.entry(
            for: bench.url("/a"),
            showHidden: false,
            sortedBy: ListOrder(key: .size, descending: true)
        )
        // Sizes follow the order the names were given in: b 0, a 1, c 2.
        #expect(bySize?.listing.items.map(\.name) == ["c.txt", "a.txt", "b.txt"])
        #expect(cache.entry(for: bench.url("/missing"), showHidden: false, sortedBy: reversed) == nil)
    }

    /// A changed folder is forgotten in both variants, with what lies below it and the folder
    /// that lists it; neighbours stay, and forgetting one folder leaves the one above alone.
    @Test
    internal func changedFoldersAreForgottenWithWhatLiesBelowAndTheFolderAbove() {
        let cache = bench.cache()
        for path in ["/", "/work", "/work/in", "/work/in/deep", "/work/inside", "/other"] {
            bench.remember(bench.listing(path, ["x"]), in: cache)
        }
        bench.remember(bench.listing("/work/in", ["x"]), in: cache, showHidden: true, readTime: 0)
        cache.invalidate([bench.url("/work/in")])
        func isKept(_ path: String) -> Bool { cache.age(of: bench.url(path), showHidden: false) != nil }
        // The folder (in both variants), what is below it, and the folder that lists it.
        #expect(!isKept("/work/in"))
        #expect(cache.age(of: bench.url("/work/in"), showHidden: true) == nil)
        #expect(!isKept("/work/in/deep"))
        #expect(!isKept("/work"))
        // A neighbour whose name merely starts the same, and everything else, stays.
        #expect(isKept("/work/inside"))
        #expect(isKept("/other"))
        #expect(isKept("/"))
        // Forgetting one folder leaves the one above alone.
        cache.forget(bench.url("/work/inside"))
        #expect(!isKept("/work/inside"))
        #expect(isKept("/"))
        cache.invalidate([bench.url("/")])
        #expect(!isKept("/") && !isKept("/other"))
    }

    /// Of two overlapping readings the later one wins, and a reading during which the folder
    /// was reported changed is not kept.
    @Test
    internal func aReadingThatWasOvertakenIsNotKept() {
        let cache = bench.cache()
        let name = bench.name
        // Two readings of the same folder overlap; the one that started later ends first.
        let (early, late) = (cache.startReading(), cache.startReading())
        #expect(cache.store(bench.listing("/a", ["new"]), sortedBy: name, showHidden: false, readTime: 0, since: late))
        #expect(
            !cache.store(bench.listing("/a", ["old"]), sortedBy: name, showHidden: false, readTime: 0, since: early)
        )
        #expect(cache.entry(for: bench.url("/a"), showHidden: false)?.listing.items.map(\.name) == ["new"])
        // A folder is reported changed while it is being read: what that reading brings may
        // be from before the change.
        let before = cache.startReading()
        cache.invalidate([bench.url("/a")])
        #expect(
            !cache.store(bench.listing("/a", ["stale"]), sortedBy: name, showHidden: false, readTime: 0, since: before)
        )
        #expect(cache.forgets(bench.url("/a")))
        #expect(bench.remember(bench.listing("/a", ["fresh"]), in: cache))
    }

    /// Switched off, the cache drops what it had and keeps nothing until it is switched on again.
    @Test
    internal func switchedOffItKeepsNothing() {
        let cache = bench.cache()
        bench.remember(bench.listing("/a", ["x"]), in: cache)
        cache.isEnabled = false
        #expect(cache.forgets(bench.url("/a")))
        #expect(!bench.remember(bench.listing("/a", ["x"]), in: cache))
        cache.isEnabled = true
        #expect(bench.remember(bench.listing("/a", ["x"]), in: cache))
    }

    /// The kernel's cache is on unless the settings say otherwise.
    @Test
    @MainActor
    internal func theKernelSwitchesItFromTheSettings() {
        let settings = MemorySettings()
        #expect(Kernel(productName: "Test", settings: settings, ui: ScriptedInteraction()).listingCache.isEnabled)
        settings.set(false, forKey: ListingCache.settingsKey)
        #expect(!Kernel(productName: "Test", settings: settings, ui: ScriptedInteraction()).listingCache.isEnabled)
    }

    /// Storing, looking up, sorting, forgetting and asking ages from many threads at once
    /// always hands out whole listings in the order asked for, within the limits.
    @Test
    internal func manyThreadsAtOnce() {
        let cache = bench.cache(folders: 8, entries: 2_000)
        let orders = [
            ListOrder(key: .name), ListOrder(key: .name, descending: true), ListOrder(key: .size), ListOrder(key: .ext)
        ]
        let listings = (0..<16).map { bench.listing("/dir\($0)", bench.files(50 + $0 * 20)) }
        // Counted under a lock: the checks run on many threads.
        let mistakes = Shared(0)
        let fixture = bench
        DispatchQueue.concurrentPerform(iterations: 2_000) { index in
            let listing = listings[index % listings.count]
            let order = orders[index % orders.count]
            let isRight = Self.exercise(cache, of: fixture, with: listing, in: order, step: index)
            if !isRight {
                mistakes.modify { $0 += 1 }
            }
        }
        #expect(mistakes.value == 0)
    }
}
