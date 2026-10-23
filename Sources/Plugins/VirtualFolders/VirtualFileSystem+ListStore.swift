import Foundation

/// Keeping the registered lists.
extension VirtualFileSystem {
    /// The registered lists of a virtual file system, and which of them are shown.
    ///
    /// Used from several threads at once; all mutable state, and the `stamp` of each list, is
    /// guarded by `lock`.
    internal final class ListStore: @unchecked Sendable {
        private let lock = NSLock()
        private var lists: [Int: FileList] = [:]
        /// Ids are numbered from a random start, so the location of a list from an earlier run of
        /// the program (it is stored with tabs, history and hotlist) never names another list.
        private var nextID = Int.random(in: 1_000...1_000_000_000)
        /// How many watchers look at a virtual folder of each list: a list that is shown stays.
        private var watched: [Int: Int] = [:]
        /// Counts the uses of lists, to find the one that was used least recently.
        private var uses = 0

        /// Registers a list under a new id; `location` makes its location from the id.
        ///
        /// Forgets old lists that are not shown when there are too many lists or files.
        internal func add(_ entries: [URL], isUnique: Bool, location: (Int) -> VirtualLocation) -> FileList {
            lock.lock()
            defer { lock.unlock() }
            let id = nextID
            nextID += 1
            let list = FileList(location: location(id), raw: entries, isUnique: isUnique)
            uses += 1
            list.stamp = uses
            lists[id] = list
            forgetSurplus(keeping: id)
            return list
        }

        /// The list registered as `id`, when it is the one the location says: a stored location
        /// whose number was given to another list means nothing.
        ///
        /// Counts as a use of the list.
        internal func registered(_ id: Int, as location: VirtualLocation) -> FileList? {
            lock.lock()
            defer { lock.unlock() }
            guard let list = lists[id], list.location.url.absoluteString == location.url.absoluteString else {
                return nil
            }
            uses += 1
            list.stamp = uses
            return list
        }

        /// The list registered as `id`, whatever its location; not counted as a use.
        internal func list(_ id: Int) -> FileList? {
            lock.lock()
            defer { lock.unlock() }
            return lists[id]
        }

        /// Notes that one more watcher looks at a virtual folder of each of the lists.
        internal func show(_ ids: [Int]) {
            lock.lock()
            defer { lock.unlock() }
            for id in ids { watched[id, default: 0] += 1 }
        }

        /// Notes that a watcher of each of the lists has gone; a list nobody watches can be forgotten.
        internal func hide(_ ids: [Int]) {
            lock.lock()
            defer { lock.unlock() }
            for id in ids {
                if let count = watched[id] { watched[id] = count > 1 ? count - 1 : nil }
            }
        }

        /// Forgets the least recently used lists that are not shown (watched) while there are too
        /// many lists or files; when all are shown, the limits are exceeded.
        ///
        /// Under the lock.
        private func forgetSurplus(keeping id: Int) {
            var total = lists.values.reduce(0) { sum, list in sum + list.raw.count }
            while lists.count > VirtualFileSystem.listLimit || total > VirtualFileSystem.entryLimit {
                guard
                    let oldest = lists.filter({ entry in entry.key != id && watched[entry.key] == nil })
                        .min(by: { first, second in first.value.stamp < second.value.stamp })
                else { return }
                total -= oldest.value.raw.count
                lists[oldest.key] = nil
            }
        }

        deinit {
            // Nothing to release.
        }
    }
}
