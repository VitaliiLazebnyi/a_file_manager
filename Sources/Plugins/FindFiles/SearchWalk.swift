import AFMKernel
import Foundation

/// The walk of one `FileSearch` run: a few threads list folders and test the files found, all from
/// one stack of jobs (the job that comes last in path order is on the bottom), while the
/// calling thread hands the results out in path order as they become ready.
///
/// The shared state is the folder tree of `SearchNode`s, which the walk's condition protects.
internal final class SearchWalk {
    private let search: FileSearch
    /// Whether the candidates are tested further (text, field rules), after the quick checks.
    private let testsCandidates: Bool
    private let condition = NSCondition()
    private let jobs = SearchJobStack()
    private let visited: VisitedFolders
    private let budget: SearchBudget

    /// Whether the search was cancelled or the walk stopped.
    internal var isStopped: Bool {
        search.cancellation.isCancelled || budget.isStopped
    }

    /// The walk of `search`; nothing runs until `start`.
    internal init(_ search: FileSearch) {
        self.search = search
        testsCandidates = search.testsText || search.query.fieldRules.isActive
        visited = VisitedFolders(hasDepthLimit: search.query.maxDepth != nil)
        let shared = SearchBudget(limit: search.budget)
        budget = shared
        jobs.shouldHold = { job in shared.holdsBack(job) }
    }

