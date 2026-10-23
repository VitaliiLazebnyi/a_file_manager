import AFMKernel
import Foundation

/// What the listing of one folder of a search has collected so far: the entries that passed the quick
/// checks and the subfolders to search.
///
/// Each batch is looked at as it arrives, so the whole listing of a big folder is never in memory at once.
internal struct SearchListing {
    /// Whether the subfolders are searched too (the depth limit is not reached).
    internal let descends: Bool
    /// The entries that passed the quick checks and are not reported yet, in the order they came.
    internal private(set) var wanted: [FileItem] = []
    /// The subfolders to search (and the archives to search like folders), in the order they came.
    internal private(set) var subfolders: [(name: String, url: URL)] = []
    /// How many entries the listing has brought so far.
    internal private(set) var seen = 0
    /// The folder is reported in parts while the listing goes on.
    internal var isStreaming = false

    /// An empty listing; with `descends` the subfolders are collected too.
    internal init(descends: Bool) {
        self.descends = descends
    }

    /// Looks at one batch of the listing: keeps what passes the quick checks of `search`, and the subfolders
    /// to search, found through `provider`.
    internal mutating func add(_ batch: [FileItem], of search: FileSearch, provider: any FileSystemProvider) {
        for entry in batch {
            if search.passesQuickChecks(entry), !search.testsText || !entry.isDirectory {
                wanted.append(entry)
            }
            guard descends else {
                continue
            }
            // Links to folders are found but not followed, so the search cannot run in circles.
            if entry.isRealDirectory {
                subfolders.append((entry.name, entry.url))
            } else if search.query.searchArchives, !entry.isDirectory,
                let inside = search.archiveRoot(of: entry, in: provider)
            {
                subfolders.append((entry.name, inside))
            }
        }
        seen += batch.count
    }

    /// Takes the wanted entries out, in name order: only what is reported needs an order.
    internal mutating func takeWanted() -> [FileItem] {
        let part = Sorter.sorted(wanted, byName: \.name)
        wanted = []
        return part
    }
}
