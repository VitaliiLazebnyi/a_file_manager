public import AFMKernel
public import Foundation

/// Watching virtual folders through the real directories behind them.
extension VirtualFileSystem {
    /// Watches the real directories behind the virtual folders, as far as that is cheap: the
    /// directories read on the last walk of a branch (up to `watchLimit`), and the folders of
    /// the files of a list.
    ///
    /// Any change in them is reported as a change of the virtual folder, on the main thread.
    @preconcurrency
    public func watch(_ directories: [URL], onChange: @escaping @MainActor @Sendable ([URL]) -> Void) -> (
        any WatchToken
    )? {
        var watchers: [any WatchToken] = []
        var coalescers: [Coalescer] = []
        var shownLists: [Int] = []
        for virtual in directories {
            guard let location = VirtualLocation(virtual) else {
                continue
            }
            switch location {
            case .list(let id, _, _), .picked(let id, _):
                shownLists.append(id)

            case .branch:
                break
            }
            // Up to `watchLimit` folders report; a busy one must not have the whole virtual
            // folder walked again for each report.
            let coalescer = Coalescer { onChange([virtual]) }
            coalescers.append(coalescer)
            watchers += watch(realDirectories(behind: virtual, location)) { coalescer.signal() }
        }
        guard !watchers.isEmpty else {
            for coalescer in coalescers { coalescer.cancel() }
            return nil
        }
        lists.show(shownLists)
        return Watchers(watchers, coalescers: coalescers) { [weak self, shownLists] in
            self?.lists.hide(shownLists)
        }
    }

    /// The real directories whose changes are changes of the virtual folder, up to `watchLimit`.
    private func realDirectories(behind virtual: URL, _ location: VirtualLocation) -> [URL] {
        let real: [URL]
        switch location {
        case .branch(let root), .picked(_, let root):
            let walked = walkedDirectories(of: virtual)
            real = walked.isEmpty ? [root] : walked

        case .list(let id, _, _):
            // Done by the preparation of the list; a list that is not through yet is
            // looked at in its first files only, so this takes no time on the main thread.
            real =
                lists.registered(id, as: location)
                .map { list in
                    list.preparedIfReady?.parents ?? parents(ofFirst: Self.parentScanLimit, of: list.raw)
                } ?? []
        }
        return Array(real.prefix(Self.watchLimit))
    }

    /// Watches `directories` on their own file systems, one watcher per scheme; `signal` is
    /// called on any change.
    private func watch(_ directories: [URL], signal: @escaping @Sendable () -> Void) -> [any WatchToken] {
        var watchers: [any WatchToken] = []
        for (_, group) in Dictionary(grouping: directories, by: \.scheme) {
            guard let provider = try? fileSystems.provider(for: group[0]), provider !== self,
                let watcher = provider.watch(group, onChange: { _ in signal() })
            else { continue }
            watchers.append(watcher)
        }
        return watchers
    }

    /// The folders of the first `count` files, each once, as many as are watched.
    private func parents(ofFirst count: Int, of files: [URL]) -> [URL] {
        var parents = ParentFolders(fileSystems: fileSystems)
        for entry in files.prefix(count) {
            parents.add(entry)
            if parents.isFull { break }
        }
        return parents.found
    }
}
