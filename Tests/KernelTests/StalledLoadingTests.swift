import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Reading a panel's directory from a location that does not answer (review 2, K004, K007,
/// K039, K040).
@Suite(.serialized)
internal struct StalledLoadingTests {
    /// A file system whose questions about `/dead` do not come back until they are released:
    /// a share whose server is gone.
    ///
    /// Unchecked: the counts and flags are guarded by `lock`; the switches are set while no
    /// question is under way.
    private final class StalledFileSystem: MemoryBacked, @unchecked Sendable {
        let inner = MemoryFileSystem(scheme: "stall")
        let release = DispatchSemaphore(value: 0)
        /// Whether the volume of the dead folder blocks.
        var stallsVolume = true
        /// Whether the listing of the dead folder blocks.
        var stallsListing = false
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        private var flags: [CancellationFlag] = []
        private var givenUp = 0
        private var waiting = 0

        var capabilities: FileSystemCapabilities { [.write] }

        /// The flags the blocked questions were given, in order.
        var handedFlags: [CancellationFlag] { lock.withLock { flags } }

        /// How many blocked questions were never released and gave up after the longest wait: a hang.
        var waitsGivenUp: Int { lock.withLock { givenUp } }

        /// How many blocked questions are waiting right now.
        var stuck: Int { lock.withLock { waiting } }

        /// How many questions of a kind (`volume`, `list`) blocked.
        func count(_ what: String) -> Int { lock.withLock { counts[what] ?? 0 } }

        func volume(of _: URL) -> VolumeInfo? { VolumeInfo(name: "plain") }

        func volume(of url: URL, cancellation: CancellationFlag) -> VolumeInfo? {
            guard isDead(url), stallsVolume else {
                return VolumeInfo(name: "alive")
            }
            block("volume", cancellation)
            return VolumeInfo(name: "back")
        }

        func list(
            _ directory: URL,
            showHidden: Bool,
            cancellation: CancellationFlag,
            receive: ([FileItem]) -> Bool
        ) throws {
            if isDead(directory), stallsListing {
                block("list", cancellation)
            }
            _ = receive(try inner.list(directory, showHidden: showHidden))
        }

        /// Notes the question and waits until the test releases it.
        private func block(_ what: String, _ flag: CancellationFlag) {
            lock.withLock {
                counts[what, default: 0] += 1
                waiting += 1
                flags.append(flag)
            }
            if release.wait(timeout: .now() + Wait.ceiling) == .timedOut {
                lock.withLock { givenUp += 1 }
            }
            lock.withLock { waiting -= 1 }
        }

        private func isDead(_ url: URL) -> Bool { url.path.hasPrefix("/dead") }

        deinit {
            // Nothing to release.
        }
    }

    /// The stalled file system, registered, with `/dead/a.txt`, `/alive/b.txt` and `/alive/c.txt`.
    private let stalled = StalledFileSystem()
    private let registry = FileSystemRegistry()

    /// Fills the stalled file system and registers it.
    internal init() {
        stalled.inner.addFile("/dead/a.txt")
        stalled.inner.addFile("/alive/b.txt")
        stalled.inner.addFile("/alive/c.txt")
        registry.register(stalled)
    }

    /// The system's number for the calling thread.
    private static func threadID() -> UInt64 {
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        return id
    }

    /// A hundred refreshes of a folder whose volume does not answer ask once, each is free at
    /// once when given up, a healthy folder still loads, and all is well once the share is back.
    @Test
    internal func aVolumeThatDoesNotAnswerCostsOneThreadHoweverOftenItIsTried() {
        for _ in 0..<100 {
            let cancellation = CancellationFlag()
            let ended = load("/dead", cancellation: cancellation)
            #expect(Wait.until { stalled.count("volume") >= 1 })
            cancellation.cancel()
            // The reader is free at once; it does not wait for the file system.
            #expect(ended.wait() != nil)
        }
        #expect(stalled.count("volume") == 1)
        #expect(stalled.stuck == 1)
        // The question was told that nobody waits for it.
        #expect(stalled.handedFlags.first?.isCancelled == true)
        // A healthy folder of the same file system still loads.
        #expect(load("/alive", cancellation: CancellationFlag()).wait()?.sorted() == ["b.txt", "c.txt"])
        // The share comes back: the stuck question ends, and the folder can be read.
        for _ in 0..<4 {
            stalled.release.signal()
        }
        #expect(Wait.until { stalled.stuck == 0 })
        stalled.stallsVolume = false
        let result = try? PanelLoader.load(stalled.inner.url("/dead"), showHidden: true, fileSystems: registry)
        #expect(result?.listing.items.map(\.name) == ["a.txt"] && result?.listing.volume?.name == "alive")
        #expect(stalled.waitsGivenUp == 0)
    }

