import Foundation

/// The questions under way and those waiting their turn.
///
/// All state, that of every `Call` included, is guarded by `lock`.
internal final class CallBook: @unchecked Sendable {
    /// A question to one owner.
    ///
    /// Equal keys are one question.
    private struct Key: Hashable {
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

    /// One question, asked once for all who want its answer.
    private final class Call: @unchecked Sendable {
        let key: Key
        let shares: Bool
        /// Set when nobody waits for the answer any more.
        let flag = CancellationFlag()
        var work: (@Sendable (CancellationFlag) -> Any)?
        var listeners: [Int: @Sendable (Any?) -> Void] = [:]
        var isRunning = false
        /// Running, and given up by everyone who asked.
        var isStranded = false

        init(key: Key, shares: Bool, work: @escaping @Sendable (CancellationFlag) -> Any) {
            (self.key, self.shares, self.work) = (key, shares, work)
        }

        deinit {
            // Nothing to release.
        }
    }

    /// One asker's place at a call.
    internal final class Ticket: Sendable {
        private let leave: @Sendable () -> Void

        /// `leave` takes the asker's place away; it is safe to call more than once.
        internal init(leave: @escaping @Sendable () -> Void) {
            self.leave = leave
        }

        /// The asker no longer wants the answer.
        ///
        /// Safe from any thread, more than once.
        internal func cancel() {
            leave()
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The one book of the program.
    internal static let shared = CallBook()
    /// The most questions one owner has under way at a time, answered or not.
    private static let mostAtOnce = 64

    private let lock = NSLock()
    private var running: [Key: [Call]] = [:]
    /// Not started yet, in the order they were asked.
    private var waiting: [Call] = []
    private var underWay: [ObjectIdentifier: Int] = [:]
    private var lastListener = 0

    /// Asks `question` of `owner`, or joins the same question under way when `shares` (and
    /// it shares too). `work` works the answer out on a kernel thread; `listener` is called
    /// once with the answer, on that thread, unless the ticket is cancelled first.
    internal func ask(
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
            return Ticket { [self] in leave(call, id) }
        }
        let call = Call(key: key, shares: shares, work: work)
        call.listeners[id] = listener
        let starts = canStart(call)
        if starts { begin(call) } else { waiting.append(call) }
        lock.unlock()
        if starts { launch(call) }
        return Ticket { [self] in leave(call, id) }
    }

    /// Called with the lock held.
    private func canStart(_ call: Call) -> Bool {
        (underWay[call.key.owner] ?? 0) < Self.mostAtOnce
            && !(running[call.key]?.contains(where: \.isStranded) ?? false)
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
        withExtendedLifetime(work) {
            // Let go of outside the lock, like everything that may hold much.
        }
        for listener in listeners { listener(answer) }
        for next in starts { launch(next) }
    }

    private func leave(_ call: Call, _ id: Int) {
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
        withExtendedLifetime((listener, work)) {
            // Only kept alive up to here.
        }
    }

    deinit {
        // Nothing to release: the one book lives as long as the program.
    }
}
