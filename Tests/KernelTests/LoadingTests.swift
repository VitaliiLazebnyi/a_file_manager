import AFMKernel
import Foundation
import TestSupport
import Testing

/// Reading what a panel is asked to show: the folder of a file, missing folders, batches,
/// empty folders and the size of a tree.
@Suite
internal struct LoadingTests {
    /// The file system that holds `/work` with three files and `docs/report.txt`.
    private let memory = MemoryFileSystem()
    /// The registry the listings are read through.
    private let fileSystems = FileSystemRegistry()

    /// Fills the file system.
    internal init() {
        memory.addFile("/work/docs/report.txt")
        memory.addFile("/work/a.txt")
        memory.addFile("/work/b.txt")
        memory.addFile("/work/c.txt")
        fileSystems.register(memory)
    }

    /// Checks that the location of a file lists its folder with the file as the focus, and
    /// the parent and root of that folder.
    @Test
    internal func aFileLeadsToItsFolder() throws {
        let result = try PanelLoader.load(
            memory.url("/work/docs/report.txt"),
            showHidden: false,
            fileSystems: fileSystems
        )
        #expect(result.listing.directory.path == "/work/docs" && result.focus == "report.txt")
        #expect(result.listing.parent?.path == "/work" && result.listing.root.path == "/")
    }

    /// A missing folder fails, unless the loader may climb to the nearest folder above; a
    /// scheme nobody handles fails with a file system error.
    @Test
    internal func aMissingFolderFailsUnlessClimbing() throws {
        #expect(throws: (any Error).self) {
            try PanelLoader.load(memory.url("/work/gone/deeper"), showHidden: false, fileSystems: fileSystems)
        }
        let climbed = try PanelLoader.load(
            memory.url("/work/gone/deeper"),
            showHidden: false,
            fileSystems: fileSystems,
            climbing: true
        )
        #expect(climbed.listing.directory.path == "/work")
        let nowhere = try #require(URL(string: "ftp://nowhere/x"))
        #expect(throws: FileSystemError.self) {
            try PanelLoader.load(nowhere, showHidden: false, fileSystems: fileSystems)
        }
    }

    /// A slow directory arrives in batches, the first marked as such, each with the folder's
    /// parent; the whole listing is the batches put together.
    @Test
    internal func aSlowDirectoryArrivesInBatches() throws {
        memory.listBatchSize = 2
        var batches: [PanelLoader.Batch] = []
        try PanelLoader.stream(memory.url("/work"), showHidden: false, fileSystems: fileSystems) { batch in
            batches.append(batch)
            return true
        }
        #expect(batches.map(\.listing.items.count) == [2, 2])
        #expect(batches.map(\.isFirst) == [true, false])
        #expect(batches.allSatisfy { $0.listing.directory.path == "/work" && $0.listing.parent?.path == "/" })
        let whole = try PanelLoader.load(memory.url("/work"), showHidden: false, fileSystems: fileSystems)
        #expect(whole.listing.items.count == 4)
    }

    /// Checks that no batch comes after the receiver said it wants no more.
    @Test
    internal func streamingStopsWhenNoMoreIsWanted() throws {
        memory.listBatchSize = 1
        var count = 0
        try PanelLoader.stream(memory.url("/work"), showHidden: false, fileSystems: fileSystems) { _ in
            count += 1
            return count < 2
        }
        #expect(count == 2)
    }

    /// Checks that an empty folder still gives one, empty, batch.
    @Test
    internal func anEmptyDirectoryStillGivesOneBatch() throws {
        memory.addDirectory("/empty")
        var batches = 0
        try PanelLoader.stream(memory.url("/empty"), showHidden: false, fileSystems: fileSystems) { batch in
            batches += 1
            return batch.listing.items.isEmpty
        }
        #expect(batches == 1)
    }

    /// Checks that the size of a folder adds up the files of the whole tree, and is 0 when the
    /// work is cancelled.
    @Test
    internal func directorySizeIsAddedUpOverTheTree() {
        memory.addFile("/big/a/one.txt", String(repeating: "a", count: 100))
        memory.addFile("/big/a/deep/two.txt", String(repeating: "b", count: 50))
        memory.addFile("/big/b/three.txt", String(repeating: "c", count: 7))
        memory.addFile("/big/top.txt", String(repeating: "d", count: 3))
        #expect(memory.totalSize(of: memory.url("/big"), cancellation: CancellationFlag()) == 160)
        let cancelled = CancellationFlag()
        cancelled.cancel()
        #expect(memory.totalSize(of: memory.url("/big"), cancellation: cancelled) == 0)
    }
}
