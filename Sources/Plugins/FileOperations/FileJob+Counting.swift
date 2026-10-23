import AFMKernel
import Foundation

/// The listings of folders and the counts the progress is measured against.
extension FileJob {
    /// A folder of a tree being counted: the folder it lies in, what it holds, and where it is remembered.
    private struct MeasureNode {
        /// The place of the folder it lies in among the nodes; -1 for the top.
        var parent: Int
        /// Its own items at first, then everything below it.
        var measure: Measure
        /// The folder's place in `measures`.
        var key: Int
    }

    /// Everything directly inside a directory, hidden items too, in processing order (a delete
    /// has none: nothing depends on it, and sorting a big folder by name is slow).
    ///
    /// Nil when the directory could not be read and the user chose to skip it. An entry whose name
    /// could lead out of the folder (`..`, a name with a slash: a server may send such a thing) is
    /// not returned; it is reported as an error of its own and counted in `rejected`.
    internal func listing(of directory: URL, sorted: Bool) throws -> (items: [FileItem], rejected: Int)? {
        var items: [FileItem] = []
        let verb: OperationRecord.Verb = kind == .copy ? .copy : (isMove ? .move : .delete)
        let readable = try attempt(verb, at: directory, target: nil) {
            items = try self.fileSystems.provider(for: directory)
                .list(
                    directory,
                    showHidden: true,
                    cancellation: self.cancellation
                )
            // A listing that ended because of the cancel is not the whole folder.
            try self.checkCancelled()
            return true
        }
        guard readable else {
            return nil
        }
        var rejected = 0
        if items.contains(where: { !Self.isSafeName($0.name) }) {
            for child in items where !Self.isSafeName(child.name) {
                rejected += 1
                add(Measure(items: 1))
                _ = try attempt(verb, at: directory, target: nil) { throw FileJobError.unsafeName(child.name) }
            }
            items.removeAll { !Self.isSafeName($0.name) }
        }
        return (sorted ? Sorter.sorted(items, byName: \.name) : items, rejected)
    }

    // MARK: Counting

    /// What a source adds to the total.
    ///
    /// A folder that a move is going to rename as a whole is one item, and its contents are not
    /// walked: that would take as long as a copy's count.
    internal func measureForTotal(_ url: URL, _ item: FileItem?) -> Measure {
        guard let item else {
            return Measure(items: 1)
        }
        if isMove, options.filter.isEmpty, item.isRealDirectory, willRename(item) {
            predictedRenames.insert(url.locationKey)
            return Measure(items: 1)
        }
        return measure(item)
    }

    /// Whether the system will rename the folder to its place: both on one local volume, and
    /// nothing there under that name.
    ///
    /// A wrong guess costs a count later, nothing else.
    private func willRename(_ folder: FileItem) -> Bool {
        guard folder.url.isFileURL, let target else {
            return false
        }
        let destination = destination(for: folder.url, in: target)
        guard destination.isFileURL, !destination.isSameLocation(as: folder.url),
            fileSystems.item(at: destination) == nil,
            let here = FileIdentity.device(of: folder.url.deletingLastPathComponent()),
            let there = FileIdentity.device(ofNearest: destination.deletingLastPathComponent())
        else { return false }
        return here == there
    }

    /// What the first count found for a folder, if it kept it; else the folder is walked.
    internal func measuredBefore(_ item: FileItem) -> Measure {
        if let known = remembered.withLock({ measures[item.url.locationKey.hashValue] }) {
            return known
        }
        return measure(item)
    }

