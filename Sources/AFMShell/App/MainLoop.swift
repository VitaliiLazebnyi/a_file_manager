import AFMKernel
import AppKit

/// The way back to the main thread for everything that may end in a dialog.
///
/// A modal dialog runs an event loop of its own. Started from inside a block of the main
/// dispatch queue, that loop cannot run the blocks queued behind it (the queue is serial and
/// its current block has not returned), so for as long as the dialog is up nothing that was
/// dispatched to the main thread arrives: no piece of a directory, no progress, no timer of
/// the queue. Started from the run loop, the dialog's loop serves the queue like any other.
/// So whatever the shell brings to the main thread and hands on to code that may ask the
/// user something (the end of a reading, of a job, a drop) comes through here.
internal enum MainLoop {
    /// Blocks that open a dialog, waiting for their turn.
    @MainActor private static var dialogs: [@MainActor () -> Void] = []
    /// True while the dialog of one of `dialogs` is on screen.
    @MainActor private static var dialogIsUp = false

    /// Runs `block` on the main thread, from the run loop and not from the main dispatch queue.
    ///
    /// It runs in every mode a dialog or a menu runs the loop in. Blocks run in the order they
    /// were handed in. Safe to call from any thread.
    internal static func perform(_ block: @escaping @MainActor @Sendable () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated(block)
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// The same for a block made on the main thread, which may hold what belongs to it.
    ///
    /// The block waits for its turn in a `MainOwned` box, and runs and is let go of on the main
    /// thread.
    @MainActor
    internal static func queue(_ block: @escaping @MainActor () -> Void) {
        let owned = MainOwned(block)
        perform { owned.take()?() }
    }

    /// The same after a delay; the returned function calls it off.
    ///
    /// Main thread only.
    @MainActor
    @discardableResult
    internal static func after(_ delay: TimeInterval, _ block: @escaping @MainActor () -> Void) -> () -> Void {
        // The timer is on the main run loop, so it fires on the main thread.
        let timer = Timer(timeInterval: max(0, delay), repeats: false) { _ in MainActor.assumeIsolated(block) }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    /// Runs a block that tells or asks the user something with a dialog.
    ///
    /// It runs from the run loop, and never while the dialog of an earlier such block is still
    /// on screen, so two panels that fail at the same moment show their messages one after the
    /// other and not one on top of the other. Main thread only.
    @MainActor
    internal static func dialog(_ block: @escaping @MainActor () -> Void) {
        dialogs.append(block)
        perform { showNextDialog() }
    }

    /// Runs the first waiting dialog block, unless a dialog is up.
    @MainActor
    private static func showNextDialog() {
        guard !dialogIsUp, !dialogs.isEmpty else {
            return
        }
        dialogIsUp = true
        dialogs.removeFirst()()
        dialogIsUp = false
        if !dialogs.isEmpty {
            perform { showNextDialog() }
        }
    }
}
