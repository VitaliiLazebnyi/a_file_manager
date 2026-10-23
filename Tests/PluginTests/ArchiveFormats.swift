import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Packing, listing and unpacking every archive format the program writes, and back.
@Suite
internal struct ArchiveFormats {
    /// The archive file systems and the sandbox of the test.
    internal let bench: ArchiveBench
    /// The test's own folder on the local disk.
    internal var box: Sandbox { bench.box }

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// Packing a tree, listing the archive and unpacking it gives back the same bytes, permissions and dates in every
    /// format that can be written.
    @Test(arguments: [ArchiveFormat.zip, .tar, .compressedTar(.gzip), .compressedTar(.bzip2), .compressedTar(.xzStream)]
    )
    internal func packListUnpackGivesTheSameBytes(format: ArchiveFormat) throws {
        let tree = try bench.makeTree()
        let archive = box.url("out/tree." + format.defaultExtension)
        let result = try bench.pack([tree], to: archive) { $0.format = format }
        #expect(result.archives == [archive] && result.completed == [tree])
        // No temporary file stays next to the archive.
        #expect(namesOnDisk(box.url("out")) == [archive.lastPathComponent])

        let opened = try bench.store.archive(at: archive, cancellation: nil)
        #expect(opened.format == format)
        let root = bench.inside(
            archive,
            scheme: format == .zip ? ArchiveURL.writableScheme : ArchiveURL.readOnlyScheme
        )
        #expect(try bench.names(root) == ["tree"])
        #expect(
            try bench.names(root.appending(name: "tree")) == ["big.log", "empty.txt", "hollow", "readme.txt", "sub"]
        )
        #expect(
            try bench.names(root.appending(name: "tree").appending(name: "sub"), showHidden: false) == [
                "deep", "random.bin"
            ]
        )
        let readme = try bench.item(root.appending(name: "tree").appending(name: "readme.txt"))
        #expect(
            readme.size == 17_600 && readme.permissions == 0o755
                && readme.modified == Date(timeIntervalSince1970: 1_600_000_000)
        )
        #expect(
            try bench.read(readme.url)
                == FileManager.default.contents(atPath: tree.appendingPathComponent("readme.txt").path)
        )

        let unpacked = try bench.unpack(archive, to: box.url("back"))
        #expect(unpacked.problems.isEmpty && !unpacked.cancelled)
        let (original, copy) = (snapshot(tree), snapshot(box.url("back/tree")))
        #expect(original.count == 7 && original == copy)
        let attributes = try FileManager.default.attributesOfItem(atPath: box.url("back/tree/readme.txt").path)
        #expect(attributes[.posixPermissions] as? Int == 0o755)
        #expect(attributes[.modificationDate] as? Date == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(ArchiveTester.test(opened, cancellation: CancellationFlag(), counter: nil, members: .all).isEmpty)
    }

    /// A single file compressed with gzip, bzip2 or xz is shown as a folder holding that file and unpacks to the same
    /// bytes; a folder cannot be packed so.
    @Test(arguments: [ArchiveFormat.Codec.gzip, .bzip2, .xzStream])
    internal func singleCompressedFilesRoundTrip(codec: ArchiveFormat.Codec) throws {
        let tree = try bench.makeTree()
        let source = tree.appendingPathComponent("big.log")
        let format = ArchiveFormat.compressedFile(codec)
        let archive = box.url("big.log." + format.defaultExtension)
        try bench.pack([source], to: archive) { $0.format = format }
        let original = try Data(contentsOf: source)
        #expect(try Data(contentsOf: archive).count < original.count / 4)

        // It is shown as a folder holding the one file, at its unpacked size.
        let root = bench.inside(archive, scheme: ArchiveURL.readOnlyScheme)
        let items = try bench.readOnly.list(root, showHidden: true)
        #expect(items.map(\.name) == ["big.log"] && items.first?.size == Int64(original.count))
        #expect(try bench.read(root.appending(name: "big.log")) == original)
        try bench.unpack(archive, to: box.url("back"))
        #expect(try Data(contentsOf: box.url("back/big.log")) == original)

        // A folder does not fit into such a file.
        #expect(throws: ArchiveError.self) {
            try bench.pack([tree], to: box.url("tree." + format.defaultExtension)) { $0.format = format }
        }
        #expect(!box.exists("tree." + format.defaultExtension))
    }

    /// A compressed archive larger than the materialising limit is read by streaming from its start, seeking included,
    /// and unpacked in one pass.
    @Test
    internal func aLargeArchiveIsStreamedInsteadOfUnpackedToATemporaryFile() throws {
        let tree = try bench.makeTree()
        let archive = box.url("tree.tar.gz")
        try bench.pack([tree], to: archive) { $0.format = .compressedTar(.gzip) }
        // Nothing may be kept in a temporary copy: every read decompresses from the start.
        bench.environment.materializeLimit = 0
        let opened = try bench.store.archive(at: archive, cancellation: nil)
        #expect(!opened.allowsParallelReads)
        let root = bench.inside(archive, "tree", scheme: ArchiveURL.readOnlyScheme)
        #expect(
            try bench.read(root.appending(name: "big.log")) == Data(contentsOf: tree.appendingPathComponent("big.log"))
        )
        let reader = try bench.readOnly.read(root.appending(name: "readme.txt"))
        try reader.seek(to: 44)
        #expect(try reader.read(upToCount: 8).flatMap { String(bytes: $0, encoding: .utf8) } == "All work")
        try reader.seek(to: 4)
        #expect(try reader.read(upToCount: 4).flatMap { String(bytes: $0, encoding: .utf8) } == "work")
        reader.close()
        // Unpacking takes one pass, and so does the test.
        let unpacked = try bench.unpack(archive, to: box.url("back"))
        #expect(unpacked.problems.isEmpty && snapshot(box.url("back/tree")) == snapshot(tree))
        #expect(ArchiveTester.test(opened, cancellation: CancellationFlag(), counter: nil, members: .all).isEmpty)

        let single = box.url("big.log.gz")
        try bench.pack([tree.appendingPathComponent("big.log")], to: single) { $0.format = .compressedFile(.gzip) }
        let item = try bench.item(bench.inside(single, "big.log", scheme: ArchiveURL.readOnlyScheme))
        #expect(item.size == Int64(try Data(contentsOf: tree.appendingPathComponent("big.log")).count))
        #expect(try bench.read(item.url) == Data(contentsOf: tree.appendingPathComponent("big.log")))
    }
}
