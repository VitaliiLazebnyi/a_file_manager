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
    /// Runs `work` on a thread of the kernel's own, inside an autorelease pool, and returns at
    /// once. For any thread. The threads are made as they are needed and go away when idle.
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
    public static func answer<Answer: Sendable>(
        from owner: AnyObject,
        to question: String,
        sharing: Bool = true,
        cancellation: CancellationFlag? = nil,
        _ work: @escaping @Sendable (CancellationFlag) -> Answer
    ) -> Answer? {
        if cancellation?.isCancelled == true { return nil }
        let slot = Slot<Answer>()
        let done = DispatchSemaphore(value: 0)
        let ticket = CallBook.shared.ask(owner: owner, question: question, shares: sharing, work: { work($0) }) {
            answer in
            slot.set(answer as? Answer)
            done.signal()
        }
        let registration = cancellation?
            .onCancel {
                ticket.cancel()
                done.signal()
            }
        done.wait()
        return withExtendedLifetime(registration) { cancellation?.isCancelled == true ? nil : slot.value }
    }

    /// The same without waiting: `deliver` is called once, on the main thread, with the
    /// answer, or with nil when `cancellation` was set first. For any thread.
    public static func answer<Answer: Sendable>(
        from owner: AnyObject,
        to question: String,
        sharing: Bool = true,
        cancellation: CancellationFlag? = nil,
        _ work: @escaping @Sendable (CancellationFlag) -> Answer,
        then deliver: @escaping @MainActor @Sendable (Answer?) -> Void
    ) {
        let slot = Slot<Answer>()
        // Only the first of answer and cancellation is delivered.
        @Sendable func finish(_ answer: Answer?) {
            guard slot.close() else { return }
            DispatchQueue.main.async { deliver(answer) }
        }
        if cancellation?.isCancelled == true {
            finish(nil)
            return
        }
        let ticket = CallBook.shared.ask(owner: owner, question: question, shares: sharing, work: { work($0) }) {
            answer in
            finish(answer as? Answer)
            slot.keep(nil)
        }
        let registration = cancellation?
            .onCancel {
                ticket.cancel()
                finish(nil)
            }
        // Kept until the answer has come; forgotten at once if it has come already.
        slot.keep(registration)
    }

    /// Where an answer is put by one thread and taken by another; guarded by `lock`.
    private final class Slot<Answer>: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: Answer?
        private var isClosed = false
        private var held: AnyObject?

        func set(_ answer: Answer?) {
            lock.lock()
            defer { lock.unlock() }
            self.answer = answer
        }

        var value: Answer? {
            lock.lock()
            defer { lock.unlock() }
            return answer
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
            withExtendedLifetime(dropped) {}
        }
    }
}

/// The questions under way and those waiting their turn. All state, that of every `Call`
/// included, is guarded by `lock`.
final class CallBook: @unchecked Sendable {
    static let shared = CallBook()

    /// A question to one owner. Equal keys are one question.
    fileprivate struct Key: Hashable {
        let owner: ObjectIdentifier
        let question: String

        static func == (left: Self, right: Self) -> Bool {
            left.owner == right.owner && left.question == right.question
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(owner)
            hasher.combine(question)
        }
    }

    fileprivate final class Call: @unchecked Sendable {
        fileprivate let key: Key
        let shares: Bool
        /// Set when nobody waits for the answer any more.
        let flag = CancellationFlag()
        var work: (@Sendable (CancellationFlag) -> Any)?
        var listeners: [Int: @Sendable (Any?) -> Void] = [:]
        var isRunning = false
        /// Running, and given up by everyone who asked.
        var isStranded = false

        fileprivate init(key: Key, shares: Bool, work: @escaping @Sendable (CancellationFlag) -> Any) {
            (self.key, self.shares, self.work) = (key, shares, work)
        }
    }

    /// One asker's place at a call.
    final class Ticket: Sendable {
        private let book: CallBook
        private let call: Call
        private let id: Int

        fileprivate init(book: CallBook, call: Call, id: Int) {
            (self.book, self.call, self.id) = (book, call, id)
        }

        /// The asker no longer wants the answer. Safe from any thread, more than once.
        func cancel() {
            book.leave(call, id)
        }
    }

    private let lock = NSLock()
    private var running: [Key: [Call]] = [:]
    /// Not started yet, in the order they were asked.
    private var waiting: [Call] = []
    private var underWay: [ObjectIdentifier: Int] = [:]
    private var lastListener = 0
    /// The most questions one owner has under way at a time, answered or not.
    private static let mostAtOnce = 64

