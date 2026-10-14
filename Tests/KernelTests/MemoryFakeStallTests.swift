import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// The stalls of the memory file system the other areas test with: held calls end when their
/// flag is set or when they are let go, and the fake says when one waits.
@Suite
internal struct MemoryFakeStallTests {
    /// A held removal ends cancelled, having changed nothing, when its flag is set; a held move
    /// goes on and does its work when the stalls are let go; both are recorded as flagged.
    @Test
    internal func theFakeHoldsChangesThatCameWithAFlagUntilItIsSetOrTheyAreLetGo() {
        let memory = MemoryFileSystem()
        memory.addFile("/a.txt", "a")
        memory.addFile("/b.txt", "b")
        memory.stallsChanges = true
        let flag = CancellationFlag()
        let failure = Signal<String>()
        OtherThread.start {
            do {
                try memory.remove(memory.url("/a.txt"), cancellation: flag)
                failure.set("removed")
            } catch let error as CocoaError where error.code == .userCancelled {
                failure.set("cancelled")
            } catch {
                failure.set("failed: \(error)")
            }
        }
        // Until the call really waits: a condition, not a length of time.
        #expect(Wait.until { memory.stalledChanges == 1 })
        #expect(memory.exists("/a.txt"))
        flag.cancel()
        #expect(failure.wait() == "cancelled")
        #expect(memory.exists("/a.txt"))
        #expect(memory.stalledChanges == 0)
        // Let go, a held call goes on and does its work.
        let other = CancellationFlag()
        let moved = Signal<Bool>()
        OtherThread.start {
            try? memory.move(memory.url("/b.txt"), to: memory.url("/c.txt"), replacing: false, cancellation: other)
            moved.set(true)
        }
        #expect(Wait.until { memory.stalledChanges == 1 })
        memory.releaseStalls()
        #expect(moved.wait() == true)
        #expect(memory.exists("/c.txt"))
        #expect(!memory.exists("/b.txt"))
        #expect(memory.flaggedChanges == ["remove /a.txt", "move /b.txt"])
    }

    /// With stalled paths set, a listing of another path answers at once; one of a stalled path
    /// waits, is counted as waiting for that path only, and answers once let go.
    @Test
    internal func theFakeStallsOnlyTheListingsItIsToldToAndSaysWhenOneWaits() throws {
        let memory = MemoryFileSystem()
        memory.addFile("/dead/a.txt")
        memory.addFile("/alive/b.txt")
        memory.stallsListings = true
        memory.stalledPaths = ["/dead"]
        let alive = try memory.list(memory.url("/alive"), showHidden: true, cancellation: CancellationFlag())
        #expect(alive.map(\.name) == ["b.txt"])
        let flag = CancellationFlag()
        let names = Signal<[String]>()
        OtherThread.start {
            names.set((try? memory.list(memory.url("/dead"), showHidden: true, cancellation: flag).map(\.name)) ?? [])
        }
        #expect(Wait.until { memory.stalledListings(of: "/dead") == 1 })
        #expect(memory.stalledListings(of: "/alive") == 0)
        memory.releaseStalls()
        #expect(names.wait() == ["a.txt"])
        #expect(memory.stalledListings(of: "/dead") == 0)
    }
}
