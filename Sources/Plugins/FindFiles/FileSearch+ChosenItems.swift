import AFMKernel
import Foundation

/// A search of chosen items ("Only search in selected directories/files", "Search in found files").
extension FileSearch {
    /// The roots of a search of chosen items: one plain list of the files that are tested themselves, then
    /// the folders to search inside; none when the search was cancelled while the items were looked at.
    internal func chosenRoots(for urls: [URL], in walk: SearchWalk) -> [SearchNode] {
        let items =
            Parallel.map(urls) { url -> FileItem? in
                guard !self.cancellation.isCancelled else {
                    return nil
                }
                return (try? self.fileSystems.provider(for: url))?.item(at: url, cancellation: self.cancellation)
            }
            .compactMap(\.self)
        guard !cancellation.isCancelled else {
            return []
        }
        let searchedInside = { (item: FileItem) in item.isRealDirectory && self.query.maxDepth != 0 }
        let folders = items.filter(searchedInside)
        // A file listed beside a folder that holds it is found by searching the folder. With
        // a depth limit only the folder's own files are sure to be reached; what lies deeper
        // may be (the results are told apart in `runWalk`). The folders are looked up as a set and
        // each item's parents are walked up, not every item compared with every folder.
        let folderKeys = Set(folders.map(\.url.locationKey))
        let reached = { (item: FileItem) -> Bool in
            guard !folderKeys.isEmpty else {
                return false
            }
            var url = item.url
            for _ in 0..<(self.query.maxDepth == nil ? max(url.pathComponents.count, 1) : 1) {
                url = url.deletingLastPathComponent()
                if folderKeys.contains(url.locationKey) {
                    return true
                }
            }
            return false
        }
        var own: [FileItem] = []
        // The name goes first, it rejects most and costs least.
        for item in items where !cancellation.isCancelled && !searchedInside(item) && passesQuickChecks(item) {
            if !reached(item) {
                own.append(item)
            }
        }
        return [walk.makeNode(files: testsText ? own.filter { !$0.isDirectory } : own)]
            + folders.map { walk.makeNode(directory: $0.url, depth: 1) }
    }
}
