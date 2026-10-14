import Foundation

/// Work that may wait for as long as it likes (a question to a file system whose volume has
/// stopped answering, a read from a server), run on threads of the kernel's own.
///
/// **Why not a dispatch queue.** The global queues have a fixed number of threads. A call that
/// never returns keeps its thread for good, and a few dozen such calls (one per refresh of a
/// folder on a dead share is enough) leave none for anybody: folders on healthy disks stop
/// loading, file jobs stop, timers on those queues stop. Work that is known to block on
/// something outside the program therefore goes here, where each piece has a thread to
/// itself and nobody else is short of one.
///
/// **Questions to a file system** (`answer`) are bounded on top of that, so that a location
/// which does not answer costs one thread and not one per try:
/// - The same question to the same file system is asked once: whoever asks while it is under
///   way waits for the same answer (`sharing`), or, for questions whose answers cannot be
///   shared (a listing delivered piece by piece), waits until the unanswered one is over and
///   asks then. Nothing is ever started behind a question that was given up and has still
///   not come back.
/// - One file system has at most 64 questions under way; further ones wait their turn.
/// - Waiting costs no thread of the kernel's, and it ends at once when the asker's
///   `CancellationFlag` is set. The question itself may go on (a system call cannot be taken
///   back); it is told through the flag it was handed, and its answer is dropped.
public enum BlockingCalls: Sendable {
    /// Where an answer is put by one thread and taken by another; guarded by `lock`.
    private final class Slot<Answer>: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: Answer?
        private var isClosed = false
        private var held: AnyObject?

        /// The answer put last; nil before any.
        var value: Answer? {
            lock.lock()
            defer { lock.unlock() }
            return answer
        }

        /// Puts the answer for the waiting thread to take.
        func put(_ answer: Answer?) {
            lock.lock()
            defer { lock.unlock() }
            self.answer = answer
        }

        /// True the first time only.
        func close() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            defer { isClosed = true }
            return !isClosed
        }

        /// Holds `object` until the slot is closed; nil lets go of what is held.
        func keep(_ object: AnyObject?) {
            lock.lock()
            let dropped = held
            held = isClosed ? nil : object
            lock.unlock()
            // Released outside the lock: a registration takes the flag's own when it goes.
            withExtendedLifetime(dropped) {
                // Only kept alive up to here.
            }
        }

        deinit {
            // Nothing to release.
        }
    }

    /// Runs `work` on a thread of the kernel's own, inside an autorelease pool, and returns at once.
    ///
    /// For any thread. The threads are made as they are needed and go away when idle.
    @preconcurrency
    public static func run(_ work: @escaping @Sendable () -> Void) {
        KernelThreads.shared.run(work)
    }

    /// Asks a file system (or whatever `owner` stands for) a question that may block, and
    /// waits for the answer on the calling thread, which must not be the main thread. `work`
    /// runs on a kernel thread; the flag it is handed is set when nobody waits for the answer
    /// any more, and it is that flag, not the caller's, that `work` passes on to the file system.
    ///
    /// `question` names what is asked, the location included (`"volume " + url.locationKey`):
    /// equal questions to one owner are one question (see the type). With `sharing`, askers of
    /// the same question get the same answer; without, each gets its own, one after the other
    /// once an earlier one was given up.
    ///
    /// Returns nil when `cancellation` was set before the answer came.
    @preconcurrency
    public static func answer<Answer: Sendable>(
        from owner: AnyObject,
        to question: String,
        sharing: Bool = true,
        cancellation: CancellationFlag? = nil,
        _ work: @escaping @Sendable (CancellationFlag) -> Answer
    ) -> Answer? {
        if cancellation?.isCancelled == true {
            return nil
        }
        let slot = Slot<Answer>()
        let done = DispatchSemaphore(value: 0)
        let ticket = CallBook.shared.ask(
            owner: owner,
            question: question,
            shares: sharing,
            work: { work($0) },
            listener: { answer in
                slot.put(answer as? Answer)
                done.signal()
            }
        )
        let registration = cancellation?
            .onCancel {
                ticket.cancel()
                done.signal()
            }
        done.wait()
        return withExtendedLifetime(registration) { cancellation?.isCancelled == true ? nil : slot.value }
    }

    /// The same without waiting: `deliver` is called once, on the main thread, with the answer, or with nil when
    /// `cancellation` was set first.
    ///
    /// Askers of the same question share its answer. For any thread.
    @preconcurrency
    public static func answer<Answer: Sendable>(
        from owner: AnyObject,
        to question: String,
        cancellation: CancellationFlag? = nil,
        _ work: @escaping @Sendable (CancellationFlag) -> Answer,
        then deliver: @escaping @MainActor @Sendable (Answer?) -> Void
    ) {
        let slot = Slot<Answer>()
        // Only the first of answer and cancellation is delivered.
        @Sendable
        func finish(_ answer: Answer?) {
            guard slot.close() else {
                return
            }
            DispatchQueue.main.async { deliver(answer) }
        }
        if cancellation?.isCancelled == true {
            finish(nil)
            return
        }
        let ticket = CallBook.shared.ask(
            owner: owner,
            question: question,
            shares: true,
            work: { work($0) },
            listener: { answer in
                finish(answer as? Answer)
                slot.keep(nil)
            }
        )
        let registration = cancellation?
            .onCancel {
                ticket.cancel()
                finish(nil)
            }
        // Kept until the answer has come; forgotten at once if it has come already.
        slot.keep(registration)
    }
}
