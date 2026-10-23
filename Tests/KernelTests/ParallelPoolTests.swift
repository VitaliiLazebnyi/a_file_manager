import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// The kernel's pool of threads for parallel work (review 2, K006, K008, K009, K025-K029, K044).
@Suite(.serialized)
internal struct ParallelPoolTests {
    /// The threads of the pool there are now, found by their name.
    private static func poolThreads() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else {
            return 0
        }
        defer {
            let size = vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), size)
        }
        var found = 0
        for index in 0..<Int(count) {
            defer { mach_port_deallocate(mach_task_self_, list[index]) }
            guard let thread = pthread_from_mach_thread_np(list[index]) else {
                continue
            }
            var name = [CChar](repeating: 0, count: 64)
            pthread_getname_np(thread, &name, name.count)
            let bytes = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            if String(bytes: bytes, encoding: .utf8) == "AFM.Parallel" {
                found += 1
            }
        }
        return found
    }

    /// Waits for `release` to be signalled by the test, at most as long as any wait lasts.
    private static func hold(_ release: DispatchSemaphore) {
        _ = release.wait(timeout: .now() + Wait.ceiling)
    }

    /// Objects a piece hands to the autorelease pool of its thread are released when the call
    /// returns, for jobs of many small and of few large pieces.
    @Test
    internal func whatAPieceLeavesToBeReleasedLaterIsGoneWhenTheCallReturns() {
        let before = Tracked.count
        let sums = Parallel.map(Array(0..<4_000)) { index -> Int in
            _ = Unmanaged.passRetained(Tracked()).autorelease()
            return index
        }
        #expect(sums.count == 4_000)
        // The pool's threads live on; their pieces' pools must have been drained all the same.
        #expect(Tracked.count == before)
        // A job of few, large pieces (one index each) too.
        _ = Parallel.map(Array(0..<8)) { _ in _ = Unmanaged.passRetained(Tracked()).autorelease() }
        #expect(Tracked.count == before)
    }

    /// A job whose pieces all wait holds at most as many threads as cores; a later job still
    /// gets helpers, and the extra threads go away again afterwards.
    @Test
    internal func aJobWhosePiecesStopDoesNotTakeTheThreadsOfTheNext() {
        let width = ParallelPool.shared.width
        guard width > 1 else {
            return
        }
        let release = DispatchSemaphore(value: 0)
        let stalled = Counter()
        let finished = Counter()
        let pieces = width * 40
        OtherThread.start {
            _ = Parallel.map(Array(0..<pieces)) { _ in
                stalled.note()
                Self.hold(release)
            }
            finished.add()
        }
        // Every thread the stalled job may have is in it.
        #expect(Wait.until { stalled.count >= width })
        // A later job still gets helpers: its pieces are not all run by its caller. Each piece
        // takes a moment (the sleep is the work), so the caller alone would need seconds for them.
        let later = Counter()
        _ = Parallel.map(Array(0..<64)) { _ in
            later.note()
            usleep(20_000)
        }
        #expect(later.count == 64)
        #expect(later.threadCount > 1)
        // The stalled job has what it had: as many threads as cores at most, its caller included.
        #expect(stalled.count <= width + 1)
        for _ in 0..<pieces {
            release.signal()
        }
        #expect(Wait.until { finished.count == 1 })
        #expect(stalled.count == pieces)
        // The threads beyond the cores go away again without waiting for all to be idle for long.
        #expect(Wait.until { Self.poolThreads() <= width })
    }

    /// Pieces that wait a moment each, as for a server, get more threads than cores, up to a limit.
    @Test
    internal func piecesThatWaitAndComeBackGetMoreThreadsThanCores() {
        let width = ParallelPool.shared.width
        guard width > 1 else {
            return
        }
        // With no more threads than cores, never more than `width + 1` would be under way at once.
        let figures = Shared((underWay: 0, most: 0))
        _ = Parallel.map(Array(0..<(width * 40))) { _ in
            figures.modify { now in
                now.underWay += 1
                now.most = max(now.most, now.underWay)
            }
            // The wait for the answer, which is what the pool has to notice.
            usleep(30_000)
            figures.modify { $0.underWay -= 1 }
        }
        #expect(figures.value.most > width + 1)
        #expect(figures.value.most <= width * 4 + 1)
    }

    /// Threads that give up waiting just as they are called lose no call, now or later.
    @Test
    internal func helpersStillComeAfterManyCallsWithIdleTimesBetween() {
        // With the wait made short, threads give up just as they are called all the time.
        let pool = ParallelPool(linger: 0.002)
        guard pool.width > 1 else {
            return
        }
        for round in 0..<600 {
            let sum = Counter()
            pool.run(count: 40) { _ in sum.add() }
            #expect(sum.count == 40)
            // Idle times of different lengths between the calls: what lets the threads give up.
            usleep(UInt32(round % 5) * 1_000)
        }
        let later = Counter()
        pool.run(count: 64) { _ in
            later.note()
            // Each piece takes a moment, so that helpers are worth calling.
            usleep(20_000)
        }
        #expect(later.threadCount > 1)
    }

    /// The same tree of nested calls from six threads at once gives the right sum on each.
    @Test
    internal func nestedWorkOfSeveralCallersAtOnceGivesTheRightSums() {
        @Sendable
        func tree(_ depth: Int) -> Int {
            depth == 0 ? 1 : Parallel.map(Array(0..<6)) { _ in tree(depth - 1) }.reduce(0, +)
        }
        let results = Counter()
        let done = Counter()
        for _ in 0..<6 {
            OtherThread.start {
                if tree(4) == 1_296 {
                    results.add()
                }
                done.add()
            }
        }
        #expect(Wait.until { done.count == 6 })
        #expect(results.count == 6)
    }

    /// Pieces of a call made off the main thread do not count as holding up the main thread.
    @Test
    internal func workForABackgroundCallerIsNotMistakenForTheMainThreads() {
        let inside = Parallel.map(Array(0..<64)) { _ in Parallel.isHoldingUpMainThread }
        let onMain = Thread.isMainThread
        #expect(inside.allSatisfy { $0 == onMain })
        #expect(!Parallel.isHoldingUpMainThread)
    }
}