    /// Counts a tree level by level: the folders of a level are listed on all cores at once,
    /// and no call goes deeper for a folder that lies deeper, so a tree of any depth (an
    /// archive or a server may show one) costs no stack.
    ///
    /// What lies below `depthLimit` is not counted, as it is not processed.
    internal func measure(_ listed: FileItem) -> Measure {
        let top = followsLinks ? resolvingLink(listed) : listed
        guard top.isRealDirectory, !cancellation.isCancelled else {
            return Measure(items: 1, bytes: top.size)
        }
        var nodes = [MeasureNode(parent: -1, measure: Measure(items: 1), key: top.url.locationKey.hashValue)]
        var level: [(index: Int, url: URL)] = [(0, top.url)]
        var depth = 0
        while !level.isEmpty, !cancellation.isCancelled, depth <= depthLimit {
            var next: [(index: Int, url: URL)] = []
            for start in stride(from: 0, to: level.count, by: Self.measuredAtOnce) {
                if cancellation.isCancelled { break }
                let chunk = Array(level[start..<min(start + Self.measuredAtOnce, level.count)])
                autoreleasepool {
                    measure(chunk, into: &nodes, next: &next)
                }
            }
            level = next
            depth += 1
        }
        // A folder comes after the folder it lies in: adding up from the end gives every
        // folder the sum of what is below it.
        for index in stride(from: nodes.count - 1, to: 0, by: -1) {
            nodes[nodes[index].parent].measure += nodes[index].measure
        }
        if !cancellation.isCancelled { remember(nodes) }
        return nodes[0].measure
    }

    /// Lists the folders of `chunk` side by side and counts what is in them: files and links
    /// into the folder's own node, subfolders as nodes of their own, which go into `next`.
    private func measure(
        _ chunk: [(index: Int, url: URL)],
        into nodes: inout [MeasureNode],
        next: inout [(index: Int, url: URL)]
    ) {
        let listings = Parallel.map(chunk, serialBelow: 2) { folder -> [FileItem] in
            (try? self.fileSystems.provider(for: folder.url)
                .list(folder.url, showHidden: true, cancellation: self.cancellation)) ?? []
        }
        for (folder, children) in zip(chunk, listings) {
            var own = Measure()
            for child in children {
                guard Self.isSafeName(child.name) else {
                    own += Measure(items: 1)
                    continue
                }
                // A link to a file whose size the listing brought along needs no
                // look at the disk to be counted.
                if followsLinks, child.isSymlink, !child.isDirectory, let size = child.linkTargetSize {
                    own += Measure(items: 1, bytes: size)
                    continue
                }
                let item = followsLinks ? resolvingLink(child) : child
                if item.isRealDirectory {
                    nodes.append(
                        MeasureNode(
                            parent: folder.index,
                            measure: Measure(items: 1),
                            key: item.url.locationKey.hashValue
                        )
                    )
                    next.append((nodes.count - 1, item.url))
                } else {
                    own += Measure(items: 1, bytes: item.size)
                }
            }
            nodes[folder.index].measure += own
        }
    }

    /// Keeps the counts of the folders, as far as there is room (see `measures`).
    private func remember(_ nodes: [MeasureNode]) {
        remembered.withLock {
            for node in nodes {
                let room =
                    measures.count < rememberedLimit
                    || (node.measure.items >= Self.worthKeepingPastLimit && measures.count < 2 * rememberedLimit)
                if room { measures[node.key] = node.measure }
            }
        }
    }

    /// What the job has to do, for the progress: trashing takes each item whole, everything else
    /// is counted item by item.
    internal func countTotal() -> Measure {
        if kind == .delete(toTrash: true) {
            return Measure(items: sources.count)
        }
        // Asking a server about a file is a trip there: what the count learns is kept for the walk.
        let remembers = sources.count <= Self.rememberedSources && sources.contains { !$0.isFileURL }
        var items: [FileItem?] = []
        var measured = Measure()
        for source in sources {
            let item = autoreleasepool { try? entry(at: source) }
            if remembers { items.append(item) }
            measured += measureForTotal(source, item)
        }
        if remembers { topItems = items }
        return measured
    }

    /// The entry of a top-level source: what the first count found, where that was kept.
    internal func topItem(_ slot: Int, _ source: URL) throws -> FileItem? {
        if topItems.indices.contains(slot), let known = topItems[slot] {
            try checkCancelled()
            return known
        }
        return try entry(at: source)
    }
}
