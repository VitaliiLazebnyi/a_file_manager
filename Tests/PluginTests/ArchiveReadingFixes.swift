import AFMKernel
import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Sizes without unpacking, one pass for many members, and the same results faster.
@Suite
internal struct ArchiveReadingFixes: ArchiveFixSuite {
    /// The archive file systems and the sandbox of the test.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// The unpacked size of a compressed file is read from its end, and what is not a real index or too small to be
    /// true
    /// is treated so.
    @Test
    internal func theSizeOfACompressedFileIsReadFromItsEnd() throws {
        let tree = try bench.makeTree()
        let source = tree.appendingPathComponent("big.log")
        let size = try Data(contentsOf: source).count
        bench.environment.materializeLimit = 0
        for codec in [ArchiveFormat.Codec.gzip, .xzStream, .bzip2] {
            let archive = box.url("big.log." + ArchiveFormat.suffix(codec))
            try bench.pack([source], to: archive) { $0.format = .compressedFile(codec) }
            let opened = try bench.store.archive(at: archive, cancellation: nil)
            let entry = try #require(opened.entries.first)
            #expect(entry.size == Int64(size) && entry.sizeIsExact == (codec != .gzip), "\(codec)")
            #expect(ArchiveTester.test(opened, cancellation: CancellationFlag(), counter: nil, members: .all).isEmpty)
        }
        // Several streams in a row with padding between them, as parallel compressors write.
        let parts = [Data(repeating: 1, count: 70_000), Data(), Data(repeating: 2, count: 300)]
        var joined = Data()
        for part in parts {
            joined.append(try XZCoder.compress(part))
            joined.append(Data(count: 8))
        }
        try joined.write(to: box.url("joined.xz"))
        #expect(try CompressedSize.ofXZ(RandomAccessFile(box.url("joined.xz"), shownAs: nil)) == 70_300)
        let stream = try XZStream(
            FileRangeStream(RandomAccessFile(box.url("joined.xz"), shownAs: nil), offset: 0, length: nil),
            control: nil
        )
        #expect(try stream.readFully(1 << 20) == parts.reduce(Data(), +))
        // Anything that is not an index is "unknown", whatever it claims.
        for cut in [1, 5, 13, 40] {
            try joined.dropLast(cut).write(to: box.url("cut.xz"))
            #expect(try CompressedSize.ofXZ(RandomAccessFile(box.url("cut.xz"), shownAs: nil)) == nil)
        }
        var forged = joined
        forged.replaceSubrange(forged.count - 16..<forged.count - 12, with: [0xFF, 0xFF, 0xFF, 0x7F])
        try forged.write(to: box.url("forged.xz"))
        #expect(try CompressedSize.ofXZ(RandomAccessFile(box.url("forged.xz"), shownAs: nil)) == nil)
        // What a file says that is too small to be true is raised by the steps it lost.
        let gzipped = box.url("big.log.gz")
        var bytes = try Data(contentsOf: gzipped)
        #expect(try CompressedSize.claimedByGzip(RandomAccessFile(gzipped, shownAs: nil)) == UInt64(size))
        bytes.replaceSubrange(bytes.count - 4..<bytes.count, with: [5, 0, 0, 0])
        try bytes.write(to: gzipped)
        #expect(try CompressedSize.claimedByGzip(RandomAccessFile(gzipped, shownAs: nil)) == 5 + 1 << 32)
    }

    /// Members of a compressed TAR read one after the other in archive order cost one pass of decompression.
    @Test
    internal func membersOfAStreamReadOneAfterTheOtherCostOnePass() throws {
        let tree = try bench.makeTree()
        let archive = box.url("tree.tar.gz")
        try bench.pack([tree], to: archive) { $0.format = .compressedTar(.gzip) }
        bench.environment.materializeLimit = 0
        let opened = try bench.store.archive(at: archive, cancellation: nil)
        let files = opened.entries.filter { !$0.isDirectory }
        #expect(files.count == 6 && opened.streamStarts == 0)
        // In archive order, as a copy job reads them.
        for entry in files {
            let stream = try opened.open(entry, slot: nil)
            let data = try stream.readFully(1 << 24)
            stream.close()
            #expect(data == (try Data(contentsOf: box.url(entry.path))), "\(entry.path)")
        }
        #expect(opened.streamStarts == 1)
        // A member that lies behind the reader starts a new pass; one left half read does not hurt.
        let half = try opened.open(files[2], slot: nil)
        _ = try half.read(upToCount: 10)
        half.close()
        #expect(try opened.open(files[4], slot: nil).readFully(1 << 24) == Data(contentsOf: box.url(files[4].path)))
        #expect(opened.streamStarts == 2)
        // The copy job gets every file right this way.
        try box.folder("out")
        let root = bench.inside(archive, "tree", scheme: ArchiveURL.readOnlyScheme)
        let result = runJob(.copy, [root], to: TargetSpec(directory: box.url("out")), fileSystems: bench.fileSystems)
        #expect(result.completed.count == 1 && snapshot(box.url("out/tree")) == snapshot(tree))
    }

