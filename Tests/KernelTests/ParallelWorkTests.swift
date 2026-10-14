import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Work spread over the cores: nested maps give the plain results, inner work gets threads of
/// its own, waiting work does not take every thread, and many callers at once all finish.
@Suite
internal struct ParallelWorkTests {
    /// The most pieces of a job of `pieces` that ran at the same time; each piece stays until a
    /// second one runs beside it, however long a thread takes to come (on one core, not at all).
    private static func mostAtOnce(pieces: Int, cores: Int) -> Int {
        let lock = NSLock()
        // Guarded by `lock`.
        nonisolated(unsafe) var (running, most) = (0, 0)
        _ = Parallel.map(Array(0..<pieces)) { _ in
            lock.withLock {
                running += 1
                most = max(most, running)
            }
            _ = Wait.until(seconds: 60) { cores == 1 || lock.withLock { most > 1 } }
            lock.withLock { running -= 1 }
        }
        return lock.withLock { most }
    }

    /// Checks that a tree of calls three levels deep, with uneven branches, sums up as plain loops do.
    @Test
    internal func nestedMapsGiveWhatPlainLoopsGive() {
        @Sendable
        func walk(_ depth: Int, _ seed: Int) -> Int {
            guard depth > 0 else {
                return seed
            }
            return Parallel.map(Array(0..<(2 + seed % 5))) { walk(depth - 1, seed * 7 + $0) }.reduce(seed, &+)
        }
        func plain(_ depth: Int, _ seed: Int) -> Int {
            guard depth > 0 else {
                return seed
            }
            return (0..<(2 + seed % 5)).map { plain(depth - 1, seed * 7 + $0) }.reduce(seed, &+)
        }
        #expect(Parallel.map(Array(0..<40)) { walk(4, $0) } == (0..<40).map { plain(4, $0) })
    }

    /// As many outer pieces as cores used to leave the inner calls with one thread each.
    ///
    /// Here one outer piece holds nearly all the work: its inner pieces must run at once, and no more of them than the
    /// limit for a job.
    @Test
    internal func workBelowTheTopLevelIsSpreadOverTheCores() {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        guard cores >= 4 else {
            return
        }
        let lock = NSLock()
        // Guarded by `lock`.
        nonisolated(unsafe) var (running, most) = (0, 0)
        _ = Parallel.map(Array(0..<cores)) { outer -> Int in
            guard outer == 0 else {
                return 0
            }
            return
                Parallel.map(Array(0..<(cores * 2))) { _ -> Int in
                    lock.withLock {
                        running += 1
                        most = max(most, running)
                    }
                    // A piece stays until a second one runs beside it (a condition, not a length
                    // of time: on a busy machine a helper thread may be long in coming); if none
                    // ever does, the check below fails.
                    _ = Wait.until(seconds: 60) { lock.withLock { most > 1 } }
                    // Work that takes a moment, so that the pieces that run at once are seen
                    // running at once.
                    Thread.sleep(forTimeInterval: 0.01)
                    lock.withLock { running -= 1 }
                    return 1
                }
                .reduce(0, +)
        }
        let seen = lock.withLock { most }
        #expect(seen > 1)
        // Sleeping pieces count as waiting, which earns a job more threads, up to a limit.
        #expect(seen <= cores * 4)
    }

    /// Pieces that wait, like pieces that wait for a server, take up every helper thread; a job
    /// that comes then still gets a second thread.
    @Test
    internal func aJobIsNotLeftAloneWhileEveryThreadWaits() {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let gate = NSCondition()
        // Guarded by `gate`.
        nonisolated(unsafe) var (isOpen, waiting) = (false, 0)
        let sleepers = DispatchGroup()
        sleepers.enter()
        OtherThread.start {
            _ = Parallel.map(Array(0..<(cores * 2))) { _ in
                gate.lock()
                waiting += 1
                gate.broadcast()
                // Let go by the test; never held for longer than a hang would be.
                let end = Date().addingTimeInterval(Wait.ceiling)
                while !isOpen, gate.wait(until: end) {
                    // Woken: look again.
                }
                gate.unlock()
            }
            sleepers.leave()
        }
        // Until the waiting job holds threads: a condition, not a length of time.
        gate.lock()
        let end = Date().addingTimeInterval(Wait.ceiling)
        while waiting < min(2, cores), gate.wait(until: end) {
            // Woken: look again.
        }
        let isHeld = waiting >= min(2, cores)
        gate.unlock()
        #expect(isHeld)
        #expect(Self.mostAtOnce(pieces: 8, cores: cores) > 1 || cores == 1)
        gate.lock()
        isOpen = true
        gate.broadcast()
        gate.unlock()
        #expect(sleepers.wait(timeout: .now() + Wait.ceiling) == .success)
    }

    /// Checks that two dozen callers on threads of their own, each with nested maps, all
    /// finish with the right sums.
    @Test
    internal func manyCallersAtOnceAllFinish() {
        let sums = Shared([Int](repeating: 0, count: 24))
        DispatchQueue.global()
            .sync {
                DispatchQueue.concurrentPerform(iterations: 24) { caller in
                    let sum =
                        Parallel.map(Array(0..<200)) { index in
                            Parallel.map([index, caller]) { $0 * 2 }.reduce(0, +)
                        }
                        .reduce(0, +)
                    sums.modify { $0[caller] = sum }
                }
            }
        #expect(sums.value == (0..<24).map { caller in (0..<200).reduce(0) { $0 + ($1 + caller) * 2 } })
    }
}
