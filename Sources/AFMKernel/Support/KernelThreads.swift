import Foundation

/// Threads for work that blocks: one per piece of work, kept for a few seconds when idle so
/// that a run of short pieces does not start a thread each. All state is guarded by `condition`.
final class KernelThreads: @unchecked Sendable {
    static let shared = KernelThreads()

    private let condition = NSCondition()
    private var queue: [@Sendable () -> Void] = []
    private var idle = 0

    func run(_ work: @escaping @Sendable () -> Void) {
        condition.lock()
        queue.append(work)
        let isTaken = idle >= queue.count
        if isTaken { condition.signal() }
        condition.unlock()
        if !isTaken { start() }
    }

    private func start() {
        let thread = Thread { [self] in
            condition.lock()
            while true {
                if !queue.isEmpty {
                    var work: (@Sendable () -> Void)? = queue.removeFirst()
                    condition.unlock()
                    autoreleasepool { work?() }
                    // Whatever the work held goes here, on this thread, before the next piece.
                    work = nil
                    condition.lock()
                    continue
                }
                idle += 1
                let signalled = condition.wait(until: Date(timeIntervalSinceNow: 5))
                idle -= 1
                if !signalled, queue.isEmpty { break }
            }
            condition.unlock()
        }
        thread.name = "AFM.Blocking"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 1 << 20
        thread.start()
    }
}
