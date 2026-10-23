import AFMKernel
import Foundation

/// Changes on volumes that are not disks of this Mac (shares, automounted folders), for
/// callers that hold a `CancellationFlag`.
///
/// A system call into a share whose server has gone can wait for as long as the system
/// likes, and a signal ends it only where the volume was mounted to allow that. So such a
/// change is made on a thread of the kernel's own while the caller waits for it: when the
/// flag is set, the call is sent the signal, waited for for a moment more, and then left
/// behind. The caller gets `userCancelled` and is free; the thread stays with the call until
/// the system lets it go.
///
/// **What that means for the change:** a call that was left behind is not known to have
/// failed. It makes no further system call once it comes back, but the one it was in may
/// still take effect when the server answers again. Whoever cancels takes nothing for done
/// and nothing for undone, as with any cancelled call.
///
/// A volume with several calls left behind is not asked again until one of them returns:
/// further changes there fail at once (`ETIMEDOUT`), instead of costing a thread each.
/// All state is guarded by `lock`.
internal final class RemoteChanges: @unchecked Sendable {
    /// Where the call's thread leaves its result, and learns that nobody waits for it.
    ///
    /// All state is guarded by `lock`.
    private final class Outcome<Value: Sendable>: @unchecked Sendable {
        /// Guards the other two.
        let lock = NSLock()
        /// What the call came back with; nil while it is under way.
        var result: Result<Value, any Error>?
        /// The caller has stopped waiting.
        var isLeftBehind = false

        deinit {
            // Nothing to release.
        }
    }

    /// The one table of the program, shared by every local file system.
    internal static let shared = RemoteChanges()

    /// The most calls on one volume that may be left behind at a time.
    internal static let limit = 4

    private let lock = NSLock()
    /// Volume → the calls that were left behind and have not come back.
    private var stranded: [String: Int] = [:]

    /// How many calls on `volume` were left behind and have not come back.
    internal func strandedCalls(on volume: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return stranded[volume] ?? 0
    }

    /// Makes the change `body` with `call` on a thread of its own and waits for it.
    ///
    /// Once `cancellation` is set the call is interrupted, waited for for `patience` seconds more,
    /// and then left behind with `userCancelled`. Fails at once with `ETIMEDOUT` while too many
    /// calls on `volume` have been left behind. Blocks the calling thread.
    internal func run<Value: Sendable>(
        on volume: String,
        patience: TimeInterval,
        cancellation: CancellationFlag,
        _ call: LocalCall,
        _ body: @escaping @Sendable (LocalCall) throws -> Value
    ) throws -> Value {
        lock.lock()
        let isDead = (stranded[volume] ?? 0) >= Self.limit
        lock.unlock()
        if isDead {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ETIMEDOUT),
                userInfo: [NSLocalizedDescriptionKey: "The volume at \(volume) does not answer."]
            )
        }
        let box = Outcome<Value>()
        let done = DispatchSemaphore(value: 0)
        start(body, with: call, on: volume, into: box, signalling: done)
        func finished() -> Result<Value, any Error>? {
            box.lock.lock()
            defer { box.lock.unlock() }
            return box.result
        }
        // Woken by the end of the call, or by the flag.
        let registration = cancellation.onCancel { done.signal() }
        defer {
            withExtendedLifetime(registration) {
                // Kept registered up to here.
            }
        }
        done.wait()
        if let result = finished() {
            return try result.get()
        }
        // Cancelled. The call has been sent its signal; it gets a moment to come back.
        call.interruption.interrupt()
        _ = done.wait(timeout: .now() + patience)
        box.lock.lock()
        if let result = box.result {
            box.lock.unlock()
            return try result.get()
        }
        // Counted before the call can see that it was left behind, so that its return takes
        // the count down again and never comes first.
        box.isLeftBehind = true
        lock.lock()
        stranded[volume, default: 0] += 1
        lock.unlock()
        box.lock.unlock()
        throw CocoaError(.userCancelled)
    }

    /// Makes the call on a thread of the kernel's own, leaves its result in `box` and signals
    /// `done`; a call that was left behind meanwhile takes itself off the count of `volume`.
    private func start<Value: Sendable>(
        _ body: @escaping @Sendable (LocalCall) throws -> Value,
        with call: LocalCall,
        on volume: String,
        into box: Outcome<Value>,
        signalling done: DispatchSemaphore
    ) {
        BlockingCalls.run { [self] in
            let result = Result { try body(call) }
            box.lock.lock()
            box.result = result
            let wasLeftBehind = box.isLeftBehind
            box.lock.unlock()
            if wasLeftBehind {
                lock.lock()
                if let count = stranded[volume] { stranded[volume] = count > 1 ? count - 1 : nil }
                lock.unlock()
            }
            done.signal()
        }
    }

    deinit {
        // Nothing to release: a call left behind holds what it needs itself.
    }
}
