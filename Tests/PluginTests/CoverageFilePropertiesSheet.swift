import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FilePropertiesPlugin

/// The rows of the Properties dialog beyond the other suites: flags, hard links, links and
/// aliases, tags, measurements that were stopped or met unreadable folders, and summaries.
@Suite
internal struct CoverageFilePropertiesSheet {
    /// The files in memory: `/T` with a file and a folder that cannot be read.
    private let memory = MemoryFileSystem()
    /// The local file system and the memory files.
    private let fileSystems = FileSystemRegistry()
    /// The files on the disk.
    private let box: Sandbox

    /// A sheet without a flag of its own.
    private var sheet: PropertySheet {
        PropertySheet(fileSystems: fileSystems, comments: CommentStore(fileSystems: fileSystems))
    }

    /// The files and the registry.
    internal init() throws {
        memory.addFile("/T/a.txt", "a")
        memory.addFile("/T/locked/b.txt", "b")
        memory.unreadable = ["/T/locked"]
        fileSystems.register(LocalFileSystem())
        fileSystems.register(memory)
        box = try Sandbox()
    }

    /// The value of the row with `label`.
    private func value(_ label: String, in rows: [PropertyRow]) -> String? {
        rows.first { $0.label == label }?.value
    }

    /// The item of a local path in the sandbox.
    private func local(_ path: String) throws -> FileItem {
        try #require(fileSystems.item(at: box.url(path)))
    }

    /// A folder with one that cannot be read says so; a stopped measurement says that.
    @Test
    internal func measurementsThatMetUnreadableFoldersOrWereStopped() throws {
        let folder = try #require(memory.item(at: memory.url("/T")))
        #expect(value("Size", in: sheet.rows(for: folder)) == "1 bytes (1 folder(s) unreadable)")
        let stopped = CancellationFlag()
        stopped.cancel()
        let cut = PropertySheet(
            fileSystems: fileSystems,
            comments: CommentStore(fileSystems: fileSystems),
            cancellation: stopped
        )
        #expect(value("Size", in: cut.rows(for: folder))?.hasSuffix("(stopped; incomplete)") == true)
        let file = try #require(memory.item(at: memory.url("/T/a.txt")))
        #expect(value("Size", in: cut.rows(forSeveral: [file, folder]))?.hasSuffix("(stopped; incomplete)") == true)
    }

    /// Flags, hard links, links and tags of local items are shown.
    @Test
    internal func flagsHardLinksLinksAndTags() throws {
        try box.file("f.txt", "f")
        try LocalInfo.setFlag(UInt32(UF_HIDDEN), true, of: box.url("f.txt"))
        _ = link(box.url("f.txt").path, box.url("hard.txt").path)
        // Finder keeps its tags in an extended attribute, as a property list of names.
        let tags = try PropertyListSerialization.data(fromPropertyList: ["Red"], format: .binary, options: 0)
        let written = tags.withUnsafeBytes { bytes in
            setxattr(box.url("f.txt").path, "com.apple.metadata:_kMDItemUserTags", bytes.baseAddress, bytes.count, 0, 0)
        }
        #expect(written == 0)
        try FileManager.default.createSymbolicLink(atPath: box.url("sym").path, withDestinationPath: "f.txt")
        try LinkMaker.create(.alias, to: box.url("f.txt"), at: box.url("alias"), relative: false)
        let rows = sheet.rows(for: try local("f.txt"))
        #expect(value("Flags", in: rows) == "Hidden" && value("Hard links", in: rows) == "2")
        #expect(value("Tags", in: rows) == "Red")
        #expect(value("Link target", in: sheet.rows(for: try local("sym"))) == "f.txt")
        let original = value("Alias of", in: sheet.rows(for: try local("alias")))
        #expect(
            original.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                == box.url("f.txt").resolvingSymlinksInPath().path
        )
    }

    /// A summary of more than four items ends in an ellipsis; items of one date and mode show
    /// that date and mode.
    @Test
    internal func summariesOfManyAlikeItems() throws {
        let time = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<5 { memory.addFile("/S/f\(index).txt", "x", modified: time, permissions: 0o600) }
        let items = try (0..<5).map { try #require(memory.item(at: memory.url("/S/f\($0).txt"))) }
        let rows = sheet.rows(forSeveral: items)
        #expect(value("Items", in: rows)?.hasSuffix(", …") == true)
        #expect(value("Modified", in: rows) == PropertyText.longDate(time))
        #expect(value("Permissions", in: rows) == "rw------- (600)")
    }

    /// An item of no file system has no volume to show.
    @Test
    internal func anItemOfNoFileSystemHasNoVolume() throws {
        let stray = FileItem(url: try #require(URL(string: "zzz:/x.txt")), name: "x.txt")
        let rows = sheet.rows(for: stray)
        #expect(value("Volume", in: rows) == nil && value("Name", in: rows) == "x.txt")
    }
}
