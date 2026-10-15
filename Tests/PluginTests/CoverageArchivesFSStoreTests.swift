import AFMKernel
import Darwin
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The store of open archives: threads that ask for one archive at once, archives that
/// cannot be opened, and openings that are cancelled or run out of room.
@Suite
internal struct CoverageArchivesFSStoreTests {
    /// What a thread hands back from the work it was given.
    private typealias Outcome = Result<OpenArchive, any Error>

    private let bench: ArchiveBench
    private let hooked = CoverageArchivesFSHookedMemory()
    private let zipBytes: Data

    private var box: Sandbox { bench.box }
    private var store: ArchiveStore { bench.store }
    private var memory: MemoryFileSystem { bench.memory }

    /// The archive file systems over the disk, a memory file system and a hooked one, and the
    /// bytes of a small ZIP.
    internal init() throws {
        bench = try ArchiveBench()
        bench.fileSystems.register(hooked)
        try bench.box.file("tree/readme.txt", "read me")
        #expect(runTool("/usr/bin/zip", ["-qr", "tree.zip", "tree"], in: bench.box.root).status == 0)
        zipBytes = try Data(contentsOf: bench.box.url("tree.zip"))
    }

    private static func isCancelled(_ error: any Error) -> Bool {
        guard case ArchiveError.cancelled = error else {
            return false
        }
        return true
    }

