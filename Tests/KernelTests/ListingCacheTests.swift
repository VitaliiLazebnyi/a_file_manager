import AFMKernel
import Foundation
import TestSupport
import Testing

/// The memory of slow folders: what it keeps, what it lets go of, and that it can be used from
/// several threads at once.
@Suite struct RememberedListings {
    /// A clock the test moves by hand. Used from one thread at a time.
    final class Clock {
        var time = Date(timeIntervalSince1970: 1_000_000)
    }

    let clock = Clock()
    let share = VolumeInfo(name: "Share", isLocal: false)
    let disk = VolumeInfo(name: "Disk", isLocal: true)
    let name = ListOrder(key: .name)

    func cache(folders: Int = 20, entries: Int = 300_000) -> ListingCache {
        var limits = ListingCache.Limits()
        limits.maxFolders = folders
        limits.maxEntries = entries
        return ListingCache(limits: limits, now: { [clock] in clock.time })
    }

    func url(_ path: String) -> URL { URL(string: "mem://" + path)! }

    func listing(_ path: String, _ names: [String], volume: VolumeInfo? = nil, sortedBy order: ListOrder? = nil)
        -> Listing
    {
        let directory = url(path)
        let items = names.enumerated().map { index, name in
            FileItem(url: directory.appending(name: name), name: name, isDirectory: false, size: Int64(index))
        }
        return Listing(
            directory: directory, items: Sorter.sort(items, by: order ?? name), parent: nil, root: url("/"),
            volume: volume ?? share)
    }

    func files(_ count: Int) -> [String] { (0..<count).map { "f\($0).txt" } }