    /// A member of an uncompressed TAR is read at any place, past its end included.
    @Test
    internal func aMemberThatLiesInAFileIsReadAtAnyPlace() throws {
        let tree = try bench.makeTree()
        let archive = box.url("tree.tar")
        try bench.pack([tree], to: archive) { $0.format = .tar }
        let expected = try Data(contentsOf: tree.appendingPathComponent("big.log"))
        let reader = try bench.readOnly.read(bench.inside(archive, "tree/big.log", scheme: ArchiveURL.readOnlyScheme))
        for offset in [5_000_000, 44, 0, expected.count - 3, expected.count + 10, 1_000_000] {
            try reader.seek(to: UInt64(offset))
            let wanted =
                offset < expected.count ? expected.subdata(in: offset..<min(offset + 100, expected.count)) : nil
            #expect(try reader.read(upToCount: 100) == wanted, "\(offset)")
        }
        reader.close()
    }
    /// The tree of an archive keeps the order of its members and makes up their folders, through every change.
    @Test
    internal func theTreeKeepsItsOrderAndItsFolders() {
        var tree = ArchiveTree()
        let paths = ["a/b/c/one.txt", "a/b/c/two.txt", "a/b/three.txt", "x.txt", "a/b/c/d/e/four.txt", "a/z.txt"]
        for path in paths { tree.insert(ArchiveEntry(path: path, isDirectory: false), keepingOrder: false) }
        #expect(tree.ordered.filter { !$0.isDirectory }.map(\.path) == paths)
        #expect(Set(tree.ordered.filter(\.isImplicit).map(\.path)) == ["a", "a/b", "a/b/c", "a/b/c/d", "a/b/c/d/e"])
        #expect(
            tree.children(of: "a/b").map(\.name).sorted() == ["c", "three.txt"]
                && tree.children(of: "").map(\.name).sorted() == ["a", "x.txt"]
        )
        // The remembered order follows every change.
        tree.remove("a/b/c/two.txt")
        tree.insert(ArchiveEntry(path: "a/b/c/five.txt", isDirectory: false), keepingOrder: false)
        tree.update("x.txt") { $0.size = 7 }
        #expect(
            tree.ordered.filter { !$0.isDirectory }.map(\.path) == [
                "a/b/c/one.txt", "a/b/three.txt", "x.txt", "a/b/c/d/e/four.txt", "a/z.txt", "a/b/c/five.txt"
            ]
        )
        #expect(tree.ordered.first { $0.path == "x.txt" }?.size == 7)
        // A folder that was taken out is made up again with the next thing inside it.
        for path in ["a/b/c/d/e/four.txt", "a/b/c/d/e", "a/b/c/d"] { tree.remove(path) }
        tree.insert(ArchiveEntry(path: "a/b/c/d/e/six.txt", isDirectory: false), keepingOrder: false)
        #expect(tree.isDirectory("a/b/c/d") && tree.children(of: "a/b/c/d/e").map(\.name) == ["six.txt"])
        #expect(tree.children(of: "a/b/c").map(\.name).sorted() == ["d", "five.txt", "one.txt"])
    }

    /// The old ZIP encryption works in place on slices and in pieces, both ways.
    @Test
    internal func encryptionWorksInPlaceAndBothWays() {
        var data = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let plain = data
        var (encrypting, decrypting) = (ZipCrypto(password: "pässword"), ZipCrypto(password: "pässword"))
        // A block that does not start at index zero, as blocks cut from larger ones do.
        var slice = data.dropFirst(10)
        encrypting.encrypt(&slice)
        #expect(slice != plain.dropFirst(10) && slice.count == plain.count - 10)
        var first = Data(slice.prefix(777))
        var rest = Data(slice.dropFirst(777))
        decrypting.decrypt(&first)
        decrypting.decrypt(&rest)
        #expect(first + rest == plain.dropFirst(10))
        data = plain
        var again = ZipCrypto(password: "pässword")
        #expect(again.encrypt(data.dropFirst(10)) == slice)
    }
}