    /// Whether the thread is waiting (for a lock, here), as the kernel says.
    private static func isWaiting(_ thread: thread_act_t) -> Bool {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), words, &count)
            }
        }
        return result == KERN_SUCCESS && info.run_state == TH_STATE_WAITING
    }

    /// Runs `work` on a thread of its own and returns once the thread waits in it (for the
    /// lock of an archive that another thread opens), and a signal for its outcome.
    private static func waitingThread(_ work: @escaping @Sendable () -> Outcome) -> Signal<Outcome> {
        let port = Signal<thread_act_t>()
        let outcome = Signal<Outcome>()
        Thread.detachNewThread {
            port.set(mach_thread_self())
            outcome.set(work())
        }
        guard let thread = port.wait() else {
            return outcome
        }
        // Waiting, and still waiting when asked again: in the lock, not on the way to it.
        #expect(Wait.until { isWaiting(thread) && isWaiting(thread) && isWaiting(thread) })
        mach_port_deallocate(mach_task_self_, thread)
        return outcome
    }

    /// Opens `url` in the store on a thread of its own.
    private func opening(_ url: URL, cancellation: CancellationFlag?) -> Signal<Outcome> {
        let (shared, outcome) = (store, Signal<Outcome>())
        Thread.detachNewThread {
            outcome.set(Result { try shared.archive(at: url, cancellation: cancellation) })
        }
        return outcome
    }

    // MARK: Threads that ask at once

    /// Two threads that ask for one archive on a server at once open it once: the second
    /// waits for the first and gets its archive.
    @Test
    internal func twoThreadsThatAskAtOnceOpenTheArchiveOnce() throws {
        let url = try CoverageArchivesFSHookedMemory.put(zipBytes, at: "/store/tree.zip", on: memory)
        memory.stallsReads = true
        let first = opening(url, cancellation: nil)
        #expect(Wait.until { memory.stalledTransfers == 1 })
        let shared = store
        let second = Self.waitingThread { Result { try shared.archive(at: url) } }
        memory.releaseStalls()
        let one = try #require(try first.wait()?.get())
        let other = try #require(try second.wait()?.get())
        #expect(one === other)
    }

    /// A thread that waits for another's opening gives up when its own cancellation is set.
    @Test
    internal func aThreadThatWaitsForAnOpeningCanBeCancelled() throws {
        let url = try CoverageArchivesFSHookedMemory.put(zipBytes, at: "/store/tree.zip", on: memory)
        memory.stallsReads = true
        let first = opening(url, cancellation: nil)
        #expect(Wait.until { memory.stalledTransfers == 1 })
        let (shared, flag) = (store, CancellationFlag())
        let second = Self.waitingThread { Result { try shared.archive(at: url, cancellation: flag) } }
        flag.cancel()
        #expect(throws: ArchiveError.self) { _ = try second.wait()?.get() }
        memory.releaseStalls()
        #expect(try first.wait()?.get() != nil)
    }

    /// When the opening that a thread waits for is cancelled, the slot goes, and the waiting
    /// thread opens the archive in a slot of its own.
    @Test
    internal func aCancelledOpeningLeavesTheArchiveToTheNextThread() throws {
        let url = try CoverageArchivesFSHookedMemory.put(zipBytes, at: "/store/tree.zip", on: memory)
        memory.stallsReads = true
        let flag = CancellationFlag()
        let first = opening(url, cancellation: flag)
        #expect(Wait.until { memory.stalledTransfers == 1 })
        let shared = store
        let second = Self.waitingThread { Result { try shared.archive(at: url) } }
        memory.stallsReads = false
        flag.cancel()
        #expect(throws: ArchiveError.self) { _ = try first.wait()?.get() }
        let archive = try #require(try second.wait()?.get())
        #expect(store.openArchive(at: url) === archive && archive.entry("tree/readme.txt") != nil)
    }

    // MARK: Archives that cannot be opened

    /// That a file on a server is no archive is remembered for a moment: asked again at
    /// once, the store does not fetch it again.
    @Test
    internal func aFileOnAServerThatIsNoArchiveIsNotFetchedAgainAtOnce() throws {
        let junk = Data("no archive at all".utf8)
        let url = try CoverageArchivesFSHookedMemory.put(junk, at: "/store/junk.zip", on: hooked.base)
        #expect(throws: ArchiveError.self) { _ = try store.archive(at: url) }
        #expect(throws: ArchiveError.self) { _ = try store.archive(at: url) }
        #expect(hooked.opened == 1)
    }

    /// A local file that was no archive is read again once it changed.
    @Test
    internal func aLocalFileThatBecameAnArchiveIsReadAgain() throws {
        let url = try box.file("late.zip", "not yet an archive")
        #expect(throws: ArchiveError.self) { _ = try store.archive(at: url) }
        try FileManager.default.removeItem(at: url)
        try zipBytes.write(to: url)
        #expect(try store.archive(at: url).entry("tree/readme.txt") != nil)
    }

    /// An opening that is cancelled while the archive is fetched from a server ends with
    /// `cancelled`, and keeps nothing: asked again, the archive opens.
    @Test
    internal func anOpeningCancelledWhileFetchingKeepsNothing() throws {
        let url = try CoverageArchivesFSHookedMemory.put(zipBytes, at: "/store/tree.zip", on: hooked.base)
        let flag = CancellationFlag()
        hooked.onNextRead { flag.cancel() }
        let error = #expect(throws: ArchiveError.self) { _ = try store.archive(at: url, cancellation: flag) }
        #expect(error.map(Self.isCancelled) == true)
        #expect(try store.archive(at: url).entry("tree/readme.txt") != nil)
    }

    /// A folder on a server is no archive; a look at the file that is given up says
    /// `cancelled` instead.
    @Test
    internal func aFolderOnAServerIsNoArchive() throws {
        let folder = hooked.base.addDirectory("/store/folder.zip")
        #expect(throws: ArchiveError.self) { _ = try store.archive(at: folder) }
        let url = try CoverageArchivesFSHookedMemory.put(zipBytes, at: "/store/tree.zip", on: hooked.base)
        let (flag, base) = (CancellationFlag(), hooked.base)
        // The look is given up, and finds nothing.
        hooked.onNextItem {
            flag.cancel()
            try? base.remove(url)
        }
        let error = #expect(throws: ArchiveError.self) { _ = try store.archive(at: url, cancellation: flag) }
        #expect(error.map(Self.isCancelled) == true)
    }

    /// An archive on a server whose name has no ending opens all the same.
    @Test
    internal func anArchiveWithoutAnEndingOpens() throws {
        let url = try CoverageArchivesFSHookedMemory.put(zipBytes, at: "/store/blob", on: memory)
        #expect(try store.archive(at: url).entry("tree/readme.txt") != nil)
    }

    /// A copy from a server that outgrows the room on the disk is given up.
    @Test
    internal func aFetchThatOutgrowsTheRoomIsGivenUp() throws {
        let url = try CoverageArchivesFSHookedMemory.put(Data(count: 33 << 20), at: "/store/big.zip", on: memory)
        let asked = Shared(0)
        bench.environment.hasRoom = { _, _ in
            asked.modify { $0 += 1 }
            return asked.value == 1
        }
        let error = #expect(throws: ArchiveError.self) { _ = try store.archive(at: url) }
        #expect(error?.errorDescription == ArchiveError.noScratchRoom("big.zip").errorDescription)
        #expect(asked.value == 2)
    }

    /// An archive on a server that was changed there stays the archive when a change began
    /// in it while the server was asked: what was begun is not lost to a fresh reading.
    @Test
    internal func anArchiveInWhichAChangeBeganIsNotLetGo() throws {
        let url = try CoverageArchivesFSHookedMemory.put(zipBytes, at: "/store/tree.zip", on: hooked.base)
        let first = try store.archive(at: url)
        let (base, bytes) = (hooked.base, zipBytes)
        let writer = Shared<(any FileWriter)?>(nil)
        hooked.onNextItem {
            _ = try? CoverageArchivesFSHookedMemory.put(bytes + Data("changed".utf8), at: "/store/tree.zip", on: base)
            writer.value = try? first.write("begun.txt")
        }
        #expect(try store.archive(at: url) === first)
        #expect(writer.value != nil && first.isBusy)
        try writer.value?.close(attributes: FileAttributes())
    }
}
