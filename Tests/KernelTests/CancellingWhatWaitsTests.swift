import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// The in-memory file system stalls like a server that has stopped answering: what waits for
/// it must end when it is cancelled, and only then.
@Suite
internal struct CancellingWhatWaitsTests {
    private let memory = MemoryFileSystem()
    private let fileSystems = FileSystemRegistry()

    /// A folder `/far` with one file and a subfolder `sub` with another.
    internal init() {
        memory.addFile("/far/a.txt", "abcdef")
        memory.addFile("/far/sub/b.txt", "xyz")
        fileSystems.register(memory)
    }

    /// A loader stuck in a listing that does not answer ends, as cancelled, once its flag is set.
    @Test
    internal func aListingThatWaitsEndsWhenThePanelLoaderIsCancelled() {
        memory.stallsListings = true
        let flag = CancellationFlag()
        let ended = Signal<String>()
        OtherThread.start { [memory, fileSystems] in
            do {
                _ = try PanelLoader.load(
                    memory.url("/far"),
                    showHidden: false,
                    fileSystems: fileSystems,
                    cancellation: flag
                )
                ended.set("loaded")
            } catch let error as CocoaError where error.code == .userCancelled {
                ended.set("cancelled")
            } catch {
                ended.set("failed: \(error)")
            }
        }
        // The listing is under way and has nothing to say.
        #expect(Wait.until { memory.stalledListings(of: "/far") == 1 })
        #expect(memory.listRequests == ["/far"])
        flag.cancel()
        #expect(ended.wait() == "cancelled")
    }

    /// A stuck listing piece by piece ends quietly when cancelled, and nothing else is tried:
    /// no parent, no question about the item.
    @Test
    internal func aStreamThatWaitsEndsQuietlyWhenCancelled() {
        memory.stallsListings = true
        let streamed = Signal<Int>()
        let flag = CancellationFlag()
        OtherThread.start { [memory, fileSystems] in
            var batches = 0
            try? PanelLoader.stream(
                memory.url("/far/sub"),
                showHidden: false,
                fileSystems: fileSystems,
                climbing: true,
                cancellation: flag
            ) { _ in
                batches += 1
                return true
            }
            streamed.set(batches)
        }
        #expect(Wait.until { memory.stalledListings(of: "/far/sub") == 1 })
        flag.cancel()
        #expect(streamed.wait() == 0)
        #expect(memory.listRequests == ["/far/sub"])
    }

    /// Without a flag, and with one that is never set, loading is as it was.
    @Test
    internal func aFlagThatIsNeverSetChangesNothing() throws {
        let plain = try PanelLoader.load(memory.url("/far"), showHidden: false, fileSystems: fileSystems)
        #expect(plain.listing.items.count == 2)
        let atFile = try PanelLoader.load(
            memory.url("/far/a.txt"),
            showHidden: false,
            fileSystems: fileSystems,
            cancellation: CancellationFlag()
        )
        #expect(atFile.focus == "a.txt")
    }

    /// A listing that pauses between its batches stops at the next pause once the flag is set,
    /// and a later load with that flag is cancelled.
    @Test
    internal func aPausedListingStopsBetweenItsBatches() throws {
        for index in 0..<40 {
            memory.addFile("/many/f\(index).txt")
        }
        memory.listBatchSize = 10
        let flag = CancellationFlag()
        var received = 0
        try PanelLoader.stream(
            memory.url("/many"),
            showHidden: false,
            fileSystems: fileSystems,
            cancellation: flag
        ) { batch in
            received += batch.listing.items.count
            flag.cancel()
            return true
        }
        #expect(received == 10)
        #expect(throws: CocoaError.self) {
            try PanelLoader.load(memory.url("/many"), showHidden: false, fileSystems: fileSystems, cancellation: flag)
        }
    }

    /// Adding up sizes gives up with nothing when its flag is set during a listing that waits.
    @Test
    internal func addingUpSizesEndsWhenAListingWaits() {
        memory.stallsListings = true
        let flag = CancellationFlag()
        let size = Signal<Int64>()
        OtherThread.start { [memory] in size.set(memory.totalSize(of: memory.url("/far"), cancellation: flag)) }
        // Until the listing really waits: a condition, not a length of time.
        #expect(Wait.until { memory.stalledListings(of: "/far") == 1 })
        flag.cancel()
        #expect(size.wait() == 0)
        memory.releaseStalls()
        #expect(memory.totalSize(of: memory.url("/far"), cancellation: CancellationFlag()) == 9)
    }

    /// A transfer's flag interrupts both its ends while they wait for a server, and only then.
    @Test
    internal func aReadAndAWriteThatWaitAreInterruptedFromAnotherThread() throws {
        memory.stallsReads = true
        memory.stallsWrites = true
        let flag = CancellationFlag()
        let reader = try memory.read(memory.url("/far/a.txt"), cancellation: flag)
        let writer = try memory.write(memory.url("/far/new.txt"), cancellation: flag)
        let (read, written) = (Signal<String>(), Signal<String>())
        // What a transfer does: the flag interrupts both ends for as long as they are in use.
        let ties = [flag.interrupting(reader), flag.interrupting(writer)]
        OtherThread.start {
            do {
                read.set("read \(try reader.read(upToCount: 16)?.count ?? 0)")
            } catch {
                read.set("interrupted")
            }
        }
        OtherThread.start {
            do {
                try writer.write(Data("x".utf8))
                written.set("written")
            } catch {
                written.set("interrupted")
            }
        }
        // Both wait for the server: a condition, not a length of time.
        #expect(Wait.until { memory.stalledTransfers == 2 })
        #expect(memory.interruptions == 0)
        flag.cancel()
        #expect(read.wait() == "interrupted")
        #expect(written.wait() == "interrupted")
        #expect(memory.interruptions == 2)
        // Interrupted stays interrupted, and interrupting again is harmless.
        reader.interrupt()
        #expect(throws: MemoryFileSystem.Interrupted.self) { try reader.read(upToCount: 1) }
        reader.close()
        #expect(ties.count == 2)
        #expect(memory.interruptions == 2)
    }

    /// The tie between a flag and a reader does not keep the reader alive, and a released tie
    /// no longer interrupts.
    @Test
    internal func aTieNeitherKeepsAReaderNorOutlivesItsRelease() throws {
        let other = CancellationFlag()
        var next: (any FileReader)? = try memory.read(memory.url("/far/a.txt"))
        weak let gone = next
        var tie: AnyObject? = other.interrupting(try #require(next))
        next = nil
        #expect(gone == nil)
        let last = try memory.read(memory.url("/far/a.txt"))
        tie = other.interrupting(last)
        tie = nil
        other.cancel()
        #expect(try last.read(upToCount: 3) == Data("abc".utf8))
        #expect(tie == nil)
    }
}
