import os

/// Spreads independent work over the processor's cores.
public enum Parallel: Sendable {
    private static let log = Log.logger("Kernel")

    /// True while the calling code runs as part of a `map` that the main thread is waiting
    /// for (on the main thread itself or on one of the helping threads): waiting for the
    /// main thread from here would never end.
    public static var isHoldingUpMainThread: Bool { ParallelPool.shared.isWorkingForMainThread }

    /// Transforms every element, using all cores, and returns the results in the original order.
    ///
    /// `transform` runs on several threads at once and must not touch shared state without protecting it. Short inputs
    /// are done on the calling thread.
    ///
    /// Calls may be nested: a transform that calls `map` itself (a walk through a tree of
    /// folders) shares the same threads, so the work below the top level is spread over the
    /// cores as well, and the number of threads stays bounded however deep the calls go.
    ///
    /// **A call made on the main thread must not hop to the main thread.** The main thread
    /// waits inside `map` until every element is done, so a transform that waits for it in
    /// turn (`DispatchQueue.main.sync`, `Kernel.askUser`, anything that asks the user) never
    /// returns: the program hangs, or stops with a trap when the hop is tried on the main
    /// thread itself. That holds for everything the transform calls, nested `map`s included.
    /// Work that may have to ask the main thread is started from a background thread. Code
    /// that is about to wait for the main thread says so with
    /// `Parallel.assertMayWaitForMainThread()`, which stops a wrong caller in debug builds.
    ///
    /// Every piece of the work runs inside an autorelease pool of its own, on whatever thread
    /// it runs: what a transform leaves to be released later (data read through Foundation)
    /// is gone when the piece ends.
    @preconcurrency
    public static func map<Element, Result>(
        _ items: [Element],
        serialBelow threshold: Int = 2,
        _ transform: @Sendable (Element) -> Result
    ) -> [Result] where Element: Sendable, Result: Sendable {
        guard items.count >= threshold, items.count > 1, ParallelPool.shared.width > 0 else {
            return items.map(transform)
        }
        return [Result](unsafeUninitializedCapacity: items.count) { buffer, count in
            // Each iteration writes its own slot, so the slots need no lock.
            nonisolated(unsafe) let slots = buffer
            items.withUnsafeBufferPointer { source in
                // Only read, while the call lasts.
                nonisolated(unsafe) let elements = source
                withoutActuallyEscaping(transform) { work in
                    ParallelPool.shared.run(count: elements.count) { index in
                        slots.initializeElement(at: index, to: work(elements[index]))
                    }
                }
            }
            count = items.count
        }
    }

    /// To be called by whatever is about to wait for the main thread (before
    /// `DispatchQueue.main.sync`): logs a fault, with the place of the call, for a caller that
    /// is part of a `map` the main thread waits for (see `map`); the wait that follows would
    /// never end.
    public static func assertMayWaitForMainThread(file: StaticString = #fileID, line: UInt = #line) {
        guard isHoldingUpMainThread else {
            return
        }
        log.fault(
            """
            Work inside a Parallel.map that the main thread waits for waits for the main thread \
            (\(file, privacy: .public):\(line))
            """
        )
    }
}
