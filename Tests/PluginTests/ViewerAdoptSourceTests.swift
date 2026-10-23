import AFMKernel
import Foundation
import Testing

@testable import ViewerPlugin

/// Reading remote files without reading them again: the disk cache of the blocks read.
@Suite
internal struct ViewerAdoptSourceTests {
    // MARK: Disk cache

    /// Blocks of the right size are kept on disk and read back; discarding empties the cache, which starts anew.
    @Test
    internal func blocksAreKeptOnDiskAndGivenBack() {
        let cache = DiskBlockCache(blockSize: 1_000, length: 4_500, limit: 1 << 30)
        #expect(!cache.isOpen && cache.read(0) == nil && !cache.contains(0))
        let first = Data((0..<1_000).map { UInt8($0 % 251) })
        let tail = Data(repeating: 7, count: 500)
        cache.store(2, first)
        cache.store(4, tail)
        // A block of the wrong size (a short read in the middle) is not kept.
        cache.store(1, Data(repeating: 1, count: 999))
        cache.store(3, Data(repeating: 1, count: 1_001))
        #expect(
            cache.isOpen && cache.contains(2) && cache.contains(4) && !cache.contains(1) && !cache.contains(3)
                && !cache.contains(0)
        )
        #expect(cache.read(2) == first && cache.read(4) == tail && cache.read(0) == nil)
        #expect(cache.storedBytes == 1_500)
        cache.discard()
        #expect(!cache.isOpen && cache.storedBytes == 0 && cache.read(2) == nil)
        // It starts anew when it is used again.
        cache.store(2, first)
        #expect(cache.read(2) == first)
    }

    /// A cache keeps no more blocks than its limit allows, the first ones stored.
    @Test
    internal func aCacheStopsAtItsLimit() {
        let cache = DiskBlockCache(blockSize: 1_000, length: 10_000, limit: 3_000)
        for block in 0..<10 { cache.store(Int64(block), Data(repeating: UInt8(block), count: 1_000)) }
        #expect(cache.storedBytes == 3_000)
        #expect((0..<10).filter { cache.contains(Int64($0)) } == [0, 1, 2])
        #expect(cache.read(1) == Data(repeating: 1, count: 1_000))
    }

    /// A UTF-8 text of `source` laid out with `options`, its rows found.
    private func indexed(
        _ source: any ByteSource,
        _ options: TextLayoutOptions,
        reusing previous: TextDocument?,
        parallel: Bool
    ) -> TextDocument {
        let document = TextDocument(
            source: source,
            encoding: .utf8,
            bomLength: 0,
            layout: .text(options),
            reusing: previous
        )
        document.buildIndex(parallel: parallel, scanning: .standard) {
            // Not watched here.
        }
        return document
    }

    /// A big file of a slow source is fetched once: new layouts read it from the disk and find the rows of the file
    /// in memory; closing the source lets go of the disk.
    @Test
    internal func aBigFileOfASlowSourceIsNotFetchedAgainWhenItIsLaidOutAgain() throws {
        let data = ViewerRemoteLike.text(megabytes: 24)
        let remote = ViewerRemoteLike(data)
        let cached = CachedByteSource(
            remote,
            policy: CachedByteSource.Policy(
                blockSize: 64 << 10,
                capacity: 16,
                wholeFileLimit: 1 << 20,
                spillsToDisk: true,
                diskLimit: 1 << 30
            )
        )
        defer { cached.close() }
        // Index it once: every byte comes from the "server".
        var previous = indexed(
            cached,
            TextLayoutOptions(columns: 80, wordWrap: true, tabWidth: 8),
            reusing: nil,
            parallel: false
        )
        let fetchedOnce = remote.fetched
        #expect(previous.isIndexComplete && fetchedOnce >= remote.length && fetchedOnce <= remote.length + 2 * 64 << 10)
        #expect(cached.diskBytes >= remote.length && cached.diskCacheIsOpen)
        // Another width, another zoom, wrapping off: not one more byte, and the same rows as a
        // text in memory gets.
        for options in [
            TextLayoutOptions(columns: 120, wordWrap: true, tabWidth: 8),
            TextLayoutOptions(columns: 40, wordWrap: true, tabWidth: 8),
            TextLayoutOptions(columns: 200, wordWrap: false, tabWidth: 8),
            TextLayoutOptions(columns: 80, wordWrap: true, tabWidth: 4)
        ] {
            let document = indexed(cached, options, reusing: previous, parallel: false)
            let reference = indexed(DataByteSource(data), options, reusing: nil, parallel: true)
            #expect(remote.fetched == fetchedOnce, "relayout \(options)")
            #expect(document.rowCount == reference.rowCount && document.lineCount == reference.lineCount)
            for first in [0, 1_000, reference.rowCount / 2, reference.rowCount - 3] {
                #expect(
                    try document.rows(from: first, count: 40, cancellation: nil).map(\.range)
                        == reference.rows(from: first, count: 40, cancellation: nil).map(\.range)
                )
            }
            #expect(remote.fetched == fetchedOnce, "rows after relayout \(options)")
            previous = document
        }
        // Closing lets go of the disk; reading again fetches again.
        cached.close()
        #expect(cached.diskBytes == 0 && !cached.diskCacheIsOpen)
        let again = try cached.read(at: 1 << 20, count: 100)
        #expect(again == data.subdata(in: 1 << 20..<(1 << 20) + 100) && remote.fetched > fetchedOnce)
    }

    /// Searching a file again, forward or backward, once it is on disk asks the server for nothing.
    @Test
    internal func aSearchOfAFileThatIsOnDiskAsksTheServerForNothing() throws {
        let data = ViewerRemoteLike.text(megabytes: 6)
        let remote = ViewerRemoteLike(data)
        let cached = CachedByteSource(
            remote,
            policy: CachedByteSource.Policy(
                blockSize: 32 << 10,
                capacity: 8,
                wholeFileLimit: 1 << 20,
                spillsToDisk: true,
                diskLimit: 1 << 30
            )
        )
        defer { cached.close() }
        let pattern = try SearchPattern("zzz-not-there", options: SearchOptions(), encoding: .utf8)
        let subject = ViewerSearch.Subject(source: cached, content: 0..<cached.length, encoding: .utf8, boundaries: nil)
        func search(from start: Int64, backwards: Bool, tuning: ViewerSearch.Tuning) throws -> Range<Int64>? {
            try ViewerSearch.find(
                ViewerSearch.Request(pattern: pattern, start: start, backwards: backwards),
                in: subject,
                tuning: tuning,
                cancellation: CancellationFlag()
            ) { _ in
                // Not watched here.
            }
        }
        #expect(try search(from: 0, backwards: false, tuning: .standard) == nil)
        let first = remote.fetched
        #expect(first >= remote.length)
        #expect(try search(from: 0, backwards: false, tuning: .standard) == nil)
        var smaller = ViewerSearch.Tuning.standard
        smaller.chunkSize = 300_000
        #expect(try search(from: cached.length, backwards: true, tuning: smaller) == nil)
        #expect(remote.fetched == first)
    }

    /// A source whose disk cache reaches its limit still reads every byte right.
    @Test
    internal func aSourceWhoseDiskIsFullGoesOnWithoutIt() throws {
        let data = ViewerRemoteLike.text(megabytes: 2)
        let remote = ViewerRemoteLike(data)
        let cached = CachedByteSource(
            remote,
            policy: CachedByteSource.Policy(
                blockSize: 16 << 10,
                capacity: 4,
                wholeFileLimit: 0,
                spillsToDisk: true,
                diskLimit: 100 << 10
            )
        )
        defer { cached.close() }
        #expect(try cached.read(at: 0, count: data.count) == data)
        #expect(cached.diskBytes <= 100 << 10 && cached.diskBytes > 0)
        #expect(try cached.read(at: 500_000, count: 700_000) == data.subdata(in: 500_000..<1_200_000))
    }
}
