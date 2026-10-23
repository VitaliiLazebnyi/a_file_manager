import AFMKernel
import Foundation

/// One question to a volume that is under way, and everybody who waits for its answer.
///
/// Unchecked: `info` and `isOver` are guarded by `condition`, `wasAnsweredFromMemory` by
/// the file system's `volumeLock`.
internal final class VolumeQuestion: @unchecked Sendable {
    /// How a wait for the answer ended.
    internal enum Outcome {
        /// The volume answered in time; nil when it could not say.
        case answered(VolumeInfo?)
        /// The caller's flag was set first.
        case cancelled
        /// The time was up before the volume answered.
        case late
    }

    /// When the question was put, in nanoseconds of uptime.
    internal let asked = DispatchTime.now().uptimeNanoseconds
    /// Somebody was answered from memory because this took too long.
    ///
    /// Guarded by the file system's `volumeLock`.
    internal var wasAnsweredFromMemory = false
    private let condition = NSCondition()
    private var info: VolumeInfo?
    private var isOver = false

    /// The volume has answered (with nil when it could not say): everybody who waits is woken.
    internal func finish(_ info: VolumeInfo?) {
        condition.lock()
        (self.info, isOver) = (info, true)
        condition.broadcast()
        condition.unlock()
    }

    /// Waits for the answer until `deadline` (nanoseconds of uptime) or until `cancellation` is
    /// set, whichever comes first.
    internal func wait(until deadline: UInt64, _ cancellation: CancellationFlag?) -> Outcome {
        let registration = cancellation?
            .onCancel { [condition] in
                condition.lock()
                condition.broadcast()
                condition.unlock()
            }
        defer {
            withExtendedLifetime(registration) {
                // Kept registered up to here.
            }
        }
        condition.lock()
        defer { condition.unlock() }
        while cancellation?.isCancelled != true, !isOver {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                return .late
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: TimeInterval(deadline - now) / 1_000_000_000))
        }
        // A caller that has cancelled is not given the answer, even one that came in time.
        return cancellation?.isCancelled == true ? .cancelled : .answered(info)
    }

    deinit {
        // Nothing to release.
    }
}
