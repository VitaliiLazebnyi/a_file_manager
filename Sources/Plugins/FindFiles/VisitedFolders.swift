import Foundation

/// The folders a search's walk has claimed, by device and inode, with the depth each was met at.
///
/// Any thread; guarded by `lock`.
internal final class VisitedFolders {
    private let lock = NSLock()
    private let hasDepthLimit: Bool
    private var visited: [FileIdentity: Int] = [:]

    /// The folders of a walk; `hasDepthLimit` tells whether the search goes only so deep.
    internal init(hasDepthLimit: Bool) {
        self.hasDepthLimit = hasDepthLimit
    }

    /// Whether the folder `identity`, met `depth` levels below a start directory, is still to be searched.
    ///
    /// A folder met a second time by another road (a firmlink, an overlapping start directory) is left out,
    /// unless it is met nearer to a start directory, where a depth limit lets the search go deeper.
    internal func claim(_ identity: FileIdentity, depth: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let before = visited[identity], hasDepthLimit else {
            return visited.updateValue(depth, forKey: identity) == nil
        }
        // Met nearer to a start directory: searched again, deeper.
        if depth < before {
            visited[identity] = depth
            return true
        }
        return false
    }

    deinit {
        // Nothing to release.
    }
}