    @Test func hitAndMiss() {
        let cache = cache()
        #expect(cache.entry(for: url("/a"), showHidden: false) == nil)
        #expect(
            cache.store(
                listing("/a", ["x.txt", "y.txt"]), sortedBy: name, showHidden: false, readTime: 0,
                since: cache.startReading()))
        let entry = cache.entry(for: url("/a"), showHidden: false)
        #expect(
            entry?.listing.items.map(\.name) == ["x.txt", "y.txt"] && entry?.order == name
                && entry?.readAt == clock.time)
        // The same place written with a trailing slash; another place.
        #expect(cache.entry(for: url("/a/"), showHidden: false) != nil)
        #expect(cache.entry(for: url("/b"), showHidden: false) == nil)
        #expect(cache.folderCount == 1 && cache.entryCount == 2)
    }

    @Test func localFoldersAreKeptOnlyWhenTheyWereSlowToRead() {
        let cache = cache()
        #expect(
            !cache.store(
                listing("/quick", ["x"], volume: disk), sortedBy: name, showHidden: false, readTime: 0.02,
                since: cache.startReading()))
        #expect(
            cache.store(
                listing("/slow", ["x"], volume: disk), sortedBy: name, showHidden: false, readTime: 0.2,
                since: cache.startReading()))
        // On a share every folder is kept, however quickly it came.
        #expect(
            cache.store(
                listing("/share", ["x"], volume: share), sortedBy: name, showHidden: false, readTime: 0.001,
                since: cache.startReading()))
        #expect(cache.folderCount == 2)
        // A folder that is remembered is brought up to date by every later reading, also a quick one.
        clock.time += 5
        #expect(
            cache.store(
                listing("/slow", ["x", "y"], volume: disk), sortedBy: name, showHidden: false, readTime: 0.01,
                since: cache.startReading()))
        #expect(cache.entry(for: url("/slow"), showHidden: false)?.listing.items.count == 2)
        #expect(cache.age(of: url("/slow"), showHidden: false) == 0)
    }

    @Test func theLeastRecentlyUsedFolderGoesFirst() {
        let cache = cache(folders: 3)
        for path in ["/1", "/2", "/3"] {
            cache.store(
                listing(path, ["x"]), sortedBy: name, showHidden: false, readTime: 0, since: cache.startReading())
        }
        // /1 is used again, so /2 is the one that makes room.
        #expect(cache.entry(for: url("/1"), showHidden: false) != nil)
        cache.store(listing("/4", ["x"]), sortedBy: name, showHidden: false, readTime: 0, since: cache.startReading())
        #expect(cache.folderCount == 3)
        #expect(cache.age(of: url("/2"), showHidden: false) == nil)
        #expect(["/1", "/3", "/4"].allSatisfy { cache.age(of: url($0), showHidden: false) != nil })
    }

    @Test func theTotalNumberOfEntriesIsLimited() {
        let cache = cache(entries: 100)
        cache.store(
            listing("/1", files(40)), sortedBy: name, showHidden: false, readTime: 0, since: cache.startReading())
        cache.store(
            listing("/2", files(40)), sortedBy: name, showHidden: false, readTime: 0, since: cache.startReading())
        #expect(cache.entryCount == 80)
        // 40 more do not fit: the oldest folder goes.
        cache.store(
            listing("/3", files(40)), sortedBy: name, showHidden: false, readTime: 0, since: cache.startReading())
        #expect(cache.entryCount == 80 && cache.age(of: url("/1"), showHidden: false) == nil)
        // A folder that is larger than the whole limit is not remembered, and what was
        // remembered of it before is dropped rather than left out of date.
        #expect(
            !cache.store(
                listing("/huge", files(101)), sortedBy: name, showHidden: false, readTime: 0,
                since: cache.startReading()))
        #expect(cache.folderCount == 2)
        #expect(
            !cache.store(
                listing("/2", files(101)), sortedBy: name, showHidden: false, readTime: 0, since: cache.startReading()
            )
        )
        #expect(cache.age(of: url("/2"), showHidden: false) == nil && cache.entryCount == 40)
        // Exactly the limit fits, alone.
        #expect(
            cache.store(
                listing("/full", files(100)), sortedBy: name, showHidden: false, readTime: 0,
                since: cache.startReading()))
        #expect(cache.folderCount == 1 && cache.entryCount == 100)
    }

    @Test func anotherOrderIsSortedOnRequestAndKept() {
        let cache = cache()
        cache.store(
            listing("/a", ["b.txt", "a.txt", "c.txt"]), sortedBy: name, showHidden: false, readTime: 0,
            since: cache.startReading())
        let reversed = ListOrder(key: .name, descending: true)
        // The cheap lookup hands out what is there, in the order it is in.
        #expect(cache.entry(for: url("/a"), showHidden: false)?.order == name)
        let sorted = cache.entry(for: url("/a"), showHidden: false, sortedBy: reversed)
        #expect(sorted?.order == reversed && sorted?.listing.items.map(\.name) == ["c.txt", "b.txt", "a.txt"])
        // From then on it is kept that way; when it was read stays what it was.
        clock.time += 30
        let kept = cache.entry(for: url("/a"), showHidden: false)
        #expect(kept?.order == reversed && kept?.listing.items.map(\.name) == ["c.txt", "b.txt", "a.txt"])
        #expect(cache.age(of: url("/a"), showHidden: false) == 30)
        let bySize = cache.entry(for: url("/a"), showHidden: false, sortedBy: ListOrder(key: .size, descending: true))
        // Sizes follow the order the names were given in: b 0, a 1, c 2.
        #expect(bySize?.listing.items.map(\.name) == ["c.txt", "a.txt", "b.txt"])
        #expect(cache.entry(for: url("/missing"), showHidden: false, sortedBy: reversed) == nil)
    }

    @Test func withAndWithoutHiddenFilesAreTwoListings() {
        let cache = cache()
        cache.store(
            listing("/a", ["x.txt"]), sortedBy: name, showHidden: false, readTime: 0, since: cache.startReading())
        #expect(cache.entry(for: url("/a"), showHidden: true) == nil)
        cache.store(
            listing("/a", [".secret", "x.txt"]), sortedBy: name, showHidden: true, readTime: 0,
            since: cache.startReading())
        #expect(cache.entry(for: url("/a"), showHidden: false)?.listing.items.count == 1)
        #expect(cache.entry(for: url("/a"), showHidden: true)?.listing.items.count == 2)
        #expect(cache.entry(for: url("/a"), showHidden: true)?.showHidden == true && cache.folderCount == 2)
    }

    @Test func anOldListingIsNotHandedOut() {
        let cache = cache()
        cache.store(
            listing("/a", ["x.txt"]), sortedBy: name, showHidden: false, readTime: 0, since: cache.startReading())
        clock.time += 10 * 60
        #expect(cache.entry(for: url("/a"), showHidden: false) != nil)
        clock.time += 1
        #expect(cache.entry(for: url("/a"), showHidden: false) == nil)
        // It is gone for good, not only hidden.
        #expect(cache.folderCount == 0)
        clock.time -= 60
        #expect(cache.entry(for: url("/a"), showHidden: false) == nil)
    }

    @Test func changedFoldersAreForgottenWithWhatLiesBelowAndTheFolderAbove() {
        let cache = cache()
        for path in ["/", "/work", "/work/in", "/work/in/deep", "/work/inside", "/other"] {
            cache.store(
                listing(path, ["x"]), sortedBy: name, showHidden: false, readTime: 0, since: cache.startReading())
        }
        cache.store(
            listing("/work/in", ["x"]), sortedBy: name, showHidden: true, readTime: 0, since: cache.startReading())
        cache.invalidate([url("/work/in")])
        func isKept(_ path: String) -> Bool { cache.age(of: url(path), showHidden: false) != nil }
        // The folder (in both variants), what is below it, and the folder that lists it.
        #expect(!isKept("/work/in") && cache.age(of: url("/work/in"), showHidden: true) == nil)
        #expect(!isKept("/work/in/deep") && !isKept("/work"))
        // A neighbour whose name merely starts the same, and everything else, stays.
        #expect(isKept("/work/inside") && isKept("/other") && isKept("/"))
        // Forgetting one folder leaves the one above alone.
        cache.forget(url("/work/inside"))
        #expect(!isKept("/work/inside") && isKept("/"))
        cache.invalidate([url("/")])
        #expect(cache.folderCount == 0)
    }

    @Test func aReadingThatWasOvertakenIsNotKept() {
        let cache = cache()
        // Two readings of the same folder overlap; the one that started later ends first.
        let (early, late) = (cache.startReading(), cache.startReading())
        #expect(cache.store(listing("/a", ["new"]), sortedBy: name, showHidden: false, readTime: 0, since: late))
        #expect(!cache.store(listing("/a", ["old"]), sortedBy: name, showHidden: false, readTime: 0, since: early))
        #expect(cache.entry(for: url("/a"), showHidden: false)?.listing.items.map(\.name) == ["new"])
        // A folder is reported changed while it is being read: what that reading brings may
        // be from before the change.
        let before = cache.startReading()
        cache.invalidate([url("/a")])
        #expect(!cache.store(listing("/a", ["stale"]), sortedBy: name, showHidden: false, readTime: 0, since: before))
        #expect(cache.folderCount == 0)
        #expect(
            cache.store(
                listing("/a", ["fresh"]), sortedBy: name, showHidden: false, readTime: 0, since: cache.startReading())
        )
    }

    @Test func switchedOffItKeepsNothing() {
        let cache = cache()
        cache.store(listing("/a", ["x"]), sortedBy: name, showHidden: false, readTime: 0, since: cache.startReading())
        cache.isEnabled = false
        #expect(cache.folderCount == 0)
        #expect(
            !cache.store(
                listing("/a", ["x"]), sortedBy: name, showHidden: false, readTime: 0, since: cache.startReading()))
        cache.isEnabled = true
        #expect(
            cache.store(
                listing("/a", ["x"]), sortedBy: name, showHidden: false, readTime: 0, since: cache.startReading()))
        cache.removeAll()
        #expect(cache.folderCount == 0)
    }

    @MainActor @Test func theKernelSwitchesItFromTheSettings() {
        let settings = MemorySettings()
        #expect(Kernel(productName: "Test", settings: settings, ui: ScriptedInteraction()).listingCache.isEnabled)
        settings.set(false, forKey: ListingCache.settingsKey)
        #expect(!Kernel(productName: "Test", settings: settings, ui: ScriptedInteraction()).listingCache.isEnabled)
    }

    @Test func manyThreadsAtOnce() {
        let cache = ListingCache(
            limits: {
                var limits = ListingCache.Limits()
                limits.maxFolders = 8
                limits.maxEntries = 2_000
                return limits
            }())
        let orders = [
            ListOrder(key: .name), ListOrder(key: .name, descending: true), ListOrder(key: .size), ListOrder(key: .ext)
        ]
        let listings = (0..<16).map { listing("/dir\($0)", files(50 + $0 * 20)) }
        // Counted under a lock: the checks run on many threads.
        let lock = NSLock()
        // Guarded by `lock`.
        nonisolated(unsafe) var mistakes = 0
        @Sendable func check(_ condition: Bool) {
            guard !condition else { return }
            lock.lock()
            mistakes += 1
            lock.unlock()
        }
        let name = name
        DispatchQueue.concurrentPerform(iterations: 2_000) { index in
            let listing = listings[index % listings.count]
            let order = orders[index % orders.count]
            switch index % 7 {
            case 0, 1:
                cache.store(
                    listing, sortedBy: name, showHidden: index % 2 == 0, readTime: 0, since: cache.startReading())

            case 2: _ = cache.entry(for: listing.directory, showHidden: index % 2 == 0)

            case 3, 4:
                // Whatever is handed out is one whole listing in the order that was asked for.
                if let entry = cache.entry(for: listing.directory, showHidden: index % 2 == 0, sortedBy: order) {
                    let items = entry.listing.items
                    check(entry.order == order && items.count == listing.items.count)
                    check(zip(items, items.dropFirst()).allSatisfy { !Sorter.areInOrder($1, $0, by: order) })
                }

            case 5: cache.invalidate([listing.directory])
            default: _ = cache.age(of: listing.directory, showHidden: false)
            }
            check(cache.folderCount <= 8 && cache.entryCount <= 2_000)
        }
        #expect(mistakes == 0)
    }
}

