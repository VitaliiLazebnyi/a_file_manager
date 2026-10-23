import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileToolsPlugin

/// The fixes of the file tools: decoding, in-place outputs, safe overwrites, BLAKE3, checksum files.
@Suite
internal struct FileToolsFixes {
    /// A folder of its own on disk for each test.
    internal let box: Sandbox
    /// The local file system.
    internal let fileSystems = FileSystemRegistry()
    /// A run of a tool without a job.
    internal var run: ToolRun { ToolRun(fileSystems: fileSystems) }

    /// A fresh folder on disk, reached through the local file system.
    internal init() throws {
        box = try Sandbox()
        fileSystems.register(LocalFileSystem())
    }

    /// `count` bytes of a pattern that repeats every 251 bytes.
    private static func pattern(_ count: Int) -> Data { Data((0..<count).map { index in UInt8(index % 251) }) }

    /// The hex digest of `data` by `method`, fed in `pieces` blocks of about the same size.
    private static func digest(_ method: ChecksumMethod, _ data: Data, pieces: Int) -> String {
        let hasher = method.makeHasher()
        let step = max(1, (data.count + pieces - 1) / pieces)
        for start in stride(from: 0, to: data.count, by: step) {
            hasher.update(data.subdata(in: start..<min(start + step, data.count)))
        }
        return hasher.finish().hex
    }