    /// `listener` is called once with the answer, on the thread that worked it out, unless
    /// the ticket is cancelled first.
    func ask(
        owner: AnyObject,
        question: String,
        shares: Bool,
        work: @escaping @Sendable (CancellationFlag) -> Any,
        listener: @escaping @Sendable (Any?) -> Void
    ) -> Ticket {
        let key = Key(owner: ObjectIdentifier(owner), question: question)
        lock.lock()
        lastListener += 1
        let id = lastListener
        if shares,
            let call = running[key]?.first(where: { $0.shares && !$0.isStranded })
                ?? waiting.first(where: { $0.key == key && $0.shares })
        {
            call.listeners[id] = listener
            lock.unlock()
            return Ticket(book: self, call: call, id: id)
        }
        let call = Call(key: key, shares: shares, work: work)
        call.listeners[id] = listener
        let starts = canStart(call)
        if starts { begin(call) } else { waiting.append(call) }
        lock.unlock()
        if starts { launch(call) }
        return Ticket(book: self, call: call, id: id)
    }

    /// Called with the lock held.
    private func canStart(_ call: Call) -> Bool {
        (underWay[call.key.owner] ?? 0) < Self.mostAtOnce && !(running[call.key]?.contains { $0.isStranded } ?? false)
    }

    /// Called with the lock held.
    private func begin(_ call: Call) {
        call.isRunning = true
        running[call.key, default: []].append(call)
        underWay[call.key.owner, default: 0] += 1
    }

    private func launch(_ call: Call) {
        KernelThreads.shared.run { [self] in
            lock.lock()
            let work = call.work
            lock.unlock()
            let answer = work.map { $0(call.flag) }
            finish(call, answer)
        }
    }

    private func finish(_ call: Call, _ answer: Any?) {
        lock.lock()
        running[call.key]?.removeAll { $0 === call }
        if running[call.key]?.isEmpty == true { running[call.key] = nil }
        if let count = underWay[call.key.owner] { underWay[call.key.owner] = count > 1 ? count - 1 : nil }
        let listeners = Array(call.listeners.values)
        let work = call.work
        (call.listeners, call.work, call.isRunning) = ([:], nil, false)
        // What was waiting for this one, or for room, starts now.
        var starts: [Call] = []
        var index = 0
        while index < waiting.count {
            if canStart(waiting[index]) {
                let next = waiting.remove(at: index)
                begin(next)
                starts.append(next)
            } else {
                index += 1
            }
        }
        lock.unlock()
        // Let go of outside the lock, like everything that may hold much.
        withExtendedLifetime(work) {}
        for listener in listeners { listener(answer) }
        for next in starts { launch(next) }
    }

    fileprivate func leave(_ call: Call, _ id: Int) {
        lock.lock()
        guard let listener = call.listeners.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        var isGivenUp = false
        var work: (@Sendable (CancellationFlag) -> Any)?
        if call.listeners.isEmpty {
            if call.isRunning {
                call.isStranded = true
                isGivenUp = true
            } else {
                waiting.removeAll { $0 === call }
                (work, call.work) = (call.work, nil)
            }
        }
        lock.unlock()
        // Outside the lock: the flag's handlers run here, and closures are let go.
        if isGivenUp { call.flag.cancel() }
        withExtendedLifetime((listener, work)) {}
    }
}

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

/// Lets go of large lists away from the thread that used them: freeing a million entries
/// takes a tenth of a second and more, which the main thread does not have.
enum Discard: Sendable {
    /// Lists shorter than this are not worth the trip.
    static let threshold = 20_000

    /// Empties `items`; if the list is long, the memory is released on a background thread
    /// (when nobody else holds the list, otherwise whoever lets go last releases it).
    static func later<Element>(_ items: inout [Element]) {
        guard items.count >= threshold else {
            items = []
            return
        }
        let box = Box(items)
        items = []
        KernelThreads.shared.run { box.empty() }
    }

    /// Handed from the thread that lets go to the one that releases. Unchecked: the thread
    /// that made it lets go of it without touching the list, so one thread at a time uses it.
    private final class Box<Element>: @unchecked Sendable {
        private var items: [Element]
        init(_ items: [Element]) { self.items = items }
        func empty() { items.removeAll() }
    }
}
