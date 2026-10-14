public import Foundation

/// Work on a thread of its own, as the program's background work runs: not on the main thread,
/// and not on a thread of Swift's concurrency pool, which a blocked test could starve.
public enum OtherThread {
    /// Starts `work` on a new thread and returns at once.
    ///
    /// `stackSize` gives the thread a stack of that many bytes; nil keeps the system's size.
    @preconcurrency
    public static func start(stackSize: Int? = nil, _ work: @escaping @Sendable () -> Void) {
        let thread = Thread(block: work)
        if let stackSize {
            thread.stackSize = stackSize
        }
        thread.start()
    }

    /// Runs `work` on a new thread and waits for what it returns, as a panel does with long lists.
    ///
    /// Nil only when it did not return within `seconds`: a hang, to be reported as a failure.
    @preconcurrency
    public static func result<Value>(
        stackSize: Int? = nil,
        seconds: TimeInterval = Wait.ceiling,
        of work: @escaping @Sendable () -> Value
    ) -> Value? {
        let done = Signal<Value>()
        start(stackSize: stackSize) { done.set(work()) }
        return done.wait(seconds: seconds)
    }
}