    /// The item at `path` in the folder, which must be there.
    internal func item(_ path: String) throws -> FileItem { try #require(fileSystems.item(at: box.url(path))) }

    /// Decoding a numbered file stops at its own end and does not run into the next file of the row.
    @Test
    internal func decodingOneNumberedFileDoesNotRunIntoTheNext() throws {
        // 57 bytes encode without padding, so only the file's own end tells it is over.
        let first = Data((0..<57).map { value in UInt8(value) })
        let second = Data((0..<114).map { value in UInt8(255 - value) })
        try box.folder("in")
        try box.folder("out")
        try first.write(to: box.url("in/src1.bin"))
        try second.write(to: box.url("in/src2.bin"))
        let mime = Encoder.Options(method: .mime)
        try Encoder.encode(try item("in/src1.bin"), into: box.url("in"), options: mime, run: run)
        try Encoder.encode(try item("in/src2.bin"), into: box.url("in"), options: mime, run: run)
        try FileManager.default.moveItem(at: box.url("in/src1.b64"), to: box.url("in/IMG_0001.b64"))
        try FileManager.default.moveItem(at: box.url("in/src2.b64"), to: box.url("in/IMG_0002.b64"))

        let written = try Decoder.decode(try item("in/IMG_0001.b64"), into: box.url("out"), autoRename: false, run: run)
        #expect(written == [box.url("out/src1.bin")])
        #expect(try Data(contentsOf: box.url("out/src1.bin")) == first)
        #expect(!FileManager.default.fileExists(atPath: box.url("out/src2.bin").path))
    }

    /// The parts of one encoded file still decode into the whole.
    @Test
    internal func partsOfOneFileStillJoin() throws {
        let data = Self.pattern(5_000)
        try box.folder("out")
        try data.write(to: box.url("big.bin"))
        let parts = try Encoder.encode(
            try item("big.bin"),
            into: box.url("."),
            options: Encoder.Options(method: .mime, linesPerFile: 20),
            run: run
        )
        #expect(parts.count > 2)
        try FileManager.default.removeItem(at: box.url("big.bin"))
        let first = try #require(fileSystems.item(at: parts[0]))
        let written = try Decoder.decode(first, into: box.url("out"), autoRename: false, run: run)
        #expect(written.count == 1)
        #expect(try Data(contentsOf: written[0]) == data)
    }

    /// Two Base64 encodings in one file: each ends where its padding does.
    @Test
    internal func base64EndsAtItsPadding() throws {
        // Two independent encodings in one file: each ends where its padding does.
        let text =
            "MIME-Version: 1.0\r\nContent-Disposition: attachment; filename=\"one.bin\"\r\n"
            + "Content-Transfer-Encoding: base64\r\n\r\nYWJj\r\nZA==\r\n"
            + "MIME-Version: 1.0\r\nContent-Disposition: attachment; filename=\"two.bin\"\r\n"
            + "Content-Transfer-Encoding: base64\r\n\r\nZWZn\r\n"
        try box.folder("out")
        try Data(text.utf8).write(to: box.url("two.b64"))
        let written = try Decoder.decode(try item("two.b64"), into: box.url("out"), autoRename: false, run: run)
        #expect(written.count == 2)
        #expect(try Data(contentsOf: written[0]) == Data("abcd".utf8))
        #expect(try Data(contentsOf: written[1]) == Data("efg".utf8))
    }

    /// Split and Encode refuse to write over the file they read.
    @Test
    internal func splitAndEncodeRefuseToReplaceTheirSource() throws {
        let data = Self.pattern(3_000)
        try data.write(to: box.url("data.001"))
        let part = try item("data.001")
        #expect(throws: ToolError.self) {
            try Splitter.split(part, into: box.url("data.001").deletingLastPathComponent(), partSize: 1_000, run: run)
        }
        #expect(try Data(contentsOf: box.url("data.001")) == data)

        try data.write(to: box.url("notes.b64"))
        let notes = try item("notes.b64")
        #expect(throws: ToolError.self) {
            try Encoder.encode(
                notes,
                into: box.url("notes.b64").deletingLastPathComponent(),
                options: Encoder.Options(method: .mime),
                run: run
            )
        }
        #expect(try Data(contentsOf: box.url("notes.b64")) == data)
    }

    /// A source that cannot be read costs no output file.
    @Test
    internal func unreadableSourceCostsNoOutput() throws {
        try box.folder("out")
        let gone = FileItem(url: box.url("missing.bin"), name: "missing.bin", stat: .init(size: 10, modified: Date()))
        #expect(throws: (any Error).self) { try Splitter.split(gone, into: box.url("out"), partSize: 5, run: run) }
        #expect(throws: (any Error).self) {
            try Encoder.encode(gone, into: box.url("out"), options: Encoder.Options(method: .mime), run: run)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.url("out").path).isEmpty)
    }

    /// A file that replaces another leaves the old one in place until the new one is finished.
    @Test
    internal func overwriteKeepsTheOldFileUntilTheNewOneIsDone() throws {
        try Data("old".utf8).write(to: box.url("target.txt"))
        let output = try #require(try run.create(box.url("target.txt"), autoRename: false, deferred: false))
        try output.write(Data("new".utf8))
        #expect(try Data(contentsOf: box.url("target.txt")) == Data("old".utf8))
        output.abandon()
        #expect(try Data(contentsOf: box.url("target.txt")) == Data("old".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.url(".").path) == ["target.txt"])

        let second = try #require(try run.create(box.url("target.txt"), autoRename: false, deferred: false))
        try second.write(Data("new".utf8))
        try second.finish()
        #expect(try Data(contentsOf: box.url("target.txt")) == Data("new".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.url(".").path) == ["target.txt"])
    }

    /// BLAKE3 gives the digests of the reference implementation, whole and fed in pieces.
    @Test(arguments: [
        (0, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"),
        (1, "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213"),
        (1_023, "10108970eeda3eb932baac1428c7a2163b0e924c9a9e25b35bba72b28f70bd11"),
        (1_024, "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7"),
        (1_025, "d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444"),
        (2_048, "e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a"),
        (3_072, "b98cb0ff3623be03326b373de6b9095218513e64f1ee2edd2525c7ad1e5cffd2"),
        (65_536, "68d647e619a930e7b1082f74f334b0c65a315725569bdc123f0ee11881717bfe"),
        (1_048_576, "74cb441fd087764ca9c3694da742ebe30cbeb3060a17009ca81825c7a8d10343"),
        (1_048_577, "2f053cd7472cf0cd2f9adaf45c1180255b91b9a865404a63671a0ee5f792ed33"),
        (9_000_007, "5719b9667d3fee9292ca79e9aac4d4668a0738cb3b2ef7ee60258adf5aa9e9cf")
    ])
    internal func blake3Vectors(count: Int, expected: String) {
        let data = Self.pattern(count)
        // Whole (the large inputs are hashed on all cores), in megabyte blocks, and in odd pieces.
        #expect(Self.digest(.blake3, data, pieces: 1) == expected)
        #expect(Self.digest(.blake3, data, pieces: 7) == expected)
        #expect(Self.digest(.blake3, data, pieces: 1_500) == expected)
    }

    /// The SHA-3 implementation of its own agrees with the one the methods use.
    @Test
    internal func sha3FallbackAgreesWithTheSelectedImplementation() {
        let data = Self.pattern(100_000)
        for length in [32, 48, 64] {
            let fallback = SHA3Hasher(digestLength: length)
            fallback.update(data)
            let method: ChecksumMethod = length == 32 ? .sha3Bits256 : length == 48 ? .sha3Bits384 : .sha3Bits512
            #expect(fallback.finish().hex == Self.digest(method, data, pieces: 5))
        }
    }

    /// Escaped GNU lines and the SHA2- tags of other tools are read.
    @Test
    internal func checksumLinesInOtherForms() {
        let md5 = "d41d8cd98f00b204e9800998ecf8427e"
        let sha224 = String(repeating: "ab", count: 28)
        let sha384 = String(repeating: "cd", count: 48)
        let entries = ChecksumFile.parse(
            "\\\(md5) *a\\\\b\\nc\nSHA2-224(x)= \(sha224)\nSHA2-384(y)= \(sha384)\n",
            fileName: "list.txt"
        )
        #expect(entries.map(\.name) == ["a\\b\nc", "x", "y"])
        #expect(entries[1].method == .sha224 && entries[2].method == .sha384)
    }

    /// A checksum file among the operands, which is about to be replaced, is not hashed.
    @Test
    internal func aChecksumFileAmongTheOperandsIsNotHashed() throws {
        try Data("one".utf8).write(to: box.url("a.txt"))
        try Data("0".utf8).write(to: box.url("dir.sfv"))
        var options = ChecksumRun.CreateOptions()
        options.method = .crc32
        let written = try ChecksumRun.create(
            for: [try item("a.txt"), try item("dir.sfv")],
            target: box.url("dir.sfv"),
            options: options,
            run: run
        )
        #expect(written == [box.url("dir.sfv")])
        let text = try String(contentsOf: box.url("dir.sfv"), encoding: .utf8)
        #expect(text.contains("a.txt") && !text.contains("dir.sfv"))
    }

    /// A file outside the checksum file's folder keeps its full path, and Verify reads it so.
    @Test
    internal func filesOutsideTheTargetFolderKeepTheirFullPath() throws {
        try box.folder("sub")
        try Data("one".utf8).write(to: box.url("a.txt"))
        try Data("two".utf8).write(to: box.url("sub/b.txt"))
        var options = ChecksumRun.CreateOptions()
        options.method = .md5
        _ = try ChecksumRun.create(
            for: [try item("a.txt")],
            target: box.url("sub/list.md5"),
            options: options,
            run: run
        )
        let text = try String(contentsOf: box.url("sub/list.md5"), encoding: .utf8)
        #expect(text.contains("*" + box.url("a.txt").path))
        // And Verify reads such a path as it is.
        let report = try ChecksumRun.verify(checksumFiles: [try item("sub/list.md5")], run: run)
        #expect(report.errors == 0)
    }

    /// Verify hashes the likeliest method of a length first, and finds the others of that length too.
    @Test
    internal func verifyHashesTheLikelyMethodFirstAndFindsTheOthers() throws {
        let data = Self.pattern(70_000)
        try data.write(to: box.url("f.bin"))
        let blake = Self.digest(.blake3, data, pieces: 1)
        let sha3 = Self.digest(.sha3Bits256, data, pieces: 1)
        let sha2 = Self.digest(.sha256, data, pieces: 1)
        let file = try item("f.bin")
        let report = try ChecksumRun.verify(
            [(file, sha2), (file, sha3), (file, blake), (file, String(repeating: "0", count: 64))],
            title: "t",
            run: run
        )
        #expect(report.sections[0].rows.map(\.result) == [.correct, .correct, .correct, .wrongChecksum])
    }
}
