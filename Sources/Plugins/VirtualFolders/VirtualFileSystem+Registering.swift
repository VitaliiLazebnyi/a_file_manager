public import Foundation

/// Registering lists and the selected branches, and what was registered.
extension VirtualFileSystem {
    /// The location that shows the branch view of a real directory.
    public func branch(of directory: URL) -> URL {
        VirtualLocation.branch(real: directory).url
    }

    /// Registers a list of files and returns the location that shows it.
    ///
    /// A file that is named twice is listed once. `origin` is where `[..]` leads back to. Takes no
    /// time however long the list is: the files are looked at later, on a background thread.
    public func register(files: [URL], title: String, origin: URL?) -> URL {
        register(files: files, title: title, origin: origin, isUnique: false)
    }

    /// The same for a list the caller knows holds no location twice (Find Files leaves out the
    /// ones it has reported): the list is not looked through for doubles, which for a list of
    /// millions saves a key per file.
    public func register(files: [URL], title: String, origin: URL?, isUnique: Bool) -> URL {
        register(files, isUnique: isUnique) { id in
            .list(id: id, title: VirtualLocation.pathComponent(title), origin: origin)
        }
    }

    /// Registers the items of `directory` a selected branch view starts from, and returns the
    /// location that shows it.
    public func registerPicked(_ items: [URL], in directory: URL) -> URL {
        register(items, isUnique: false) { .picked(id: $0, real: directory) }
    }

    /// The real locations a registered list or selected branch was made from; empty for every
    /// other location and for a list that was forgotten.
    ///
    /// Waits for a long list to be worked through: not for the main thread.
    public func entries(of url: URL) -> [URL] {
        guard let location = VirtualLocation(url) else {
            return []
        }
        switch location {
        case .picked(let id, _), .list(let id, _, _):
            return lists.registered(id, as: location).map { prepared($0).entries } ?? []

        case .branch:
            return []
        }
    }

    /// The real location a location in a branch view or selected branch stands for: the file
    /// or folder that is really there, which is what an operation on it must go to.
    ///
    /// Nil for every other URL and for a list (whose entries keep their real locations).
    public func realLocation(of url: URL) -> URL? {
        switch VirtualLocation(url) {
        case .branch(let real), .picked(_, let real):
            return real

        case .list, nil:
            return nil
        }
    }

    /// Works out what has to look at every file of the list.
    ///
    /// Blocks while another thread is on it; for the background.
    internal func prepared(_ list: FileList) -> PreparedList {
        list.prepared { raw in
            var seen = Set<[UInt8]>()
            var entries: [URL] = []
            if !list.isUnique {
                seen.reserveCapacity(raw.count)
                entries.reserveCapacity(raw.count)
            }
            var schemes = Set<String>()
            var examples: [URL] = []
            var isLocal = true
            var parents = ParentFolders(fileSystems: fileSystems)
            for url in raw where list.isUnique || seen.insert(Self.identity(of: url)).inserted {
                if !list.isUnique { entries.append(url) }
                if schemes.insert(url.scheme ?? "file").inserted { examples.append(url) }
                if !url.isFileURL { isLocal = false }
                parents.add(url)
            }
            return PreparedList(
                entries: list.isUnique ? raw : entries,
                examples: examples,
                parents: parents.found,
                isLocal: isLocal
            )
        }
    }

    /// Registers a list made from `entries` and returns its location; prepares it at once when it
    /// is short, in the background otherwise.
    private func register(_ entries: [URL], isUnique: Bool, location: (Int) -> VirtualLocation) -> URL {
        let list = lists.add(entries, isUnique: isUnique, location: location)
        if entries.count <= Self.inlineEntryLimit {
            _ = prepared(list)
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [self] in _ = prepared(list) }
        }
        return list.location.url
    }
}
