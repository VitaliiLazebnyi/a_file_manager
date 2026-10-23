import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport

@testable import DirectorySyncPlugin

/// Two trees in memory, `/L` and `/R`, compared through the local and the memory file system.
internal struct SyncTreeFixture {
    /// The date most files are dated.
    internal static let early = Date(timeIntervalSince1970: 1_000_000)

    /// The local and the memory file system.
    internal let fileSystems = FileSystemRegistry()
    /// The trees.
    internal let memory = MemoryFileSystem()

    /// Empty trees.
    internal init() {
        fileSystems.register(LocalFileSystem())
        fileSystems.register(memory)
    }

    /// The rows as short texts: `sub/name state action`.
    internal static func describe(_ rows: [SyncRow]) -> [String] {
        rows.map { row in "\(row.relativePath)\(row.isDirectory ? "/" : "") \(row.state) \(row.action)" }
    }

    /// One file of every kind the comparison tells apart.
    internal func makeTree() {
        memory.addFile("/L/equal.txt", "same", modified: Self.early)
        memory.addFile("/R/equal.txt", "same", modified: Self.early)
        memory.addFile("/L/left.txt", "only here")
        memory.addFile("/R/right.txt", "only there")
        memory.addFile("/L/newer-left.txt", "new", modified: Self.early.addingTimeInterval(60))
        memory.addFile("/R/newer-left.txt", "old", modified: Self.early)
        memory.addFile("/L/newer-right.txt", "old", modified: Self.early)
        memory.addFile("/R/newer-right.txt", "newer", modified: Self.early.addingTimeInterval(60))
        memory.addFile("/L/size.txt", "short", modified: Self.early)
        memory.addFile("/R/size.txt", "much longer", modified: Self.early)
        memory.addFile("/L/twin.txt", "aaaa", modified: Self.early)
        memory.addFile("/R/twin.txt", "bbbb", modified: Self.early)
        memory.addFile("/L/sub/deep/inner.txt", "x", modified: Self.early)
        memory.addFile("/R/sub/deep/inner.txt", "x", modified: Self.early)
        memory.addFile("/L/sub/only-left.txt", "x")
        memory.addFile("/R/other/only-right.txt", "x")
    }

    /// Compares `/L` with `/R` by the usual options.
    internal func compare() -> SyncResult {
        compare("/L", "/R") { _ in
            // The usual options.
        }
    }

    /// Compares `/L` with `/R` by the options `configure` makes.
    internal func compare(_ configure: (inout SyncOptions) -> Void) -> SyncResult {
        compare("/L", "/R", configure)
    }

    /// Compares two folders of the memory file system by the options `configure` makes.
    internal func compare(_ left: String, _ right: String, _ configure: (inout SyncOptions) -> Void) -> SyncResult {
        var options = SyncOptions()
        configure(&options)
        return SyncComparison(options: options, fileSystems: fileSystems)
            .run(left: memory.url(left), right: memory.url(right))
    }
}
