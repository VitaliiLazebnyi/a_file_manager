import Foundation
import os

/// A feature of the program. A plugin registers what it provides (commands, menu entries,
/// file systems, openers, services) with the kernel when it starts, and keeps whatever state
/// it needs in itself. It never refers to another plugin.
@MainActor
public protocol Plugin: AnyObject {
    var name: String { get }
    /// Called once, before the window exists. Register here; use `kernel.panels` and
    /// `kernel.jobs` only later, inside command handlers.
    func start(in kernel: Kernel)
    /// Called once when the program quits, in the reverse order of `start`. On the main
    /// thread: it must return soon. Work that takes time (writing what is still in memory,
    /// uploads) belongs in `prepareToQuit`.
    func stop()
    /// Asked on the main thread when the user wants to quit, before anything is stopped. A
    /// plugin with work the user would lose (unsaved edits) asks its question here and
    /// returns false when the user cancels: the quit is then called off. The default is true.
    func shouldTerminate() -> Bool
    /// Called on the main thread once the quit is decided and before any plugin is stopped,
    /// so every service is still there. A plugin that has something to finish (changes not
    /// yet written) starts that work in the background and calls `completion`, on any thread
    /// and exactly once, when it is done or has given up because `cancellation` was set (the
    /// user did not want to wait). The default calls `completion` at once.
    func prepareToQuit(cancellation: CancellationFlag, completion: @escaping @Sendable () -> Void)
}

extension Plugin {
    public func stop() {}
    public func shouldTerminate() -> Bool { true }
    public func prepareToQuit(cancellation _: CancellationFlag, completion: @escaping @Sendable () -> Void) {
        completion()
    }
}
