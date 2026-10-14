import Foundation
import Testing

@testable import AFMKernel

/// Counts its instances that are still alive.
private final class Tracked {
    static let lock = NSLock()
    /// Guarded by `lock`.
    nonisolated(unsafe) static var alive = 0
    init() {
        Self.lock.lock()
        Self.alive += 1
        Self.lock.unlock()
    }
    deinit {
        Self.lock.lock()
        Self.alive -= 1
        Self.lock.unlock()
    }
    static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return alive
    }
}

/// Unchecked: all state is guarded by `lock`.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var threads = Set<UInt64>()
    func add() {
        lock.lock()
        value += 1
        lock.unlock()
    }
    func note() {
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        lock.lock()
        threads.insert(id)
        value += 1
        lock.unlock()
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    var threadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return threads.count
    }
}

private func waitUntil(seconds: TimeInterval = 60, _ condition: () -> Bool) -> Bool {
    let end = Date(timeIntervalSinceNow: seconds)
    while !condition() {
        if Date() > end { return false }
        usleep(2_000)
    }
    return true
}

/// Review 2, K006, K008/K009/K028, K025-K027, K029, K044.
@Suite(.serialized) struct Review2KernelParallel {
    @Test func whatAPieceLeavesToBeReleasedLaterIsGoneWhenTheCallReturns() {
        // Objects handed to the autorelease pool of whatever thread runs the piece.
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

    @Test func aJobWhosePiecesStopDoesNotTakeTheThreadsOfTheNext() {
        let width = ParallelPool.shared.width
        guard width > 1 else { return }
        let release = DispatchSemaphore(value: 0)
        let stalled = Counter()
        let finished = DispatchSemaphore(value: 0)
        let pieces = width * 40
        Thread.detachNewThread {
            _ = Parallel.map(Array(0..<pieces)) { _ in
                stalled.note()
                release.wait()
            }
            finished.signal()
        }
        // Every thread the stalled job may have is in it.
        #expect(waitUntil { stalled.count >= width })
        // A later job still gets helpers: its pieces are not all run by its caller. Each piece
        // takes a moment, so the caller alone would need seconds for them.
        let later = Counter()
        _ = Parallel.map(Array(0..<64)) { _ in
            later.note()
            usleep(20_000)
        }
        #expect(later.count == 64)
        #expect(later.threadCount > 1)
        // The stalled job has what it had: as many threads as cores at most, its caller included.
        #expect(stalled.count <= width + 1)
        for _ in 0..<pieces { release.signal() }
        #expect(finished.wait(timeout: .now() + 60) == .success)
        #expect(stalled.count == pieces)
        // The threads beyond the cores go away again without waiting for all to be idle for long.
        #expect(waitUntil { ParallelPool.shared.census.threads <= width })
    }

    @Test func piecesThatWaitAndComeBackGetMoreThreadsThanCores() {
        let width = ParallelPool.shared.width
        guard width > 1 else { return }
        // Pieces that wait a moment each (as for an answer from a server). With no more
        // threads than cores, never more than `width + 1` of them are under way at once.
        let lock = NSLock()
        // Guarded by `lock`.
        nonisolated(unsafe) var (underWay, most) = (0, 0)
        _ = Parallel.map(Array(0..<(width * 40))) { _ in
            lock.lock()
            underWay += 1
            most = max(most, underWay)
            lock.unlock()
            usleep(30_000)
            lock.lock()
            underWay -= 1
            lock.unlock()
        }
        #expect(most > width + 1)
        #expect(most <= width * 4 + 1)
    }

    @Test func helpersStillComeAfterManyCallsWithIdleTimesBetween() {
        let pool = ParallelPool.shared
        guard pool.width > 1 else { return }
        // Threads that give up waiting just as they are called: with the wait made short,
        // that happens all the time. Calls must not be lost for it, now or later.
        pool.lingering = 0.002
        defer { pool.lingering = 2 }
        for round in 0..<600 {
            #expect(Parallel.map(Array(0..<40)) { $0 * 2 }.reduce(0, +) == 1_560)
            usleep(UInt32(round % 5) * 1_000)
        }
        pool.lingering = 2
        let later = Counter()
        _ = Parallel.map(Array(0..<64)) { _ in
            later.note()
            usleep(20_000)
        }
        #expect(later.threadCount > 1)
    }

    @Test func nestedWorkOfSeveralCallersAtOnceGivesTheRightSums() {
        // The same tree of calls from several threads, while others open and close jobs.
        @Sendable func tree(_ depth: Int) -> Int {
            depth == 0 ? 1 : Parallel.map(Array(0..<6)) { _ in tree(depth - 1) }.reduce(0, +)
        }
        let results = Counter()
        let done = DispatchSemaphore(value: 0)
        for _ in 0..<6 {
            Thread.detachNewThread {
                if tree(4) == 1_296 { results.add() }
                done.signal()
            }
        }
        for _ in 0..<6 { #expect(done.wait(timeout: .now() + 120) == .success) }
        #expect(results.count == 6)
    }

    @Test func workForABackgroundCallerIsNotMistakenForTheMainThreads() {
        let inside = Parallel.map(Array(0..<64)) { _ in Parallel.isHoldingUpMainThread }
        #expect(Thread.isMainThread ? inside.allSatisfy { $0 } : inside.allSatisfy { !$0 })
        #expect(!Parallel.isHoldingUpMainThread)
    }
}

@Suite(.serialized) @MainActor struct Review2KernelParallelOnMain {
    @Test func piecesOfACallOnTheMainThreadKnowThatItWaitsForThem() {
        guard Thread.isMainThread else { return }
        let inside = Parallel.map(Array(0..<256)) { _ -> Bool in
            // Nested calls belong to the same wait.
            Parallel.map([1, 2, 3]) { _ in Parallel.isHoldingUpMainThread }.allSatisfy { $0 }
                && Parallel.isHoldingUpMainThread
        }
        #expect(inside.allSatisfy { $0 })
        #expect(!Parallel.isHoldingUpMainThread)
    }
}

/// Review 2, K004/K007/K040: blocking questions on the kernel's own threads, bounded.
@Suite(.serialized) struct Review2KernelBlockingCalls {
    private final class Owner: Sendable {}

    @Test func theSameQuestionIsAskedOnceForAllWhoWait() {
        let owner = Owner()
        let asked = Counter()
        let release = DispatchSemaphore(value: 0)
        let answers = Counter()
        let done = DispatchSemaphore(value: 0)
        for _ in 0..<12 {
            Thread.detachNewThread {
                let answer = BlockingCalls.answer(from: owner, to: "volume /dead") { _ -> Int in
                    asked.add()
                    release.wait()
                    return 7
                }
                if answer == 7 { answers.add() }
                done.signal()
            }
        }
        #expect(waitUntil { asked.count == 1 })
        usleep(50_000)
        #expect(asked.count == 1 && BlockingCalls.unanswered(for: owner) == 1)
        release.signal()
        for _ in 0..<12 { #expect(done.wait(timeout: .now() + 60) == .success) }
        // Whoever came after the answer asked again; nobody asked while it was under way.
        for _ in 0..<12 { release.signal() }
        #expect(waitUntil { answers.count == 12 })
        #expect(waitUntil { BlockingCalls.unanswered(for: owner) == 0 })
    }

    @Test func aQuestionThatWasGivenUpIsNotAskedAgainUntilItComesBack() {
        let owner = Owner()
        let asked = Counter()
        let release = DispatchSemaphore(value: 0)
        // Guarded by `lock`.
        nonisolated(unsafe) var flags: [CancellationFlag] = []
        let lock = NSLock()
        // Fifty tries at a location that does not answer, each given up.
        for _ in 0..<50 {
            let cancellation = CancellationFlag()
            let returned = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                let answer = BlockingCalls.answer(from: owner, to: "volume /dead", cancellation: cancellation) {
                    flag -> Int in
                    lock.lock()
                    flags.append(flag)
                    lock.unlock()
                    asked.add()
                    release.wait()
                    return 1
                }
                if answer == nil { returned.signal() }
            }
            #expect(waitUntil { asked.count >= 1 })
            cancellation.cancel()
            // Giving up ends the wait at once, though the question itself goes on.
            #expect(returned.wait(timeout: .now() + 60) == .success)
        }
        #expect(asked.count == 1)
        #expect(BlockingCalls.unanswered(for: owner) == 1)
        lock.lock()
        let told = flags.first?.isCancelled
        lock.unlock()
        // The question was told that nobody waits.
        #expect(told == true)
        // Another question to the same owner, and the same one to another owner, are not held up.
        #expect(BlockingCalls.answer(from: owner, to: "volume /alive") { _ in 2 } == 2)
        #expect(BlockingCalls.answer(from: Owner(), to: "volume /dead") { _ in 3 } == 3)
        // Once it has come back, the question can be asked afresh.
        release.signal()
        #expect(waitUntil { BlockingCalls.unanswered(for: owner) == 0 })
        release.signal()
        #expect(
            BlockingCalls.answer(from: owner, to: "volume /dead") { _ -> Int in
                release.wait()
                return 4
            } == 4)
        #expect(asked.count == 1)
    }

    @Test func oneOwnerHasABoundedNumberOfQuestionsUnderWay() {
        let owner = Owner()
        let limit = BlockingCalls.limit
        let started = Counter()
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let total = limit + 10
        for index in 0..<total {
            Thread.detachNewThread {
                _ = BlockingCalls.answer(from: owner, to: "item \(index)") { _ -> Int in
                    started.add()
                    release.wait()
                    return index
                }
                done.signal()
            }
        }
        #expect(waitUntil { started.count == limit })
        usleep(50_000)
        #expect(started.count == limit && BlockingCalls.unanswered(for: owner) == limit)
        for _ in 0..<total { release.signal() }
        for _ in 0..<total { #expect(done.wait(timeout: .now() + 60) == .success) }
        #expect(started.count == total)
    }

    @Test func workRunsOffTheDispatchQueuesAndListsAreReleasedThere() {
        let name = DispatchSemaphore(value: 0)
        // Written by the other thread before it signals, read here after the wait.
        nonisolated(unsafe) var threadName: String?
        BlockingCalls.run {
            threadName = Thread.current.name
            name.signal()
        }
        #expect(name.wait(timeout: .now() + 60) == .success)
        #expect(threadName == "AFM.Blocking")
        // A long list of objects handed to `Discard` is freed without the caller doing it.
        let before = Tracked.count
        var list = (0..<(Discard.threshold + 5)).map { _ in Tracked() }
        #expect(Tracked.count == before + list.count)
        Discard.later(&list)
        #expect(list.isEmpty)
        #expect(waitUntil { Tracked.count == before })
    }
}
