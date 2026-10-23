import AFMKernel
import Foundation

/// One folder of a search's walk (or, without a URL, a plain list of files): what it holds that passed
/// the quick checks, which of these passed the slow ones, and its subfolders.
///
/// Everything but `url` and `depth` is guarded by the condition of the walk (`SearchWalk`).
internal final class SearchNode {
    /// The folder; nil for a plain list of files.
    internal let url: URL?
    /// How far below a start directory the folder lies (0 for a start directory).
    internal let depth: Int
    /// The listing is done, or its first part is published.
    internal var isListed = false
    /// Nothing more will be added to `candidates` (a listing that is reported in parts
    /// is complete); set together with `isListed` for a folder that is not.
    internal var isFinal = false
    /// The entries that passed the quick checks, in name order.
    internal var candidates: [FileItem] = []
    /// Per candidate, while the slow checks are tested: 0 not tested yet, 1 not a hit, 2 a hit.
    ///
    /// Empty when the search has no slow checks: then every candidate is a hit.
    internal var state: [UInt8] = []
    /// The subfolders, in name order.
    internal var children: [SearchNode] = []
    /// Jobs not yet done: the listing, then the tests.
    internal var pending = 1
    /// A start directory that is a place another start directory covers (see `SearchWalk.start`).
    internal var isDuplicateRoot = false
    /// The start directory has claimed its place already (see `SearchWalk.start`).
    internal var isClaimed = false

    /// A folder at `url` (nil: a plain list of files), `depth` levels below a start directory.
    internal init(url: URL?, depth: Int) {
        self.url = url
        self.depth = depth
    }

    deinit {
        // Nothing to release.
    }
}
