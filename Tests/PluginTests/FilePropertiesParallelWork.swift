import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FilePropertiesPlugin

/// Measuring, the columns, comments and attribute changes over many files at once, on all cores.
@Suite
internal struct FilePropertiesParallelWork {
    /// The local file system and `memory`.
    private let fileSystems: FileSystemRegistry
    /// A file system in memory, `mem:`.
    private let memory: MemoryFileSystem

    /// Both file systems, empty.
    internal init() {
        (fileSystems, memory) = makeFileSystems()
    }

    /// A tree is measured on all cores: files, folders, bytes, rounded sizes and unreadable folders.
    @Test
    internal func measuresATreeOnAllCores() throws {
        for folder in 0..<40 {
            for file in 0..<25 {
                memory.addFile("/tree/d\(folder)/sub\(file % 3)/f\(file).bin", String(repeating: "x", count: file))
            }
        }
        memory.addFile("/tree/top.bin", "12345")
        memory.addDirectory("/tree/empty")
        memory.unreadable = ["/tree/d0/sub0"]
        let tree = try #require(memory.item(at: memory.url("/tree")))
        let top = try #require(memory.item(at: memory.url("/tree/top.bin")))
        let totals = SpaceCalculator(fileSystems: fileSystems, targetCluster: 16).measure([tree, top])
        // 40 folders × 3 subfolders, the empty one and the tree itself.
        #expect(totals[0].folders == 40 * 4 + 2 && totals[0].unreadable == 1)
        let unreadableFiles = Array(stride(from: 0, to: 25, by: 3))
        #expect(totals[0].files == 40 * 25 + 1 - unreadableFiles.count)
        let allBytes: Int = 40 * (0..<25).reduce(0, +) + 5
        let expectedBytes: Int = allBytes - unreadableFiles.reduce(0, +)
        #expect(totals[0].bytes == Int64(expectedBytes))
        #expect(
            totals[0].allocated == totals[0].bytes && totals[0].rounded >= totals[0].bytes
                && totals[0].rounded.isMultiple(of: 16)
        )
        #expect(totals[1] == SpaceTotals(bytes: 5, allocated: 5, rounded: 16, files: 1))
        // A cancelled calculation stops descending.
        let cancelled = CancellationFlag()
        cancelled.cancel()
        #expect(
            SpaceCalculator(fileSystems: fileSystems, cancellation: cancelled).measure(directory: memory.url("/tree"))
                == SpaceTotals()
        )
    }

    /// On the local disk the space allocated is measured too, and a link is counted, not followed.
    @Test
    internal func measuresRealAllocationOnTheLocalDisk() throws {
        let box = try Sandbox()
        try box.file("a/one.txt", String(repeating: "x", count: 5_000))
        try box.file("a/deep/two.txt", "2")
        try FileManager.default.createSymbolicLink(
            atPath: box.url("a/link").path,
            withDestinationPath: box.url("a/deep").path
        )
        let folder = try #require(fileSystems.item(at: box.url("a")))
        let totals =
            SpaceCalculator(fileSystems: fileSystems, targetCluster: LocalInfo.clusterSize(at: box.root))
            .measure([folder])[0]
        // The link is counted as a link, not followed.
        #expect(totals.files == 3 && totals.folders == 2 && totals.bytes == 5_001)
        #expect(totals.allocated >= 5_001 && totals.rounded >= 5_001 && totals.rounded.isMultiple(of: 512))
    }

    /// Every column answers for every item from many threads at once.
    @Test
    internal func columnsAnswerFromManyThreadsAtOnce() throws {
        let box = try Sandbox()
        for index in 0..<60 { try box.file("f\(index).txt", String(repeating: "y", count: index)) }
        try box.file("descript.ion", (0..<60).map { "f\($0).txt comment \($0)\r\n" }.joined())
        try FileManager.default.createSymbolicLink(atPath: box.url("link").path, withDestinationPath: "f1.txt")
        memory.addFile("/m/a.png", "x")
        memory.addFile("/m/descript.ion", "a.png a picture\r\n")
        let columns = ColumnRegistry()
        PropertyColumns.register(in: columns, comments: CommentStore(fileSystems: fileSystems))
        #expect(
            columns.all.map(\.id) == [
                "comment", "owner", "group", "created", "accessed", "octal", "linkTarget", "kind", "tags", "xattrCount",
                "sizeOnDisk"
            ]
        )
        let items =
            try fileSystems.provider(for: box.root).list(box.root, showHidden: true)
            + memory.list(memory.url("/m"), showHidden: true)
        // Every column for every item, all at once, as a panel asks.
        let cells = Parallel.map(items.flatMap { item in columns.all.map { (item, $0) } }) { item, column in
            (item.name, column.id, column.value(item))
        }
        func cell(_ name: String, _ column: String) -> String? { cells.first { $0.0 == name && $0.1 == column }?.2 }
        #expect(
            cell("f7.txt", "comment") == "comment 7" && cell("a.png", "comment") == "a picture"
                && cell("link", "comment")?.isEmpty == true
        )
        #expect(cell("f7.txt", "owner") == NSUserName() && cell("a.png", "owner")?.isEmpty == true)
        #expect(
            cell("f7.txt", "group")?.isEmpty == false && cell("f7.txt", "created")?.isEmpty == false
                && cell("f7.txt", "accessed")?.isEmpty == false
        )
        #expect(cell("f7.txt", "octal") == "644" && cell("a.png", "octal") == "644")
        #expect(cell("link", "linkTarget") == "f1.txt" && cell("f7.txt", "linkTarget")?.isEmpty == true)
        #expect(cell("f7.txt", "kind")?.isEmpty == false && cell("a.png", "kind")?.isEmpty == false)
        #expect(cell("f7.txt", "tags")?.isEmpty == true && cell("a.png", "xattrCount")?.isEmpty == true)
        let onDisk: String = cell("f59.txt", "sizeOnDisk") ?? ""
        let allocated: Int64 = Int64(onDisk.replacingOccurrences(of: ",", with: "")) ?? -1
        #expect(allocated >= 59)
    }

    /// The comment store reads a folder's comment file once for many readers, and writes changes through.
    @Test
    internal func commentStoreReadsAFolderOnceForManyReaders() throws {
        memory.addFile("/c/descript.ion", "a.txt first\r\nb.txt second\r\n")
        let store = CommentStore(fileSystems: fileSystems)
        let answers = Parallel.map(Array(0..<200)) { index in
            store.comments(in: memory.url("/c"))[index.isMultiple(of: 2) ? "a.txt" : "b.txt"]
        }
        #expect(answers.filter { $0 == "first" }.count == 100 && answers.filter { $0 == "second" }.count == 100)
        // A change made through the store is seen at once; the file disappears with its last comment.
        try store.setComment("changed", for: "A.TXT", in: memory.url("/c"), hidden: true)
        #expect(store.comments(in: memory.url("/c"))["a.txt"] == "changed")
        #expect(memory.contents("/c/descript.ion") == "a.txt changed\r\nb.txt second\r\n")
        try store.setComment("", for: "a.txt", in: memory.url("/c"), hidden: true)
        try store.setComment("", for: "b.txt", in: memory.url("/c"), hidden: true)
        #expect(!memory.exists("/c/descript.ion") && memory.allPaths == ["/c"])
    }

    /// Attributes of a whole tree change on all cores, even when a folder's own permissions are taken away.
    @Test
    internal func changesAttributesOfATreeOnAllCores() throws {
        let box = try Sandbox()
        for folder in 0..<8 {
            for file in 0..<100 { try box.file("t/d\(folder)/f\(file).txt") }
        }
        let tree = try #require(fileSystems.item(at: box.url("t")))
        var change = AttributeChange()
        change.permissions = try #require(PermissionChange("go-r"))
        change.timestamp = TimestampChange(date: "2001-02-03", time: "04:05:06")
        change.recurse = true
        let outcome = AttributeJob(change: change, fileSystems: fileSystems).run([tree])
        #expect(outcome.changed == 8 * 100 + 8 + 1 && outcome.failed == 0 && !outcome.cancelled)
        let file = try #require(fileSystems.item(at: box.url("t/d3/f42.txt")))
        #expect(file.permissions == 0o600 && TimestampChange.fieldTexts(for: file.modified).date == "2001-02-03")
        #expect(fileSystems.item(at: box.url("t/d3"))?.permissions == 0o711)

        // Taking a folder's own permissions away does not lock the job out of its contents…
        change = AttributeChange(permissions: try #require(PermissionChange("000")), recurse: true)
        #expect(AttributeJob(change: change, fileSystems: fileSystems).run([tree]).failed == 0)
        // …and giving them back opens the folders on the way down.
        change.permissions = try #require(PermissionChange("u+rwX"))
        let restored = AttributeJob(change: change, fileSystems: fileSystems).run([tree])
        #expect(restored.failed == 0 && restored.changed == 809)
        #expect(
            fileSystems.item(at: box.url("t/d3/f42.txt"))?.permissions == 0o600
                && fileSystems.item(at: box.url("t/d3"))?.permissions == 0o700
        )
    }
}