    /// Forty tries at a listing that does not answer start it once; whoever still wants the
    /// folder waits, without a thread of the kernel's, and reads it afresh when the old one is back.
    @Test
    internal func aListingThatDoesNotAnswerIsNotStartedASecondTime() {
        (stalled.stallsVolume, stalled.stallsListing) = (false, true)
        for round in 0..<40 {
            let cancellation = CancellationFlag()
            let ended = load("/dead", cancellation: cancellation)
            if round == 0 {
                #expect(Wait.until { stalled.count("list") == 1 })
            }
            cancellation.cancel()
            #expect(ended.wait() != nil)
        }
        #expect(stalled.count("list") == 1 && stalled.stuck == 1)
        let reading = load("/dead", cancellation: CancellationFlag())
        // Nothing more is asked meanwhile: an absence, which no condition can show, so it is
        // looked for after a moment.
        usleep(50_000)
        #expect(stalled.count("list") == 1)
        stalled.stallsListing = false
        stalled.release.signal()
        #expect(reading.wait() == ["a.txt"])
        #expect(Wait.until { stalled.stuck == 0 })
        #expect(stalled.waitsGivenUp == 0)
    }

    /// Batches arrive on the thread that asked, the first marked as first; wanting no more ends
    /// the reading, a missing folder throws there (or climbs), and a file leads to its folder.
    @Test
    internal func batchesArriveOnTheThreadThatAskedAndErrorsAreThrownThere() throws {
        let memory = MemoryFileSystem(scheme: "mem")
        for index in 0..<50 {
            memory.addFile("/big/file\(index).txt")
        }
        memory.listBatchSize = 7
        let memoryRegistry = FileSystemRegistry()
        memoryRegistry.register(memory)
        let own = Self.threadID()
        var (batches, firsts, names, elsewhere) = (0, 0, [String](), 0)
        try PanelLoader.stream(memory.url("/big"), showHidden: true, fileSystems: memoryRegistry) { batch in
            elsewhere += Self.threadID() == own ? 0 : 1
            batches += 1
            firsts += batch.isFirst ? 1 : 0
            names += batch.listing.items.map(\.name)
            return true
        }
        #expect(batches > 1 && firsts == 1 && names.count == 50 && elsewhere == 0)
        var taken = 0
        try PanelLoader.stream(memory.url("/big"), showHidden: true, fileSystems: memoryRegistry) { _ in
            taken += 1
            return false
        }
        #expect(taken == 1)
        #expect(throws: (any Error).self) {
            try PanelLoader.load(memory.url("/big/none"), showHidden: true, fileSystems: memoryRegistry)
        }
        let climbed = try PanelLoader.load(
            memory.url("/big/none"),
            showHidden: true,
            fileSystems: memoryRegistry,
            climbing: true
        )
        #expect(climbed.listing.items.count == 50)
        let atFile = try PanelLoader.load(memory.url("/big/file3.txt"), showHidden: true, fileSystems: memoryRegistry)
        #expect(atFile.focus == "file3.txt" && atFile.listing.items.count == 50)
    }

    /// One try at reading `path` of the stalled file system, on a thread of its own; the
    /// signal is set with the names it got when it returns.
    private func load(_ path: String, cancellation: CancellationFlag) -> Signal<[String]> {
        let ended = Signal<[String]>()
        let (location, fileSystems) = (stalled.inner.url(path), registry)
        OtherThread.start {
            var seen: [String] = []
            try? PanelLoader.stream(
                location,
                showHidden: true,
                fileSystems: fileSystems,
                cancellation: cancellation
            ) { batch in
                seen += batch.listing.items.map(\.name)
                return true
            }
            ended.set(seen)
        }
        return ended
    }
}
