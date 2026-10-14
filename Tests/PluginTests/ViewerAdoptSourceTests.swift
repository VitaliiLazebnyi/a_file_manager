import AFMKernel
import Darwin
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// A function that runs on a thread of its own, for work that is meant to block: it says when
/// the thread waits (in a read that never answers), so a test sets the flag then and not "after a
/// moment".
final class ViewerAdoptWorker {
    private var port: mach_port_t = 0
    private let started = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var thread: Thread?

    init(_ body: @escaping () -> Void) {
        thread = Thread { [self] in
            port = mach_thread_self()
            started.signal()
            body()
            finished.signal()
        }
    }

    func start() {
        thread?.start()
        _ = started.wait(timeout: .now() + 30)
    }

    /// Whether the thread is waiting on something now (a condition, a lock).
    var isWaiting: Bool {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS && info.run_state == TH_STATE_WAITING
    }

    /// Polls until the thread waits; false after `timeout` seconds.
    func waitUntilWaiting(timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isWaiting, Date() < deadline { usleep(2_000) }
        return isWaiting
    }

    /// True when the body returned within `timeout` seconds.
    func waitUntilFinished(timeout: TimeInterval = 30) -> Bool {
        finished.wait(timeout: .now() + timeout) == .success
    }
}

/// Polls `condition` until it holds, for at most `seconds`.
func viewerAdoptWait(_ seconds: TimeInterval = 30, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline { usleep(2_000) }
    return condition()
}

/// A guarded value, for results that come from threads.
final class ViewerAdoptBox<Value> {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }

    func mutate(_ change: (inout Value) -> Void) {
        lock.lock()
        change(&stored)
        lock.unlock()
    }
}

/// A file that is "far away": every byte that is read from it is counted.
final class ViewerRemoteLike: ByteSource {
    let data: Data
    private let counter = ViewerAdoptBox((bytes: Int64(0), requests: 0))

    init(_ data: Data) { self.data = data }

    var length: Int64 { Int64(data.count) }
    var fetched: Int64 { counter.value.bytes }
    var requests: Int { counter.value.requests }

    func read(at offset: Int64, count: Int) -> Data {
        let lower = Int(max(0, min(offset, length)))
        let upper = min(data.count, lower + max(0, count))
        counter.mutate {
            $0.bytes += Int64(upper - lower)
            $0.requests += 1
        }
        return data.subdata(in: lower..<upper)
    }

    /// Text of lines of 10 to 150 characters, some with tabs and some with accents: the sort of
    /// file whose layout depends on the width of the window.
    static func text(megabytes: Int, seed: UInt64 = 1) -> Data {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        func next() -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(truncatingIfNeeded: state >> 11) & 0x7FFF_FFFF
        }
        let words = [
            "alpha", "beta", "gamma", "delta", "epsilon", "request", "handled", "user", "session", "0x7fff", "ä",
            "größe", "x"
        ]
        var bytes: [UInt8] = []
        bytes.reserveCapacity(megabytes << 20)
        while bytes.count < megabytes << 20 {
            let target = 10 + next() % 140
            var line = 0
            while line < target {
                let word = Array(words[next() % words.count].utf8)
                bytes.append(contentsOf: word)
                bytes.append(next() % 40 == 0 ? 0x09 : 0x20)
                line += word.count + 1
            }
            bytes.append(0x0A)
        }
        return Data(bytes)
    }
}

/// Reading remote files without reading them again, and ending reads that wait.
@Suite struct ViewerAdoptSource {
    // MARK: Disk cache

