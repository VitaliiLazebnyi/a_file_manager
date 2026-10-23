import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// Reads, indexes, searches and copies of files that never answer end with their flags.
@Suite
internal struct ViewerAdoptCancellationTests {
    /// A text file of about `size` bytes in the memory file system, and a registry that knows that file system.
    private func stalledFile(_ memory: MemoryFileSystem, size: Int) -> (FileSystemRegistry, URL) {
        let registry = FileSystemRegistry()
        registry.register(memory)
        let url = memory.addFile("/far/big.txt", String(repeating: "line of text\n", count: size / 13))
        return (registry, url)
    }

    /// A read that waits for a stalled server ends with an error when its flag is set, and the source can be read
    /// again afterwards.
    @Test
    internal func aReadThatWaitsForTheServerEndsWhenItsFlagIsSet() throws {
        let memory = MemoryFileSystem()
        let (registry, url) = stalledFile(memory, size: 100_000)
        let source = try ProviderByteSource.open(url, fileSystems: registry, cancellation: CancellationFlag())
        memory.stallsReads = true
        for attempt in 1...5 {
            let flag = CancellationFlag()
            let outcome = ViewerAdoptBox<Result<Data, any Error>?>(nil)
            let worker = ViewerAdoptWorker {
                outcome.value = Result { try source.read(at: 10, count: 5_000, cancellation: flag) }
            }
            worker.start()
            #expect(worker.waitUntilWaiting())
            let before = memory.interruptions
            flag.cancel()
            #expect(worker.waitUntilFinished(), "attempt \(attempt)")
            if case .success? = outcome.value { Issue.record("The read was not ended") }
            if memory.interruptions > before { break }
            // The flag was set before the read began (nothing waited yet): try again.
            #expect(attempt < 5, "the blocked read was never interrupted")
        }
        // The source is usable again afterwards, with another flag.
        memory.stallsReads = false
        #expect(try source.read(at: 0, count: 13, cancellation: CancellationFlag()) == Data("line of text\n".utf8))
    }

    /// A set flag ends the reads it was given and no others.
    @Test
    internal func aFlagOnlyEndsTheReadsItWasGiven() throws {
        let memory = MemoryFileSystem()
        let (registry, url) = stalledFile(memory, size: 50_000)
        let source = CachedByteSource(
            try ProviderByteSource.open(url, fileSystems: registry, cancellation: CancellationFlag()),
            policy: CachedByteSource.Policy(
                blockSize: 4_096,
                capacity: 4,
                wholeFileLimit: 0,
                spillsToDisk: false,
                diskLimit: 1 << 30
            )
        )
        let other = CancellationFlag()
        let mine = CancellationFlag()
        mine.cancel()
        #expect(throws: (any Error).self) { try source.read(at: 0, count: 100, cancellation: mine) }
        #expect(try source.read(at: 0, count: 100, cancellation: other).count == 100)
        // A reader that a cancelled read had out is not handed to the next one.
        #expect(try source.read(at: 20_000, count: 100).count == 100)
    }

    /// Indexing a file whose server never answers stops, without an error, when the document is cancelled.
    @Test
    internal func indexingAFileThatNeverAnswersStopsWhenTheDocumentIsDropped() throws {
        let memory = MemoryFileSystem()
        let (registry, url) = stalledFile(memory, size: 400_000)
        let source = CachedByteSource(
            try ProviderByteSource.open(url, fileSystems: registry, cancellation: CancellationFlag()),
            policy: .standard
        )
        memory.stallsReads = true
        let document = TextDocument(
            source: source,
            encoding: .utf8,
            bomLength: 0,
            layout: .text(TextLayoutOptions(columns: 80, wordWrap: true, tabWidth: 8)),
            reusing: nil
        )
        let worker = ViewerAdoptWorker {
            document.buildIndex(parallel: false, scanning: .standard) {
                // Not watched here.
            }
        }
        worker.start()
        #expect(worker.waitUntilWaiting())
        document.cancellation.cancel()
        #expect(worker.waitUntilFinished())
        #expect(!document.isIndexComplete && document.readError == nil && memory.interruptions >= 1)
    }

