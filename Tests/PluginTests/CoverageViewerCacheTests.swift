import AFMKernel
import Darwin
import Foundation
import Testing

@testable import ViewerPlugin

/// The blocks of a file the viewer keeps: on disk within a shared budget, and in memory.
@Suite
internal struct CoverageViewerCacheTests {
    // MARK: Disk cache

    /// The caches share the room their budget gives; what is let go goes back to it.
    @Test
    internal func cachesStopWhereTheirSharedBudgetEnds() {
        let budget = DiskBudget(limit: 2_500)
        let first = DiskBlockCache(
            blockSize: 1_000,
            length: 10_000,
            limit: 10_000,
            budget: budget,
            openFile: DiskBlockCache.openUnnamedFile
        )
        let second = DiskBlockCache(
            blockSize: 1_000,
            length: 10_000,
            limit: 10_000,
            budget: budget,
            openFile: DiskBlockCache.openUnnamedFile
        )
        first.store(0, Data(repeating: 1, count: 1_000))
        second.store(0, Data(repeating: 2, count: 1_000))
        first.store(1, Data(repeating: 3, count: 1_000))
        #expect(budget.heldBytes == 2_000 && first.contains(0) && second.contains(0) && !first.contains(1))
        second.discard()
        #expect(budget.heldBytes == 1_000)
        first.store(1, Data(repeating: 3, count: 1_000))
        #expect(first.read(1) == Data(repeating: 3, count: 1_000) && budget.heldBytes == 2_000)
        first.discard()
        #expect(budget.heldBytes == 0)
    }

    /// A cache that cannot make its file keeps nothing and gives its room back.
    @Test
    internal func aCacheWithoutAFileKeepsNothing() {
        let budget = DiskBudget(limit: 10_000)
        let cache = DiskBlockCache(blockSize: 1_000, length: 4_000, limit: 4_000, budget: budget) { -1 }
        cache.store(0, Data(repeating: 1, count: 1_000))
        cache.store(1, Data(repeating: 1, count: 1_000))
        #expect(!cache.isOpen && !cache.contains(0) && cache.storedBytes == 0 && budget.heldBytes == 0)
    }

    /// A block the disk does not give back whole is forgotten, and its room given back.
    @Test
    internal func aBlockTheDiskLostIsForgotten() {
        let budget = DiskBudget(limit: 10_000)
        // What is written to /dev/null is accepted; reading it gives nothing.
        let cache = DiskBlockCache(blockSize: 1_000, length: 4_000, limit: 4_000, budget: budget) {
            open("/dev/null", O_RDWR | O_CLOEXEC)
        }
        cache.store(2, Data(repeating: 5, count: 1_000))
        #expect(cache.contains(2) && cache.storedBytes == 1_000 && budget.heldBytes == 1_000)
        #expect(cache.read(2) == nil)
        #expect(!cache.contains(2) && cache.storedBytes == 0 && budget.heldBytes == 0)
    }

    /// A write that fails (a full disk) stops the caching for good.
    @Test
    internal func aFailedWriteStopsTheCaching() {
        let budget = DiskBudget(limit: 10_000)
        let cache = DiskBlockCache(blockSize: 1_000, length: 4_000, limit: 4_000, budget: budget) {
            open("/dev/null", O_RDONLY | O_CLOEXEC)
        }
        cache.store(0, Data(repeating: 6, count: 1_000))
        cache.store(1, Data(repeating: 6, count: 1_000))
        #expect(!cache.contains(0) && !cache.contains(1) && cache.storedBytes == 0 && budget.heldBytes == 0)
    }

    /// The shared temporary file is made and gone from its folder at once.
    @Test
    internal func theBlockFileHasNoNameOnceOpen() {
        let descriptor = DiskBlockCache.openUnnamedFile()
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        #expect(fcntl(descriptor, F_GETPATH, &path) == 0)
        let name = String(bytes: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
        #expect(name.contains("afm-viewer-p") && !FileManager.default.fileExists(atPath: name))
    }

    // MARK: Memory cache

    /// Without a disk cache there are no bytes on disk.
    @Test
    internal func aSourceThatDoesNotSpillHasNothingOnDisk() {
        let cached = CachedByteSource(DataByteSource(Data(count: 10)), policy: .standard)
        #expect(cached.diskBytes == 0 && !cached.diskCacheIsOpen)
    }

    /// A file kept whole that became shorter: the blocks that are there whole are kept, a short
    /// one in the middle is not, and what is not there is not made up.
    @Test
    internal func aWholeFileThatBecameShorterKeepsOnlyWholeBlocks() throws {
        let base = CoverageViewerShortSource(length: 1_000, available: 250)
        let cached = CachedByteSource(
            base,
            policy: CachedByteSource.Policy(
                blockSize: 100,
                capacity: 20,
                wholeFileLimit: 10_000,
                spillsToDisk: false,
                diskLimit: 1 << 30
            )
        )
        let all = try cached.read(at: 0, count: 1_000)
        #expect(all == base.read(at: 0, count: 1_000) && all.count == 250)
        // Blocks 0 and 1 are kept: read again they come from memory.
        #expect(try cached.read(at: 0, count: 200) == base.read(at: 0, count: 200))
        // Read again from the start, the kept blocks stay as they are.
        #expect(try cached.read(at: 0, count: 1_000).count == 250)
        // A long read of what is not there at all gives nothing.
        #expect(try cached.read(at: 500, count: 400).isEmpty)
    }

    /// A long read through the disk cache ends where a short read of the base ends.
    @Test
    internal func aLongReadThroughTheDiskEndsWhereTheFileEnds() throws {
        let base = CoverageViewerShortSource(length: 10_000, available: 2_500)
        let cached = CachedByteSource(
            base,
            policy: CachedByteSource.Policy(
                blockSize: 1_000,
                capacity: 2,
                wholeFileLimit: 0,
                spillsToDisk: true,
                diskLimit: 1 << 30
            )
        )
        defer { cached.close() }
        let data = try cached.read(at: 0, count: 8_000)
        #expect(data == base.read(at: 0, count: 2_500))
        // The two whole blocks were stored on disk, the short third was not.
        #expect(cached.diskBytes == 2_000)
    }
}
