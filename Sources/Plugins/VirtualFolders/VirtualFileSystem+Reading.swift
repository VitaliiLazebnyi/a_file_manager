public import AFMKernel
public import Foundation

/// Listing virtual folders and looking at their items.
extension VirtualFileSystem {
    /// What a listing of a virtual folder works with, whichever kind it is.
    private struct Listing {
        /// The virtual folder that is listed.
        let directory: URL
        /// The options as they were when the listing began.
        let options: Options
        /// The walker of its branches, with those options.
        let walker: BranchWalker
        /// Set when the listing is to stop.
        let cancellation: CancellationFlag?

        var isCancelled: Bool { cancellation?.isCancelled == true }
    }

    /// Every item of a virtual folder: the files of its branch, or the files of its list.
    public func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        var items: [FileItem] = []
        try list(directory, showHidden: showHidden) { batch in
            items += batch
            return true
        }
        return items
    }

    /// The items of a virtual folder in batches, as they are found; `receive` returns false to stop.
    public func list(_ directory: URL, showHidden: Bool, receive: ([FileItem]) -> Bool) throws {
        try listing(directory, showHidden: showHidden, cancellation: nil, receive: receive)
    }

    /// Every item of a virtual folder; once the flag is set, what was found so far.
    public func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        var items: [FileItem] = []
        try list(directory, showHidden: showHidden, cancellation: cancellation) { batch in
            items += batch
            return true
        }
        return items
    }

    /// The items in batches; once the flag is set, nothing more is read or handed over.
    public func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag, receive: ([FileItem]) -> Bool)
        throws
    {
        try listing(directory, showHidden: showHidden, cancellation: cancellation, receive: receive)
    }

    /// The item at a location in a virtual folder: the virtual folder itself for a directory,
    /// otherwise the real file; nil when nothing is there.
    public func item(at url: URL) -> FileItem? {
        virtualItem(at: url, cancellation: nil)
    }

    /// The same; the flag ends the wait for a real file system that is slow to answer.
    public func item(at url: URL, cancellation: CancellationFlag) -> FileItem? {
        virtualItem(at: url, cancellation: cancellation)
    }

    /// Lists a virtual folder of any kind, in batches.
    private func listing(
        _ directory: URL,
        showHidden: Bool,
        cancellation: CancellationFlag?,
        receive: ([FileItem]) -> Bool
    ) throws {
        guard let location = VirtualLocation(directory) else { throw FileSystemError.noProvider(directory) }
        let current = options
        let listing = Listing(
            directory: directory,
            options: current,
            walker: BranchWalker(
                fileSystems: fileSystems,
                showHidden: showHidden,
                listsFolders: current.listsFolders,
                entersPackages: current.entersPackages
            ),
            cancellation: cancellation
        )
        switch location {
        case .branch(let real):
            try listBranch(of: real, listing, receive: receive)

        case .list(let id, let title, _):
            guard let list = lists.registered(id, as: location) else { throw ForgottenList(title: title) }
            listFiles(of: list, listing, receive: receive)

        case .picked(let id, let real):
            guard let list = lists.registered(id, as: location) else {
                throw ForgottenList(title: real.lastPathComponent)
            }
            try listPicked(list, in: real, listing, receive: receive)
        }
    }

    /// Lists the branch view of the real directory `real`.
    private func listBranch(of real: URL, _ listing: Listing, receive: ([FileItem]) -> Bool) throws {
        noteCapabilities(of: [real], for: listing.directory)
        let visited = try listing.walker.walk(
            [BranchWalker.Start(real)],
            mustRead: true,
            keeping: Self.watchLimit,
            cancellation: listing.cancellation,
            receive: receive
        )
        // What a stopped walk read is not the branch.
        if !listing.isCancelled { remember(visited, for: listing.directory) }
    }

    /// Lists a selected branch: the picked items of `real`, and the branches of the picked folders.
    private func listPicked(_ list: FileList, in real: URL, _ listing: Listing, receive: ([FileItem]) -> Bool) throws {
        let entries = prepared(list).entries
        noteCapabilities(of: [real], for: listing.directory)
        let cancellation = listing.cancellation
        let found = Parallel.map(entries) { self.realItem(at: $0, cancellation: cancellation) }.compactMap(\.self)
        let names = Self.uniqueNames(of: found) { self.fileSystems.displayPath($0.url) }
        var starts: [BranchWalker.Start] = []
        var files: [FileItem] = []
        for (item, name) in zip(found, names) {
            let isWalked = item.isRealDirectory && (listing.options.entersPackages || !item.isPackage)
            if isWalked { starts.append(BranchWalker.Start(item.url, prefix: name + "/")) }
            if !isWalked || listing.options.listsFolders { files.append(name == item.name ? item : item.named(name)) }
        }
        if listing.isCancelled {
            return
        }
        if !files.isEmpty, !receive(files) {
            return
        }
        let visited = try listing.walker.walk(
            starts,
            keeping: Self.watchLimit,
            cancellation: cancellation,
            receive: receive
        )
        if !listing.isCancelled { remember([real] + visited, for: listing.directory) }
    }

    /// Lists the files of a list, each from its own file system, a batch at a time.
    private func listFiles(of list: FileList, _ listing: Listing, receive: ([FileItem]) -> Bool) {
        let prepared = self.prepared(list)
        let entries = prepared.entries
        noteCapabilities(of: prepared.examples, for: listing.directory)
        let cancellation = listing.cancellation
        for from in stride(from: 0, to: entries.count, by: Self.entriesPerBatch) {
            if listing.isCancelled {
                return
            }
            let chunk = Array(entries[from..<min(from + Self.entriesPerBatch, entries.count)])
            // Each file is asked for on its own file system; what has vanished is left out.
            let items = Parallel.map(chunk) { url in
                self.realItem(at: url, cancellation: cancellation)?.named(self.fileSystems.displayPath(url))
            }
            if listing.isCancelled || !receive(items.compactMap(\.self)) {
                return
            }
        }
    }

    /// The file on its own file system.
    private func realItem(at url: URL, cancellation: CancellationFlag?) -> FileItem? {
        guard let provider = try? fileSystems.provider(for: url) else {
            return nil
        }
        return cancellation.map { provider.item(at: url, cancellation: $0) } ?? provider.item(at: url)
    }

    /// The item at a location of this scheme, for both `item(at:)` calls.
    private func virtualItem(at url: URL, cancellation: CancellationFlag?) -> FileItem? {
        guard let location = VirtualLocation(url) else {
            return nil
        }
        switch location {
        case .branch(let real), .picked(_, let real):
            guard let item = realItem(at: real, cancellation: cancellation) else {
                return nil
            }
            // A directory is the virtual folder itself; anything else is simply the real file.
            return item.isDirectory
                ? FileItem(
                    url: url,
                    name: item.name,
                    kind: .directory,
                    stat: .init(modified: item.modified, permissions: item.permissions)
                ) : item

        case .list(let id, let title, _):
            return lists.registered(id, as: location) == nil
                ? nil : FileItem(url: url, name: title, kind: .directory, stat: .init(permissions: 0o555))
        }
    }
}
