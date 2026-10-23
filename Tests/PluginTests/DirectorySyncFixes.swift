import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import DirectorySyncPlugin

/// The fixes of the directory comparison and its session.
@Suite
internal struct DirectorySyncFixes {
    /// The local file system and the one in memory.
    internal let fileSystems = FileSystemRegistry()
    /// The file system in memory.
    internal let memory = MemoryFileSystem()
    /// A date in the past the files carry.
    internal let early = Date(timeIntervalSince1970: 1_000_000)

    /// Both file systems registered.
    internal init() {
        fileSystems.register(LocalFileSystem())
        fileSystems.register(memory)
    }

    /// An item of one byte named `name` in memory, made without the file system.
    internal func file(_ name: String) -> FileItem {
        FileItem(url: memory.url("/" + name), name: name, stat: .init(size: 1, modified: early))
    }

    /// Several names that fold alike pair in order, the rest stay alone, and many pair quickly.
    @Test
    internal func caseInsensitivePairingKeepsItsOrderAndIsFast() {
        // Several names that fold alike pair in order; the rest stays alone.
        let left = ["ab", "AB", "c"].map(file)
        let right = ["Ab", "aB", "d"].map(file)
        let pairs = SyncComparison.pair(left, right)
        #expect(
            pairs.map { pair in "\(pair.left?.name ?? "-")/\(pair.right?.name ?? "-")" }
                == ["ab/Ab", "AB/aB", "c/-", "-/d"]
        )

        let many = 20_000
        let big = SyncComparison.pair(
            (0..<many).map { index in file("L\(index)") },
            (0..<many).map { index in file("l\(index)") }
        )
        #expect(big.count == many && big.allSatisfy { pair in pair.left != nil && pair.right != nil })
    }

    /// Dates that differ by less than a second count as the same.
    @Test
    internal func subSecondDifferencesAreNotDifferences() {
        var options = SyncOptions()
        options.toleranceSeconds = 0
        let apfs = FileItem(
            url: memory.url("/a"),
            name: "a",
            stat: .init(size: 1, modified: early.addingTimeInterval(0.789))
        )
        let fat = FileItem(url: memory.url("/a"), name: "a", stat: .init(size: 1, modified: early))
        #expect(SyncComparison.classify(left: apfs, right: fat, options: options).state == .equal)
        let later = FileItem(
            url: memory.url("/a"),
            name: "a",
            stat: .init(size: 1, modified: early.addingTimeInterval(1.5))
        )
        #expect(SyncComparison.classify(left: later, right: fat, options: options).state == .leftNewer)
    }

    /// A link facing a file is shown but never acted on, and a link alone is left out.
    @Test
    internal func aLinkFacingAFileIsNeverActedOn() throws {
        let box = try Sandbox()
        try box.folder("L")
        try box.folder("R")
        try Data("x".utf8).write(to: box.url("L/a.txt"))
        try Data("y".utf8).write(to: box.url("R/target.txt"))
        try FileManager.default.createSymbolicLink(at: box.url("R/a.txt"), withDestinationURL: box.url("R/target.txt"))
        try FileManager.default.createSymbolicLink(
            at: box.url("L/lonely"),
            withDestinationURL: box.url("R/target.txt")
        )
        let result = SyncComparison(options: SyncOptions(), fileSystems: fileSystems)
            .run(
                left: box.url("L"),
                right: box.url("R")
            )
        let row = try #require(result.rows.first { row in row.name == "a.txt" })
        #expect(row.state == .excluded && row.action == .nothing && !row.accepts(.copyToRight))
        #expect(
            result.rows.contains { row in row.name == "target.txt" }
                && !result.rows.contains { row in row.name == "lonely" }
        )
        #expect(SyncPlan(rows: result.rows).toRight.isEmpty)
    }
}