    /// Ends the walk early (the result limit): what is left is dropped.
    internal func stop() {
        budget.stop()
        _ = jobs.close()
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    /// Drops the jobs that are left and returns them, to be let go of on another thread.
    internal func close() -> Any {
        jobs.close()
    }

    /// The node of a folder to search, `depth` levels below a start directory.
    internal func makeNode(directory: URL, depth: Int) -> SearchNode {
        SearchNode(url: directory, depth: depth)
    }

    /// The node of a plain list of files, which are tested themselves.
    internal func makeNode(files: [FileItem]) -> SearchNode {
        let node = SearchNode(url: nil, depth: 0)
        node.candidates = files
        return node
    }

    /// Starts the workers on `roots`, in order.
    internal func start(_ roots: [SearchNode]) {
        // The start directories claim their places in order, so that of two that are one
        // place (a firmlink), the first is searched, whichever thread is quicker.
        for root in roots {
            guard let url = root.url else {
                continue
            }
            root.isDuplicateRoot = !claim(url, depth: root.depth)
            root.isClaimed = true
        }
        jobs.start(threads: search.threads)
        var first: [SearchJobStack.Job] = []
        for root in roots {
            if root.url == nil {
                first += publish(root, candidates: root.candidates, children: [], isFinal: true)
            } else {
                first.append(SearchJobStack.Job(node: root, isListing: true) { self.list(root) })
            }
        }
        jobs.push(first)
    }

    /// Reports each folder in turn: the folder, then what of its entries is ready, in
    /// order, while the rest is still being tested, then its subfolders.
    ///
    /// Returns early when cancelled or stopped.
    internal func deliver(_ root: SearchNode, onDirectory: (URL) -> Void, onMatch: (FileItem) -> Void) {
        var stack = [root]
        while let node = stack.popLast() {
            guard waitUntilListed(node) else {
                if isStopped {
                    return
                }
                continue
            }
            if let url = node.url {
                onDirectory(url)
            }
            guard deliverEntries(of: node, onMatch: onMatch) else {
                return
            }
            condition.lock()
            node.candidates = []
            node.state = []
            let children = node.children
            node.children = []
            condition.unlock()
            stack.append(contentsOf: children.reversed())
        }
    }

    /// Waits until `node` is listed (or its listing failed); false when it was not listed or the walk stopped.
    private func waitUntilListed(_ node: SearchNode) -> Bool {
        condition.lock()
        budget.setNeeded(node)
        while !node.isListed, node.pending > 0, !isStopped {
            condition.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
        budget.setNeeded(nil)
        let isListed = node.isListed
        condition.unlock()
        return !isStopped && isListed
    }

    /// Reports the hits among the candidates of `node` as they become ready, until all are tested and
    /// the listing is complete; false when the walk stopped.
    private func deliverEntries(of node: SearchNode, onMatch: (FileItem) -> Void) -> Bool {
        var index = 0
        while true {
            condition.lock()
            // A folder that is listed in parts grows while it is reported.
            let total = node.candidates.count
            var end = index
            var flags: [UInt8] = []
            if testsCandidates {
                while end < total, node.state[end] != 0 {
                    end += 1
                }
                flags = Array(node.state[index..<end])
            } else {
                end = total
            }
            guard end > index else {
                let finished = node.isFinal && index >= total
                if !finished, !isStopped {
                    condition.wait(until: Date(timeIntervalSinceNow: 0.05))
                }
                condition.unlock()
                if isStopped {
                    return false
                }
                if finished {
                    return true
                }
                continue
            }
            let batch = Array(node.candidates[index..<end])
            condition.unlock()
            budget.adjust(by: -(end - index))
            for offset in 0..<(end - index) where flags.isEmpty || flags[offset] == 2 {
                if isStopped {
                    return false
                }
                onMatch(batch[offset])
            }
            index = end
        }
    }

    /// Whether this folder is still to be searched (`VisitedFolders.claim`); a location that is not a
    /// local folder always is.
    private func claim(_ url: URL, depth: Int) -> Bool {
        guard let identity = search.folderIdentity(url) else {
            return true
        }
        return visited.claim(identity, depth: depth)
    }

    private func finishJob(of node: SearchNode) {
        condition.lock()
        node.pending -= 1
        if node.pending == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    private func list(_ node: SearchNode) {
        guard let url = node.url, !isStopped, !node.isDuplicateRoot,
            node.isClaimed || claim(url, depth: node.depth),
            let provider = try? search.fileSystems.provider(for: url)
        else {
            finishJob(of: node)
            return
        }
        var listing = SearchListing(descends: search.query.maxDepth.map { node.depth < $0 } ?? true)
        do {
            try provider.list(
                url,
                showHidden: search.query.includeHidden,
                cancellation: search.cancellation
            ) { batch in
                listing.add(batch, of: search, provider: provider)
                // A folder of very many entries is reported in parts, as the listing comes in, each part
                // in name order, so that the first hit does not wait for the last entry.
                if listing.isStreaming || listing.seen >= search.partialListingAfter, !listing.wanted.isEmpty,
                    !isStopped
                {
                    listing.isStreaming = true
                    jobs.push(publish(node, candidates: listing.takeWanted(), children: [], isFinal: false))
                }
                return !isStopped
            }
        } catch {
            guard listing.isStreaming else {
                finishJob(of: node)
                return
            }
            // What was reported stays; the folder ends here.
            jobs.push(publish(node, candidates: [], children: [], isFinal: true))
            return
        }
        guard !isStopped else {
            if listing.isStreaming {
                jobs.push(publish(node, candidates: [], children: [], isFinal: true))
            } else {
                finishJob(of: node)
            }
            return
        }
        // Only what is reported needs an order, and only the matches are sorted.
        let wanted = listing.takeWanted()
        let subfolders = Sorter.sorted(listing.subfolders, byName: \.name)
        let children = subfolders.map { SearchNode(url: $0.url, depth: node.depth + 1) }
        // The tests of this folder go first: they are needed first.
        jobs.push(
            publish(node, candidates: wanted, children: children, isFinal: true)
                + children.map { child in SearchJobStack.Job(node: child, isListing: true) { self.list(child) } }
        )
    }

    /// Makes a node's candidates and subfolders known, all at once under the lock (the
    /// reporting thread must never see them without the state that goes with them), and
    /// returns the jobs that test the candidates; the node's pending count is the number of
    /// them.
    ///
    /// Without slow criteria nothing is left to do.
    private func publish(
        _ node: SearchNode,
        candidates: [FileItem],
        children: [SearchNode],
        isFinal: Bool
    ) -> [SearchJobStack.Job] {
        let size = search.testsText ? 4 : 32
        let ranges =
            testsCandidates
            ? stride(from: 0, to: candidates.count, by: size).map { $0..<min($0 + size, candidates.count) } : []
        budget.adjust(by: candidates.count)
        condition.lock()
        // The first part of a folder takes the place of the listing job in the count; later ones add to it.
        let isFirst = !node.isListed
        let base = isFirst ? 0 : node.candidates.count
        if isFirst {
            node.candidates = candidates
        } else {
            node.candidates.append(contentsOf: candidates)
        }
        if isFinal {
            node.children = children
        }
        if testsCandidates {
            if isFirst {
                node.state = [UInt8](repeating: 0, count: candidates.count)
            } else {
                node.state.append(contentsOf: [UInt8](repeating: 0, count: candidates.count))
            }
        }
        node.pending = (isFirst ? 0 : node.pending) + ranges.count
        node.isListed = true
        node.isFinal = isFinal
        condition.broadcast()
        condition.unlock()
        return ranges.map { range in
            SearchJobStack.Job(node: node, isListing: false) {
                let results = range.map { !self.isStopped && self.search.passesSlowChecks(candidates[$0]) }
                self.condition.lock()
                for (offset, index) in range.enumerated() {
                    node.state[base + index] = results[offset] ? 2 : 1
                }
                node.pending -= 1
                self.condition.broadcast()
                self.condition.unlock()
            }
        }
    }

    deinit {
        // Nothing to release: the tree is let go of by whoever ran the walk.
    }
}
