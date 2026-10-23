import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Review round 2: files handed to bsdtar, typed paths, and formats read in odd shapes.
@Suite
internal struct Review2ArchivesForeignTests: ArchiveFixSuite {
    /// The archive file systems in a sandbox of their own.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// A text file named like an archive is not handed to bsdtar; only the first bytes decide (A038).
    @Test
    internal func aTextFileNamedLikeAnArchiveIsNotGivenToBsdtar() throws {
        let secret = try box.file("secret.txt", "TOP-SECRET-CONTENT")
        for (name, head) in [
            ("holiday.7z", "#mtree\n"), ("list.rar", ""),
            ("lha.lzh", "ab-lh5- type=file contents=\(secret.path)\n#mtree\n")
        ] {
            let url = box.url(name)
            try Data((head + "photo.jpg type=file contents=\(secret.path)\n").utf8).write(to: url)
            #expect { try bench.store.archive(at: url, cancellation: nil) } throws: { error in
                if case ArchiveError.notAnArchive = error {
                    return true
                }
                return false
            }
        }
        // By the first bytes, with a zero byte before the first line ends: only then.
        func kind(_ bytes: [UInt8], padding: Int = 64) throws -> ForeignArchive.Kind? {
            let url = box.url("probe-\(UUID().uuidString)")
            try Data(bytes + [UInt8](repeating: 0x41, count: padding)).write(to: url)
            return ForeignArchive.kind(of: try RandomAccessFile(url, shownAs: nil))
        }
        #expect(try kind([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 4]) == .libarchive)
        #expect(try kind([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x0A, 0]) == nil)
        #expect(try kind(Array("Rar!".utf8) + [0x1A, 0x07, 0]) == .libarchive)
        #expect(try kind(Array("#mtree\n".utf8)) == nil && kind(Array("!<arch>\n".utf8)) == nil)
        #expect(try kind([0x1F, 0x9D, 0x90]) == .compressedTar)
        #expect(try kind(Array("070707 type=file\n".utf8) + [0]) == nil)
    }

    /// Real 7-Zip and cpio archives still open through bsdtar (A087).
    @Test
    internal func realForeignArchivesStillOpen() throws {
        try bench.makeTree("tree")
        #expect(runTool("/usr/bin/bsdtar", ["--format", "7zip", "-cf", "tree.7z", "tree"], in: box.root).status == 0)
        #expect(
            runTool("/usr/bin/bsdtar", ["--format", "cpio", "-cf", "tree.cpio", "tree"], in: box.root).status == 0
        )
        for name in ["tree.7z", "tree.cpio"] {
            let inner = bench.inside(box.url(name), "tree", scheme: ArchiveURL.readOnlyScheme)
            #expect(try bench.names(inner, showHidden: true).contains("readme.txt"), "\(name)")
            #expect(
                try bench.read(inner.appending(name: "readme.txt")) == Data(contentsOf: box.url("tree/readme.txt")),
                "\(name)"
            )
        }
    }

    // MARK: Typed paths (A001, A002, A056)

    /// A typed path is looked at only on local disks, and a folder named like an archive stays a folder (A001).
    @Test
    internal func aTypedPathIsOnlyAskedAboutOnLocalDisks() throws {
        try box.file("real/a.zip", "x")
        try box.folder("folder.zip")
        try FileManager.default.createSymbolicLink(at: box.url("link"), withDestinationURL: box.url("real"))
        #expect(Volume.isOnLocalVolume(box.root.path) && !Volume.isOnLocalVolume("relative/path"))
        #expect(Volume.kind(ofLocalPath: box.url("real/a.zip").path) == .regularFile)
        #expect(Volume.kind(ofLocalPath: box.url("link/a.zip").path) == .regularFile)
        #expect(Volume.kind(ofLocalPath: box.url("folder.zip").path) == .directory)
        #expect(Volume.kind(ofLocalPath: box.url("missing.zip").path) == .missing)
        #expect(Volume.kind(ofLocalPath: box.url("real/a.zip/x").path) == .missing)
        // A folder named like an archive, reached by an archive location all the same (as a
        // typed path on a server is read): the place is the folder's.
        try box.file("folder.zip/inside.txt", "inside")
        let through = ArchiveURL.make(scheme: ArchiveURL.writableScheme, archive: box.url("folder.zip"), innerPath: "")
        #expect(try bench.names(through, showHidden: true) == ["inside.txt"])
    }

    // MARK: Formats

    /// Long zero padding between two XZ streams is read over, and both streams are read.
    @Test
    internal func longPaddingBetweenXZStreamsIsRead() throws {
        var file = try XZCoder.compress(Data("first ".utf8))
        file.append(Data(count: 200_000))
        file.append(try XZCoder.compress(Data("second".utf8)))
        file.append(Data(count: 65_536))
        try file.write(to: box.url("padded.xz"))
        let stream = try XZStream(
            FileRangeStream(try RandomAccessFile(box.url("padded.xz"), shownAs: nil), offset: 0, length: nil),
            control: nil
        )
        var data = Data()
        while let block = try stream.read(upToCount: 1 << 16) { data.append(block) }
        #expect(String(bytes: data, encoding: .utf8) == "first second")
    }

    /// The ZIP64 end record is found behind a self-extractor's program in front of the archive.
    @Test
    internal func aZip64EndRecordIsFoundBehindASelfExtractorStub() throws {
        let plain = try writeZip(
            "wide.zip",
            limits: ZipLimits(maxField: 0xFFFF_FFFE, maxEntries: 2),
            names: ["a.txt", "b.txt", "c.txt", "d.txt"]
        )
        var stubbed = Data(repeating: 0x90, count: 5_000)
        stubbed.append(try Data(contentsOf: plain))
        try stubbed.write(to: box.url("sfx.zip"))
        let contents = try ZipDirectory.read(
            try RandomAccessFile(box.url("sfx.zip"), shownAs: nil),
            maxEntries: .max,
            check: nil
        )
        #expect(contents.isZip64 && contents.records.map(\.name) == ["a.txt", "b.txt", "c.txt", "d.txt"])
        #expect(
            try bench.names(bench.inside(box.url("sfx.zip"), "", scheme: ArchiveURL.writableScheme), showHidden: true)
                == ["a.txt", "b.txt", "c.txt", "d.txt"]
        )
    }

    /// A file that comes after a hard link of the same name keeps its own contents.
    @Test
    internal func aFileThatTakesOverTheNameOfAHardLinkKeepsItsOwnContents() throws {
        var tar = Data()
        tar.append(HandMadeTar.file("target.txt", "target"))
        tar.append(HandMadeTar.link("name.txt", to: "target.txt", type: 49))
        tar.append(HandMadeTar.file("name.txt", "own"))
        tar.append(Data(count: 1_024))
        try tar.write(to: box.url("links.tar"))
        let root = bench.inside(box.url("links.tar"), "", scheme: ArchiveURL.readOnlyScheme)
        #expect(try bench.read(root.appending(name: "name.txt")) == Data("own".utf8))
        #expect(try bench.read(root.appending(name: "target.txt")) == Data("target".utf8))
    }
}