    @Test func blocksAreKeptOnDiskAndGivenBack() {
        let cache = DiskBlockCache(blockSize: 1_000, length: 4_500)
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
                && !cache.contains(0))
        #expect(cache.read(2) == first && cache.read(4) == tail && cache.read(0) == nil)
        #expect(cache.storedBytes == 1_500)
        cache.discard()
        #expect(!cache.isOpen && cache.storedBytes == 0 && cache.read(2) == nil)
        // It starts anew when it is used again.
        cache.store(2, first)
        #expect(cache.read(2) == first)
    }

    @Test func aCacheStopsAtItsLimit() {
        let cache = DiskBlockCache(blockSize: 1_000, length: 10_000, limit: 3_000)
        for block in 0..<10 { cache.store(Int64(block), Data(repeating: UInt8(block), count: 1_000)) }
        #expect(cache.storedBytes == 3_000)
        #expect((0..<10).filter { cache.contains(Int64($0)) } == [0, 1, 2])
        #expect(cache.read(1) == Data(repeating: 1, count: 1_000))
    }

    @Test func aBigFileOfASlowSourceIsNotFetchedAgainWhenItIsLaidOutAgain() throws {
        let data = ViewerRemoteLike.text(megabytes: 24)
        let remote = ViewerRemoteLike(data)
        let cached = CachedByteSource(
            remote, blockSize: 64 << 10, capacity: 16, wholeFileLimit: 1 << 20, spillsToDisk: true)
        defer { cached.close() }
        // Index it once: every byte comes from the "server".
        var previous = TextDocument(
            source: cached, encoding: .utf8, layout: .text(TextLayoutOptions(columns: 80, wordWrap: true)))
        previous.buildIndex(parallel: false)
        let fetchedOnce = remote.fetched
        #expect(previous.isIndexComplete && fetchedOnce >= remote.length && fetchedOnce <= remote.length + 2 * 64 << 10)
        #expect(cached.diskBytes >= remote.length && cached.diskCacheIsOpen)
        // Another width, another zoom, wrapping off: not one more byte, and the same rows as a
        // text in memory gets.
        for options in [
            TextLayoutOptions(columns: 120, wordWrap: true), TextLayoutOptions(columns: 40, wordWrap: true),
            TextLayoutOptions(columns: 200, wordWrap: false),
            TextLayoutOptions(columns: 80, wordWrap: true, tabWidth: 4)
        ] {
            let document = TextDocument(source: cached, encoding: .utf8, layout: .text(options), reusing: previous)
            document.buildIndex(parallel: false)
            let reference = TextDocument(source: DataByteSource(data), encoding: .utf8, layout: .text(options))
            reference.buildIndex(parallel: true)
            #expect(remote.fetched == fetchedOnce, "relayout \(options)")
            #expect(document.rowCount == reference.rowCount && document.lineCount == reference.lineCount)
            for first in [0, 1_000, reference.rowCount / 2, reference.rowCount - 3] {
                #expect(
                    try document.rows(from: first, count: 40).map(\.range)
                        == reference.rows(from: first, count: 40).map(\.range))
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

    @Test func aSearchOfAFileThatIsOnDiskAsksTheServerForNothing() throws {
        let data = ViewerRemoteLike.text(megabytes: 6)
        let remote = ViewerRemoteLike(data)
        let cached = CachedByteSource(
            remote, blockSize: 32 << 10, capacity: 8, wholeFileLimit: 1 << 20, spillsToDisk: true)
        defer { cached.close() }
        let needle = "zzz-not-there"
        let pattern = try SearchPattern(needle, options: SearchOptions(), encoding: .utf8)
        #expect(
            try ViewerSearch.find(
                pattern, in: cached, content: 0..<cached.length, from: 0, backwards: false, encoding: .utf8,
                chunkSize: 1 << 20) == nil)
        let first = remote.fetched
        #expect(first >= remote.length)
        #expect(
            try ViewerSearch.find(
                pattern, in: cached, content: 0..<cached.length, from: 0, backwards: false, encoding: .utf8,
                chunkSize: 1 << 20) == nil)
        #expect(
            try ViewerSearch.find(
                pattern, in: cached, content: 0..<cached.length, from: cached.length, backwards: true, encoding: .utf8,
                chunkSize: 300_000) == nil)
        #expect(remote.fetched == first)
    }

    @Test func aSourceWhoseDiskIsFullGoesOnWithoutIt() throws {
        let data = ViewerRemoteLike.text(megabytes: 2)
        let remote = ViewerRemoteLike(data)
        let cached = CachedByteSource(
            remote, blockSize: 16 << 10, capacity: 4, wholeFileLimit: 0, spillsToDisk: true, diskLimit: 100 << 10)
        defer { cached.close() }
        #expect(try cached.read(at: 0, count: data.count) == data)
        #expect(cached.diskBytes <= 100 << 10 && cached.diskBytes > 0)
        #expect(try cached.read(at: 500_000, count: 700_000) == data.subdata(in: 500_000..<1_200_000))
    }

    // MARK: Cancellation

    private func stalledFile(_ memory: MemoryFileSystem, size: Int) -> (FileSystemRegistry, URL) {
        let registry = FileSystemRegistry()
        registry.register(memory)
        let url = memory.addFile("/far/big.txt", String(repeating: "line of text\n", count: size / 13))
        return (registry, url)
    }

    @Test func aReadThatWaitsForTheServerEndsWhenItsFlagIsSet() throws {
        let memory = MemoryFileSystem()
        let (registry, url) = try stalledFile(memory, size: 100_000)
        let source = try ProviderByteSource.open(url, fileSystems: registry)
        memory.stallsReads = true
        for attempt in 1...5 {
            let flag = CancellationFlag()
            let outcome = ViewerAdoptBox<Result<Data, Error>?>(nil)
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

    @Test func aFlagOnlyEndsTheReadsItWasGiven() throws {
        let memory = MemoryFileSystem()
        let (registry, url) = try stalledFile(memory, size: 50_000)
        let source = CachedByteSource(
            try ProviderByteSource.open(url, fileSystems: registry), blockSize: 4_096, capacity: 4)
        let other = CancellationFlag()
        let mine = CancellationFlag()
        mine.cancel()
        #expect(throws: (any Error).self) { try source.read(at: 0, count: 100, cancellation: mine) }
        #expect(try source.read(at: 0, count: 100, cancellation: other).count == 100)
        // A reader that a cancelled read had out is not handed to the next one.
        #expect(try source.read(at: 20_000, count: 100).count == 100)
    }

    @Test func indexingAFileThatNeverAnswersStopsWhenTheDocumentIsDropped() throws {
        let memory = MemoryFileSystem()
        let (registry, url) = try stalledFile(memory, size: 400_000)
        let source = CachedByteSource(try ProviderByteSource.open(url, fileSystems: registry))
        memory.stallsReads = true
        let document = TextDocument(
            source: source, encoding: .utf8, layout: .text(TextLayoutOptions(columns: 80, wordWrap: true)))
        let worker = ViewerAdoptWorker { document.buildIndex(parallel: false) }
        worker.start()
        #expect(worker.waitUntilWaiting())
        document.cancellation.cancel()
        #expect(worker.waitUntilFinished())
        #expect(!document.isIndexComplete && document.readError == nil && memory.interruptions >= 1)
    }

    @Test func fetchingRowsFromAFileThatNeverAnswersEndsWhenTheFetchIsOvertaken() throws {
        let memory = MemoryFileSystem()
        let (registry, url) = try stalledFile(memory, size: 100_000)
        let source = try ProviderByteSource.open(url, fileSystems: registry)
        let document = TextDocument(
            source: source, encoding: .utf8, layout: .text(TextLayoutOptions(columns: 80, wordWrap: true)))
        document.buildIndex(parallel: false)
        // The readers the index used are not stalled; new ones are.
        source.close()
        memory.stallsReads = true
        let fetch = LinkedCancellation(document.cancellation)
        let outcome = ViewerAdoptBox<Result<[DisplayRow], Error>?>(nil)
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
        let second = ViewerAdoptBox<Result<Int?, Error>?>(nil)
        let again = ViewerAdoptWorker {
            second.value = Result { try document.row(containing: 90_000, cancellation: tied.flag) }
        }
        again.start()
        #expect(again.waitUntilWaiting())
        document.cancellation.cancel()
        #expect(again.waitUntilFinished() && tied.flag.isCancelled)
    }

    @Test func aSearchThroughAFileThatNeverAnswersEndsWithItsFlag() throws {
        let memory = MemoryFileSystem()
        let (registry, url) = try stalledFile(memory, size: 300_000)
        let source = CachedByteSource(try ProviderByteSource.open(url, fileSystems: registry))
        memory.stallsReads = true
        let flag = CancellationFlag()
        let pattern = try SearchPattern("nothing like this", options: SearchOptions(), encoding: .utf8)
        let outcome = ViewerAdoptBox<Result<Range<Int64>?, Error>?>(nil)
        let worker = ViewerAdoptWorker {
            outcome.value = Result {
                try ViewerSearch.find(
                    pattern, in: source, content: 0..<source.length, from: 0, backwards: false, encoding: .utf8,
                    chunkSize: 50_000,
                    parallelism: 1, cancellation: flag)
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

    @Test func aCopyOfAFileThatNeverAnswersEndsWithItsFlagAndLeavesNothingBehind() throws {
        let memory = MemoryFileSystem()
        let (registry, url) = try stalledFile(memory, size: 200_000)
        memory.stallsReads = true
        let copies = TemporaryCopies()
        defer { copies.removeAll() }
        let flag = CancellationFlag()
        let outcome = ViewerAdoptBox<URL?>(URL(fileURLWithPath: "/unset"))
        let worker = ViewerAdoptWorker {
            outcome.value = copies.localURL(
                for: url, fileSystems: registry, owner: ObjectIdentifier(copies), cancellation: flag)
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
                for: url, fileSystems: registry, owner: ObjectIdentifier(copies), cancellation: CancellationFlag()))
        #expect(try Data(contentsOf: copy).count == 200_000 / 13 * 13)
    }

    @Test func aLinkedFlagFollowsItsParentsAndLetsGoWhenReleased() {
        let first = CancellationFlag()
        let second = CancellationFlag()
        var linked: LinkedCancellation? = LinkedCancellation(first, second)
        let flag = linked!.flag
        #expect(!flag.isCancelled)
        second.cancel()
        #expect(flag.isCancelled && !first.isCancelled)
        let third = CancellationFlag()
        var released: LinkedCancellation? = LinkedCancellation(third)
        let kept = released!.flag
        released = nil
        third.cancel()
        #expect(!kept.isCancelled)
        linked = nil
    }
}
