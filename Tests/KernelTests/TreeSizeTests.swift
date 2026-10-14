import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// The size of a tree that is deeper than any stack (review 2, K003, K038).
@Suite
internal struct TreeSizeTests {
    /// A tree of folders one inside the other, as deep as wanted, with a file of 3 bytes at
    /// every level.
    ///
    /// Unchecked: the count is guarded by `lock`; `isEndless` is set before use.
    private final class DeepFileSystem: ListingOnly, @unchecked Sendable {
        let scheme = "deep"
        let capabilities: FileSystemCapabilities = []
        let depth: Int
        /// A folder that shows itself as its own child, for ever.
        var isEndless = false
        private let lock = NSLock()
        private var listed = 0

        /// How many listings were asked for.
        var listings: Int { lock.withLock { listed } }

        init(depth: Int) { self.depth = depth }

        func list(_ directory: URL, showHidden _: Bool) -> [FileItem] {
            lock.withLock { listed += 1 }
            let level = directory.pathComponents.count - 1
            var items = [FileItem(url: directory.appendingPathComponent("f"), name: "f", isDirectory: false, size: 3)]
            if isEndless {
                items.append(FileItem(url: directory, name: "d", isDirectory: true))
            } else if level < depth {
                items.append(FileItem(url: directory.appendingPathComponent("d"), name: "d", isDirectory: true))
            }
            return items
        }

        func parent(of directory: URL) -> URL? {
            directory.pathComponents.count > 1 ? directory.deletingLastPathComponent() : nil
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The size of `tree`, worked out on a thread with the small stack the pool's threads used
    /// to have; nil when it did not finish.
    private static func size(of tree: DeepFileSystem) -> Int64? {
        let top = URL(string: "deep:///")
        return OtherThread.result(stackSize: 512 << 10) { top.map { tree.totalSize(of: $0) } }.flatMap(\.self)
    }

    /// Shallow and deep real trees are counted to the last level; a hostile tree of twenty
    /// thousand levels is walked to the limit, and a folder inside itself is listed a bounded
    /// number of times.
    @Test
    internal func aTreeDeeperThanAnyStackIsMeasuredToTheDepthNoRealTreeHas() throws {
        // Shallow: every level counted, by calls that nest.
        #expect(Self.size(of: DeepFileSystem(depth: 20)) == Int64(3 * 21))
        // Deeper than the nesting allows, and still a real tree: every level counted.
        #expect(Self.size(of: DeepFileSystem(depth: 600)) == Int64(3 * 601))
        // Twenty thousand levels crashed the program; now the walk ends at its limit.
        let size = try #require(Self.size(of: DeepFileSystem(depth: 20_000)))
        #expect(size >= 3 * Int64(TreeWalk.deepestTree))
        #expect(size <= 3 * Int64(TreeWalk.deepestTree + TreeWalk.deepestNesting * 80))
        // A folder inside itself is listed once per level it seems to have, not for ever.
        let endless = DeepFileSystem(depth: 0)
        endless.isEndless = true
        #expect(Self.size(of: endless) != nil)
        #expect(endless.listings < 200)
    }

    /// A flag set before the walk gives nothing and lists nothing.
    @Test
    internal func cancellingEndsTheWalkWithNothing() throws {
        let top = try #require(URL(string: "deep:///"))
        let tree = DeepFileSystem(depth: 500)
        let cancellation = CancellationFlag()
        cancellation.cancel()
        #expect(tree.totalSize(of: top, cancellation: cancellation) == 0 && tree.listings == 0)
        #expect(TreeWalk.nesting == 0)
    }
}
