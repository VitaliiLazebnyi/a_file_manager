import AFMKernel
import Foundation

/// Reports changes made by other programs to the watched folders, about half a second after
/// they happen (spec 03 › Watching the file system).
///
/// The system reports every change anywhere below a watched folder, which for the home
/// folder or a whole disk is a great deal. Those reports arrive on a queue of the watcher's
/// own and are sifted there; only a change in one of the watched folders themselves is
/// passed on to the caller's queue, and then in lumps: a burst of reports becomes one call.
///
/// **No call here waits for the file system.** `watch(_:)` only records what is wanted; the
/// folders are resolved (`realpath` asks the disk, and a stalled share does not answer) and
/// the streams are made and started on queues of the watcher's own, so the caller may be the
/// main thread.
///
/// The parts are the types `FSEv*`: the census of streams, the gate, the state of a
/// running watch, the core that makes the streams, and what is asked of the system.
internal final class DirectoryWatcher: Sendable {
    private let core: FSEvCore

    /// The folders the streams watch now, once the requests made before have been dealt with
    /// (the folders that are still being resolved are not among them yet).
    internal var watchedFolders: Set<URL> { core.watchedFolders }

    /// `onChange` receives the watched folders whose contents changed, on `queue`; `system`
    /// makes the streams.
    internal init(queue: DispatchQueue, system: FSEvSystem, onChange: @escaping @Sendable ([URL]) -> Void) {
        core = FSEvCore(queue: queue, system: system, onChange: onChange)
    }

    /// `onChange` receives the watched folders whose contents changed, on `queue`.
    internal convenience init(queue: DispatchQueue, onChange: @escaping @Sendable ([URL]) -> Void) {
        self.init(queue: queue, system: .live, onChange: onChange)
    }

    /// `onChange` receives the watched folders whose contents changed, on the main queue.
    internal convenience init(onChange: @escaping @Sendable ([URL]) -> Void) {
        self.init(queue: .main, system: .live, onChange: onChange)
    }

    /// Replaces the set of watched folders.
    ///
    /// Only their direct contents are reported. Returns at once; the streams follow in the
    /// background.
    internal func watch(_ directories: [URL]) {
        core.request(directories)
    }

    /// Stops watching, for good; reports under way are dropped.
    internal func stop() {
        core.stop()
    }

    deinit { core.stop() }
}