/// The panel model's side of "show old, refresh behind".
extension Panel {
    @Test func aRememberedListingIsShownUntilTheFreshOneArrives() throws {
        let remembered = try listing("/work/docs")
        memory.addFile("/work/docs/new.txt")
        memory.addFile("/work/docs/old.txt")
        let before = panel.snapshot()
        panel.showRemembered(try listing("/work/docs"), focus: "old.txt")
        // It can be used, but it is not known to be all there is.
        #expect(
            panel.directory.path == "/work/docs" && panel.isListed && panel.isRefreshing && !panel.isComplete
                && !panel.isOpening)
        #expect(panel.cursorItem?.name == "old.txt" && panel.backLocation?.path == "/work")
        panel.toggleSelection(row: panel.cursor)
        // The fresh listing takes its place and keeps cursor and selection.
        memory.addFile("/work/docs/another.txt")
        #expect(panel.update(with: try listing("/work/docs")))
        #expect(panel.isComplete && !panel.isRefreshing && panel.items.count == 3)
        #expect(
            panel.cursorItem?.name == "old.txt" && panel.selection == ["old.txt"] && panel.backLocation?.path == "/work"
        )

        // A fresh reading that fails: back to where the panel was.
        panel.restore(before)
        panel.showRemembered(remembered)
        #expect(panel.isRefreshing && panel.items.isEmpty)
        panel.restore(before)
        #expect(
            panel.directory.path == "/work" && panel.isComplete && !panel.isRefreshing && panel.forwardLocation == nil)
        // A snapshot taken in between remembers that the list was only a remembered one.
        panel.showRemembered(remembered)
        let between = panel.snapshot()
        try show("/work/bin")
        panel.restore(between)
        #expect(panel.directory.path == "/work/docs" && panel.isRefreshing && !panel.isComplete)
        panel.finishLoading()
        #expect(panel.isComplete && !panel.isRefreshing)
    }
}
