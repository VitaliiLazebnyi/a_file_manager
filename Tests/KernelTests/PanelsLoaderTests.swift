import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Reading what a panel shows when nothing on the way can be read, the listing cache's view of
/// volumes it knows nothing about, and sorting a list too short to sort.
@Suite
internal struct PanelsLoaderTests {
    /// Climbing from a folder that is gone ends with the error when no folder above can be read.
    @Test
    internal func climbingEndsWithTheErrorWhenNothingCanBeRead() {
        let memory = MemoryFileSystem()
        _ = memory.addDirectory("/top")
        memory.unreadable = ["/", "/top"]
        let fileSystems = FileSystemRegistry()
        fileSystems.register(memory)
        var batches = 0
        let gone = memory.url("/top/gone")
        #expect(throws: (any Error).self) {
            try PanelLoader.stream(climbingFrom: gone, showHidden: false, fileSystems: fileSystems) { _ in
                batches += 1
                return true
            }
        }
        #expect(batches == 0)
    }

    /// A listing that breaks off after its first batch: the batch arrives, and then the error.
    @Test
    internal func aListingThatBreaksOffDeliversWhatCameAndThrows() {
        let broken = PanelsBrokenListing()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(broken)
        var names: [String] = []
        #expect(throws: PanelsBrokenListing.Broken.self) {
            try PanelLoader.stream(broken.url("/folder"), showHidden: false, fileSystems: fileSystems) { batch in
                names += batch.listing.items.map(\.name)
                return true
            }
        }
        #expect(names == ["first"])
    }

    /// Climbing ends at the first folder above that delivers anything, even if its listing then
    /// breaks off: what came is shown, and no error.
    @Test
    internal func climbingEndsWhereSomethingArrived() throws {
        let broken = PanelsBrokenListing(failing: ["/gone", "/gone/away"])
        let fileSystems = FileSystemRegistry()
        fileSystems.register(broken)
        var batches: [PanelLoader.Batch] = []
        let away = broken.url("/gone/away")
        try PanelLoader.stream(climbingFrom: away, showHidden: false, fileSystems: fileSystems) { batch in
            batches.append(batch)
            return true
        }
        #expect(batches.map(\.listing.directory.path) == ["/"] && batches.allSatisfy(\.isFirst))
    }

    /// A listing whose first batch is not wanted is told to stop: its file system sees the flag.
    @Test
    internal func aListingNotWantedIsToldToStop() throws {
        let broken = PanelsBrokenListing()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(broken)
        var batches = 0
        try PanelLoader.stream(broken.url("/folder"), showHidden: false, fileSystems: fileSystems) { _ in
            batches += 1
            return false
        }
        #expect(batches == 1 && Wait.until { broken.wasToldToStop })
    }

    /// A reading that was cancelled before it began is no listing.
    @Test
    internal func aCancelledReadingIsNoListing() {
        let memory = MemoryFileSystem()
        _ = memory.addFile("/a/b.txt")
        let fileSystems = FileSystemRegistry()
        fileSystems.register(memory)
        let flag = CancellationFlag()
        flag.cancel()
        #expect(throws: CocoaError.self) {
            try PanelLoader.load(memory.url("/a"), showHidden: false, fileSystems: fileSystems, cancellation: flag)
        }
    }

    /// A listing from a volume nobody described is remembered only when it took long to read.
    @Test
    internal func aListingWithoutVolumeIsKeptWhenSlow() {
        let cache = ListingCache()
        let directory = URL(fileURLWithPath: "/nowhere")
        let listing = Listing(directory: directory, items: [], parent: nil, root: directory)
        #expect(
            !cache.store(listing, sortedBy: ListOrder(), showHidden: false, readTime: 0, since: cache.startReading())
        )
        #expect(
            cache.store(listing, sortedBy: ListOrder(), showHidden: false, readTime: 1, since: cache.startReading())
        )
    }

    /// A list of one name is in order as it is.
    @Test
    internal func oneNameIsSortedAsItIs() {
        #expect(Sorter.sorted(["only"]) { $0 } == ["only"])
        #expect(Sorter.sorted([String]()) { $0 }.isEmpty)
    }
}
