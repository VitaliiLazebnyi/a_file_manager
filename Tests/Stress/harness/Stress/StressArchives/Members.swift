import Foundation
import StressKit

/// The members that are in the big archive for good (the probes, and what was added and committed),
/// and how many files the archive holds.
///
/// Unchecked: `readable` and `committedFiles` are only touched while `lock` is held.
internal final class Members: @unchecked Sendable {
    /// Guards `readable` and `committedFiles`.
    private let lock = NSLock()
    /// The members whose bytes are known.
    private var readable: [Probe]
    /// How many files the archive holds after the last commit.
    private var committedFiles: Int

    /// Every member whose bytes are known.
    internal var all: [Probe] {
        lock.withLock { readable }
    }

    /// The probes, in an archive of `files` files.
    internal init(probes: [Probe], files: Int) {
        readable = probes
        committedFiles = files
    }

    /// Mostly one of the first `probeCount` (the probes); with a chance of two in ten any known member.
    internal func pick(probeCount: Int, using random: inout Random) -> Probe {
        lock.withLock {
            Int.random(in: 0..<10, using: &random) < 8
                ? readable[Int.random(in: 0..<probeCount, using: &random)]
                : readable[Int.random(in: 0..<readable.count, using: &random)]
        }
    }

    /// Counts `added` files as committed; returns the files the archive must now hold.
    internal func commit(_ added: Int) -> Int {
        lock.withLock {
            committedFiles += added
            return committedFiles
        }
    }

    /// Makes `added` readable.
    internal func append(_ added: [Probe]) {
        lock.withLock { readable += added }
    }

    deinit {
        // Nothing to release.
    }
}
