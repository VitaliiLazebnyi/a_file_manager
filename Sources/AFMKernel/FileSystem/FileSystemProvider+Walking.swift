public import Foundation

/// Walks through trees of folders the way any file system can: by listing them.
extension FileSystemProvider {
    /// `totalSizeByListing(of:cancellation:)`.
    public func totalSize(of directory: URL, cancellation: CancellationFlag) -> Int64 {
        totalSizeByListing(of: directory, cancellation: cancellation)
    }

    /// The sum as any file system can work it out, by listing every folder; the subfolders are measured on all cores at
    /// once.
    ///
    /// What a file system falls back on when it has a faster way of its own that does not work everywhere: each
    /// subfolder is asked of the file system again (`totalSize(of:cancellation:)`), so its faster way gets its chance
    /// one level down.
    ///
    /// A tree can be as deep as whoever made it liked (an archive with thousands of nested
    /// folders, a server that shows a folder inside itself for ever), and a thread's stack
    /// cannot. So only the first levels are walked by calls that nest; from there on the
    /// walk goes level by level without nesting, stops at a depth no real tree has, and
    /// never lists a location twice. What was counted by then is the answer.
    public func totalSizeByListing(of directory: URL, cancellation: CancellationFlag) -> Int64 {
        let depth = TreeWalk.nesting
        guard depth < TreeWalk.deepestNesting else {
            return totalSizeLevelByLevel(of: directory, cancellation: cancellation)
        }
        TreeWalk.nesting = depth + 1
        defer { TreeWalk.nesting = depth }
        guard !cancellation.isCancelled,
            let items = try? list(directory, showHidden: true, cancellation: cancellation),
            !cancellation.isCancelled
        else { return 0 }
        let files = items.reduce(Int64(0)) { $1.isRealDirectory ? $0 : $0.addingSaturated($1.size) }
        // A measurement started after the flag was set ends at once; the answer is then 0 anyway.
        let folders = Parallel.map(items.filter(\.isRealDirectory)) { folder in
            self.totalSize(of: folder.url, cancellation: cancellation)
        }
        return cancellation.isCancelled ? 0 : folders.reduce(files) { $0.addingSaturated($1) }
    }

    /// The same without a call inside a call: every level of the tree is listed on all cores
    /// before the next one is begun.
    private func totalSizeLevelByLevel(of directory: URL, cancellation: CancellationFlag) -> Int64 {
        var total: Int64 = 0
        var level = [directory]
        var seen: Set<String> = [directory.locationKey]
        var depth = 0
        while !level.isEmpty, depth < TreeWalk.deepestTree, !cancellation.isCancelled {
            let listings = Parallel.map(level) { folder -> [FileItem] in
                cancellation.isCancelled
                    ? [] : (try? self.list(folder, showHidden: true, cancellation: cancellation)) ?? []
            }
            var next: [URL] = []
            for items in listings {
                for item in items {
                    if !item.isRealDirectory {
                        total = total.addingSaturated(item.size)
                    } else if seen.insert(item.url.locationKey).inserted {
                        next.append(item.url)
                    }
                }
            }
            level = next
            depth += 1
        }
        return cancellation.isCancelled ? 0 : total
    }

    /// The top of the tree `url` belongs to, found by going up (the default of the requirement).
    public func root(of url: URL) -> URL {
        var current = url
        while let parent = parent(of: current) { current = parent }
        return current
    }
}
