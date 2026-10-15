import AFMKernel
import Foundation
import TestSupport

@testable import CompareContentPlugin

/// Two files of a memory file system, `/A/left.txt` and `/B/right.txt`, and compare sessions on them without a
/// window.
///
/// Main thread only.
@MainActor
internal final class CovCompareStage {
    /// The files.
    internal let memory = MemoryFileSystem()
    /// The kernel with fake panels and jobs that run at once.
    internal let bench: TestBench

    /// The two files with the given contents; throws when the memory file system refuses them.
    internal init(left: Data, right: Data) throws {
        bench = TestBench(
            plugins: [],
            fileSystems: [memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
        try put(left, at: "/A/left.txt")
        try put(right, at: "/B/right.txt")
    }

    /// The two files with the given texts.
    internal convenience init(left: String, right: String) throws {
        try self.init(left: Data(left.utf8), right: Data(right.utf8))
    }

    /// Lets the main thread run what was queued for it until `condition` holds; false when it still does not after
    /// `Wait.ceiling`.
    internal static func settle(until condition: () -> Bool) async -> Bool {
        let end = Date(timeIntervalSinceNow: Wait.ceiling)
        while !condition() {
            guard Date() < end else {
                return false
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }

    /// Lines `"line 0"` to `"line <count - 1>"`, each ended by a line break.
    internal static func lines(_ count: Int) -> String {
        (0..<count).map { "line \($0)\n" }.joined()
    }

    /// Puts a file holding `data` at `path`, in place of what was there.
    internal func put(_ data: Data, at path: String) throws {
        try CoverageArchivesFSHookedMemory.put(data, at: path, on: memory)
    }

    /// A session on the two files, compared; inline (on the calling thread) unless `inline` is false, when the
    /// comparison is still running.
    internal func session(inline: Bool) -> CompareSession {
        let session = CompareSession(kernel: bench.kernel)
        session.runsInline = inline
        session.leftURL = memory.url("/A/left.txt")
        session.rightURL = memory.url("/B/right.txt")
        session.compare()
        return session
    }

    deinit {
        // Nothing to release.
    }
}
