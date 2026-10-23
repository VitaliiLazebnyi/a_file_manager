import AFMKernel

/// What a watcher of virtual folders holds.
extension VirtualFileSystem {
    /// Keeps the real file systems' watchers alive for as long as the caller keeps this.
    internal final class Watchers: Sendable {
        /// The watchers of the real directories, released with this.
        internal let watchers: [any WatchToken]
        private let coalescers: [Coalescer]
        private let release: @Sendable () -> Void

        /// Holds `watchers` and the coalescers their reports go through; `release` runs when
        /// this goes.
        internal init(_ watchers: [any WatchToken], coalescers: [Coalescer], release: @escaping @Sendable () -> Void) {
            self.watchers = watchers
            self.coalescers = coalescers
            self.release = release
        }

        deinit {
            // A report that is still waiting for its turn must not reach a released watcher.
            for coalescer in coalescers { coalescer.cancel() }
            release()
        }
    }
}
