import Foundation

/// One registered list.
extension VirtualFileSystem {
    /// A registered list: the files of a search result, or the items a selected branch starts from.
    ///
    /// The files are registered as they come, which takes no time however many there are; what
    /// has to look at each of them (leaving out a file named twice, finding the folders to
    /// watch) is done once by `prepared`, off the main thread for a long list.
    ///
    /// `result` is guarded by `lock`, `stamp` by the lock of the `ListStore` that holds the list;
    /// the rest is fixed in `init`.
    internal final class FileList: @unchecked Sendable {
        /// The location that shows the list, which holds its id.
        internal let location: VirtualLocation
        /// The files as they were registered, perhaps with doubles.
        internal let raw: [URL]
        /// The caller said no location is in `raw` twice.
        internal let isUnique: Bool
        /// When the list was last used (a number from the store's counter): the least
        /// recently used one is forgotten first.
        ///
        /// Guarded by the store's lock.
        internal var stamp = 0
        private let lock = NSLock()
        private var result: PreparedList?

        /// The finished work; nil when it is not done yet, whoever is doing it.
        ///
        /// Never waits.
        internal var preparedIfReady: PreparedList? {
            guard lock.try() else {
                return nil
            }
            defer { lock.unlock() }
            return result
        }

        /// A list of `raw` shown at `location`, not prepared yet.
        internal init(location: VirtualLocation, raw: [URL], isUnique: Bool) {
            self.location = location
            self.raw = raw
            self.isUnique = isUnique
        }

        /// The finished work, waiting for it when another thread is on it; `make` does it the
        /// first time, from the raw files.
        internal func prepared(_ make: ([URL]) -> PreparedList) -> PreparedList {
            lock.lock()
            defer { lock.unlock() }
            if let result {
                return result
            }
            let made = make(raw)
            result = made
            return made
        }

        deinit {
            // Nothing to release.
        }
    }
}
