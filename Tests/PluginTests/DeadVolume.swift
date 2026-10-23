import Foundation

@testable import LocalFileSystemPlugin

/// A folder that stands for a share whose server has gone: every question the file system
/// puts to the system about a path in it waits here until the "server" answers again.
///
/// The folder itself is an ordinary one on the local disk. Unchecked: the state is guarded by
/// `condition`.
internal final class DeadVolume: @unchecked Sendable {
    /// The path of the folder that stands for the share.
    internal let root: String
    private let condition = NSCondition()
    private var answers = false
    private var waitingNow = 0
    private var askedSoFar = 0

    /// How many questions are waiting at this moment.
    internal var waiting: Int {
        condition.lock()
        defer { condition.unlock() }
        return waitingNow
    }

    /// How many questions were ever put about a path in the folder.
    internal var asked: Int {
        condition.lock()
        defer { condition.unlock() }
        return askedSoFar
    }

    /// A share that does not answer, at the folder `root`.
    internal init(_ root: URL) { self.root = root.path }

    /// The server is back: everything that waits goes on, and nothing waits from now on.
    internal func answer() {
        condition.lock()
        answers = true
        condition.broadcast()
        condition.unlock()
    }

    /// A file system that takes the folder for a volume that is not a disk of this Mac.
    ///
    /// `patienceAfterCancel` is how long a cancelled change is waited for before it is left behind,
    /// `volumePatience` how long a question about the volume is waited for before it is answered from memory.
    internal func fileSystem(patienceAfterCancel: TimeInterval, volumePatience: TimeInterval) -> LocalFileSystem {
        var probes = LocalProbes()
        probes.willAsk = { [self] path in willAsk(path) }
        probes.isLocal = { [self] path in holds(path) ? false : MountTable.shared.isLocal(path) }
        probes.patienceAfterCancel = patienceAfterCancel
        probes.volumePatience = volumePatience
        return LocalFileSystem(probes: probes)
    }

    private func holds(_ path: String) -> Bool { path == root || path.hasPrefix(root + "/") }

    private func willAsk(_ path: String) {
        guard holds(path) else {
            return
        }
        condition.lock()
        askedSoFar += 1
        waitingNow += 1
        while !answers { condition.wait() }
        waitingNow -= 1
        condition.unlock()
    }

    deinit {
        // Nothing to release.
    }
}