    /// A fetch of rows that waits for the server ends when the next fetch overtakes it, and a fetch tied to the
    /// document ends with the document.
    @Test
    internal func fetchingRowsFromAFileThatNeverAnswersEndsWhenTheFetchIsOvertaken() throws {
        let memory = MemoryFileSystem()
        let (registry, url) = stalledFile(memory, size: 100_000)
        let source = try ProviderByteSource.open(url, fileSystems: registry, cancellation: CancellationFlag())
        let document = TextDocument(
            source: source,
            encoding: .utf8,
            bomLength: 0,
            layout: .text(TextLayoutOptions(columns: 80, wordWrap: true, tabWidth: 8)),
            reusing: nil
        )
        document.buildIndex(parallel: false, scanning: .standard) {
            // Not watched here.
        }
        // The readers the index used are not stalled; new ones are.
        source.close()
        memory.stallsReads = true
        let fetch = LinkedCancellation(document.cancellation)
        let outcome = ViewerAdoptBox<Result<[DisplayRow], any Error>?>(nil)
        let worker = ViewerAdoptWorker {
            outcome.value = Result { try document.rows(from: 3_000, count: 20, cancellation: fetch.flag) }
        }
        worker.start()
        #expect(worker.waitUntilWaiting())
        // The next fetch replaces this one.
        fetch.flag.cancel()
        #expect(worker.waitUntilFinished())
        if case .success? = outcome.value { Issue.record("The fetch was not ended") }
        #expect(document.readError == nil)
        // A fetch tied to the document ends with it.
        let tied = LinkedCancellation(document.cancellation)
        let second = ViewerAdoptBox<Result<Int?, any Error>?>(nil)
        let again = ViewerAdoptWorker {
            second.value = Result { try document.row(containing: 90_000, cancellation: tied.flag) }
        }
        again.start()
        #expect(again.waitUntilWaiting())
        document.cancellation.cancel()
        #expect(again.waitUntilFinished() && tied.flag.isCancelled)
    }

    /// A search through a file that never answers ends with its flag and finds nothing, without failing.
    @Test
    internal func aSearchThroughAFileThatNeverAnswersEndsWithItsFlag() throws {
        let memory = MemoryFileSystem()
        let (registry, url) = stalledFile(memory, size: 300_000)
        let source = CachedByteSource(
            try ProviderByteSource.open(url, fileSystems: registry, cancellation: CancellationFlag()),
            policy: .standard
        )
        memory.stallsReads = true
        let flag = CancellationFlag()
        let pattern = try SearchPattern("nothing like this", options: SearchOptions(), encoding: .utf8)
        let outcome = ViewerAdoptBox<Result<Range<Int64>?, any Error>?>(nil)
        let worker = ViewerAdoptWorker {
            outcome.value = Result {
                try ViewerSearch.find(
                    ViewerSearch.Request(pattern: pattern, start: 0, backwards: false),
                    in: ViewerSearch.Subject(
                        source: source,
                        content: 0..<source.length,
                        encoding: .utf8,
                        boundaries: nil
                    ),
                    tuning: ViewerSearch.Tuning(
                        chunkSize: 50_000,
                        parallelism: 1,
                        rawBytes: true
                    ),
                    cancellation: flag
                ) { _ in
                    // Not watched here.
                }
            }
        }
        worker.start()
        #expect(worker.waitUntilWaiting())
        flag.cancel()
        #expect(worker.waitUntilFinished())
        // A cancelled search finds nothing; it does not fail.
        guard case .success(let found)? = outcome.value else {
            Issue.record("The search failed: \(String(describing: outcome.value))")
            return
        }
        #expect(found == nil && memory.interruptions >= 1)
    }

    /// A local copy of a file that never answers ends with its flag and keeps no part copy: the next copy is whole.
    @Test
    internal func aCopyOfAFileThatNeverAnswersEndsWithItsFlagAndLeavesNothingBehind() throws {
        let memory = MemoryFileSystem()
        let (registry, url) = stalledFile(memory, size: 200_000)
        memory.stallsReads = true
        let copies = TemporaryCopies()
        defer { copies.removeAll() }
        let flag = CancellationFlag()
        let outcome = ViewerAdoptBox<URL?>(URL(fileURLWithPath: "/unset"))
        let worker = ViewerAdoptWorker {
            outcome.value = copies.localURL(
                for: url,
                fileSystems: registry,
                owner: ObjectIdentifier(copies),
                cancellation: flag
            )
        }
        worker.start()
        #expect(worker.waitUntilWaiting())
        flag.cancel()
        #expect(worker.waitUntilFinished())
        #expect(outcome.value == nil && memory.interruptions >= 1)
        // Nothing was kept: copying again (the server answers now) makes a whole copy.
        memory.stallsReads = false
        let copy = try #require(
            copies.localURL(
                for: url,
                fileSystems: registry,
                owner: ObjectIdentifier(copies),
                cancellation: CancellationFlag()
            )
        )
        #expect(try Data(contentsOf: copy).count == 200_000 / 13 * 13)
    }

    /// A linked flag is set when any of its parents is, and a released one no longer follows its parent.
    @Test
    internal func aLinkedFlagFollowsItsParentsAndLetsGoWhenReleased() throws {
        let first = CancellationFlag()
        let second = CancellationFlag()
        var linked: LinkedCancellation? = LinkedCancellation(first, second)
        let flag = try #require(linked?.flag)
        #expect(!flag.isCancelled)
        second.cancel()
        #expect(flag.isCancelled && !first.isCancelled)
        let third = CancellationFlag()
        var released: LinkedCancellation? = LinkedCancellation(third)
        let kept = try #require(released?.flag)
        released = nil
        third.cancel()
        #expect(!kept.isCancelled)
        linked = nil
    }
}
