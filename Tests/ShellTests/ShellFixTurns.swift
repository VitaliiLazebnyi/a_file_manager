import Foundation
import TestSupport

@testable import AFMShell

/// Puts a step of the test in its place among what the background sends to the main thread.
@MainActor
internal enum ShellFixTurns {
    /// Runs `step` on the main thread right after what the work handed in before to the lane of
    /// `purpose` at `location` sends there, and before anything that sending starts in turn.
    ///
    /// A lane runs one piece of work at a time, and what goes to the main thread from the run
    /// loop (`MainLoop.perform`) runs in the order it was sent; so a piece queued behind the work
    /// in the lane, which sends `step`, sends it right after the work's answer.
    internal static func afterWork(
        inLane purpose: String,
        at location: URL,
        _ step: @escaping @MainActor () -> Void
    ) {
        let owned = MainOwned(step)
        Background.storage(purpose, at: location) { MainLoop.perform { owned.take()?() } }
    }

    /// The same, holding the main thread until the answer and `step` have both been sent, so
    /// that nothing the answer starts on the main thread comes before `step`.
    internal static func afterWorkHeld(
        inLane purpose: String,
        at location: URL,
        _ step: @escaping @MainActor () -> Void
    ) -> Bool {
        let owned = MainOwned(step)
        let sent = Shared(false)
        Background.storage(purpose, at: location) {
            MainLoop.perform { owned.take()?() }
            sent.value = true
        }
        return Wait.until { sent.value }
    }

    /// Waits until a timer of the run loop that is started now with `delay` has fired: timers fire
    /// in the order of their times, so every timer started before with that delay or a shorter one
    /// has fired too.
    internal static func timer(after delay: TimeInterval) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            MainLoop.after(delay) { done.resume() }
        }
    }
}
