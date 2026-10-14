import AFMKernel
import Foundation

/// Limits how many long jobs of one kind (building the row index of a text) are on threads at
/// once. A read that cannot be interrupted (a share that stopped answering, a provider that
/// ignores `interrupt`) keeps its thread after the job was cancelled; without a limit, paging
/// quickly through files on such a volume would start a job, and strand a thread, for every file.
///
/// - At most `live` jobs that nobody has cancelled run at once; the others wait their turn, and a
///   waiting job that is cancelled before its turn is dropped without ever running.
/// - A cancelled job whose thread is still inside a read is not live any more, but it holds its
///   thread. When `stuck` threads are held like that, a new job is refused (`refused` is called
///   instead of the work) instead of making one thread more.
///
/// All state is guarded by `lock`.
final class ViewerWorkGate: @unchecked Sendable {
    /// Index builds of text documents.
    static let indexBuilds = ViewerWorkGate(
        live: max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)), stuck: 8)

    let live: Int
    let stuck: Int
    private let lock = NSLock()
    private struct Waiting {
        let flag: CancellationFlag
        let work: @Sendable () -> Void
        let refused: @Sendable () -> Void
    }
    private struct Running {
        let flag: CancellationFlag
        var token: AnyObject?
    }
    private var waiting: [Waiting] = []
    private var running: [Int: Running] = [:]
    private var lastID = 0

    init(live: Int, stuck: Int) {
        self.live = max(1, live)
        self.stuck = max(1, stuck)
    }

    /// Jobs that hold a thread now, cancelled or not (for tests).
    var threadsInUse: Int {
        lock.lock()
        defer { lock.unlock() }
        return running.count
    }

    /// Jobs that wait for their turn (for tests).
    var waitingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiting.filter { !$0.flag.isCancelled }.count
    }

    /// Runs `work` on a background thread as soon as the limits allow, unless `flag` is set
    /// before; or calls `refused` (on this thread) when `stuck` threads are held by cancelled
    /// jobs that have not come back. Any thread.
    func submit(
        cancellation flag: CancellationFlag, refused: @escaping @Sendable () -> Void = {},
        _ work: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        waiting.removeAll { $0.flag.isCancelled }
        if running.values.reduce(0, { $0 + ($1.flag.isCancelled ? 1 : 0) }) >= stuck {
            lock.unlock()
            refused()
            return
        }
        waiting.append(Waiting(flag: flag, work: work, refused: refused))
        let ready = takeReady()
        lock.unlock()
        start(ready)
    }

    /// The jobs that may start now; called with the lock held.
    private func takeReady() -> [(Int, Waiting)] {
        var ready: [(Int, Waiting)] = []
        while let next = waiting.first {
            if next.flag.isCancelled {
                waiting.removeFirst()
                continue
            }
            let alive = running.values.reduce(0) { $0 + ($1.flag.isCancelled ? 0 : 1) }
            guard alive < live else { break }
            waiting.removeFirst()
            lastID += 1
            running[lastID] = Running(flag: next.flag, token: nil)
            ready.append((lastID, next))
        }
        return ready
    }

    private func start(_ ready: [(Int, Waiting)]) {
        for (id, job) in ready {
            // A job that is cancelled while it runs no longer counts as live: the next may start.
            let token = job.flag.onCancel { [weak self] in self?.pump() }
            lock.lock()
            running[id]?.token = token
            lock.unlock()
            // On a thread of the kernel's own: the work reads a file, and one that does not
            // come back (the gate bounds how many may) must not hold a thread of the system's
            // shared pool, which every other part of the program needs.
            BlockingCalls.run { [self] in
                autoreleasepool { job.work() }
                finish(id)
            }
        }
    }

    private func finish(_ id: Int) {
        lock.lock()
        let token = running.removeValue(forKey: id)?.token
        let ready = takeReady()
        lock.unlock()
        withExtendedLifetime(token) {}
        start(ready)
    }

    private func pump() {
        lock.lock()
        let ready = takeReady()
        lock.unlock()
        start(ready)
    }
}
