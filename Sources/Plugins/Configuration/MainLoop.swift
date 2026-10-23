import Foundation

/// Hands a block to the main thread through the run loop (all modes that count), not through
/// the main dispatch queue: a block that asks the user something runs a modal dialog, and a
/// dialog started from inside a block of the main queue keeps every later block of the queue
/// (directory pieces, progress) waiting until it is closed.
internal enum MainLoop {
    /// Runs `block` on the main thread at the next turn of its run loop; callable from any thread.
    internal static func perform(_ block: @escaping @MainActor @Sendable () -> Void) {
        // The main run loop runs the block on the main thread.
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated(block) }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
