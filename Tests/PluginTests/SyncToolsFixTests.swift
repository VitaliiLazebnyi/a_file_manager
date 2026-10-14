import AFMContracts
import AFMKernel
@testable import CompareContentPlugin
@testable import DirectorySyncPlugin
@testable import FileToolsPlugin
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

private func fixPattern(_ count: Int) -> Data { Data((0..<count).map { UInt8($0 % 251) }) }

private func fixDigest(_ method: ChecksumMethod, _ data: Data, pieces: Int = 1) -> String {
    let hasher = method.makeHasher()
    let step = max(1, (data.count + pieces - 1) / pieces)
    for start in stride(from: 0, to: data.count, by: step) { hasher.update(data.subdata(in: start..<min(start + step, data.count))) }
    return hasher.finish().hex
}

/// The fixes of the file tools: decoding, in-place outputs, safe overwrites, BLAKE3, checksum files.
@Suite struct FileToolsFixes {
    let box: Sandbox
    let fileSystems = FileSystemRegistry()
    var run: ToolRun { ToolRun(fileSystems: fileSystems) }

    init() throws {
        box = try Sandbox()
        fileSystems.register(LocalFileSystem())
    }

    func item(_ path: String) -> FileItem { fileSystems.item(at: box.url(path))! }

    @Test func decodingOneNumberedFileDoesNotRunIntoTheNext() throws {
        // 57 bytes encode without padding, so only the file's own end tells it is over.
        let first = Data((0..<57).map { UInt8($0) }), second = Data((0..<114).map { UInt8(255 - $0) })
        try box.folder("in")
        try box.folder("out")
        try first.write(to: box.url("in/src1.bin"))
        try second.write(to: box.url("in/src2.bin"))
        try Encoder.encode(item("in/src1.bin"), into: box.url("in"), method: .mime, run: run)
        try Encoder.encode(item("in/src2.bin"), into: box.url("in"), method: .mime, run: run)
        try FileManager.default.moveItem(at: box.url("in/src1.b64"), to: box.url("in/IMG_0001.b64"))
        try FileManager.default.moveItem(at: box.url("in/src2.b64"), to: box.url("in/IMG_0002.b64"))

        let written = try Decoder.decode(item("in/IMG_0001.b64"), into: box.url("out"), run: run)
        #expect(written == [box.url("out/src1.bin")])
        #expect(try Data(contentsOf: box.url("out/src1.bin")) == first)
        #expect(!FileManager.default.fileExists(atPath: box.url("out/src2.bin").path))
    }

    @Test func partsOfOneFileStillJoin() throws {
        let data = fixPattern(5000)
        try box.folder("out")
        try data.write(to: box.url("big.bin"))
        let parts = try Encoder.encode(item("big.bin"), into: box.url("."), method: .mime, linesPerFile: 20, run: run)
        #expect(parts.count > 2)
        try FileManager.default.removeItem(at: box.url("big.bin"))
        let written = try Decoder.decode(fileSystems.item(at: parts[0])!, into: box.url("out"), run: run)
        #expect(written.count == 1)
        #expect(try Data(contentsOf: written[0]) == data)
    }

    @Test func base64EndsAtItsPadding() throws {
        // Two independent encodings in one file: each ends where its padding does.
        let text = "MIME-Version: 1.0\r\nContent-Disposition: attachment; filename=\"one.bin\"\r\nContent-Transfer-Encoding: base64\r\n\r\nYWJj\r\nZA==\r\n"
            + "MIME-Version: 1.0\r\nContent-Disposition: attachment; filename=\"two.bin\"\r\nContent-Transfer-Encoding: base64\r\n\r\nZWZn\r\n"
        try box.folder("out")
        try Data(text.utf8).write(to: box.url("two.b64"))
        let written = try Decoder.decode(item("two.b64"), into: box.url("out"), run: run)
        #expect(written.count == 2)
        #expect(try Data(contentsOf: written[0]) == Data("abcd".utf8))
        #expect(try Data(contentsOf: written[1]) == Data("efg".utf8))
    }

    @Test func splitAndEncodeRefuseToReplaceTheirSource() throws {
        let data = fixPattern(3000)
        try data.write(to: box.url("data.001"))
        #expect(throws: ToolError.self) { try Splitter.split(item("data.001"), into: box.url("data.001").deletingLastPathComponent(), partSize: 1000, run: run) }
        #expect(try Data(contentsOf: box.url("data.001")) == data)

        try data.write(to: box.url("notes.b64"))
        #expect(throws: ToolError.self) { try Encoder.encode(item("notes.b64"), into: box.url("notes.b64").deletingLastPathComponent(), method: .mime, run: run) }
        #expect(try Data(contentsOf: box.url("notes.b64")) == data)
    }

    @Test func unreadableSourceCostsNoOutput() throws {
        try box.folder("out")
        let gone = FileItem(url: box.url("missing.bin"), name: "missing.bin", isDirectory: false, size: 10, modified: Date())
        #expect(throws: (any Error).self) { try Splitter.split(gone, into: box.url("out"), partSize: 5, run: run) }
        #expect(throws: (any Error).self) { try Encoder.encode(gone, into: box.url("out"), method: .mime, run: run) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.url("out").path).isEmpty)
    }

    @Test func overwriteKeepsTheOldFileUntilTheNewOneIsDone() throws {
        try Data("old".utf8).write(to: box.url("target.txt"))
        let output = try #require(try run.create(box.url("target.txt")))
        try output.write(Data("new".utf8))
        #expect(try Data(contentsOf: box.url("target.txt")) == Data("old".utf8))
        output.abandon()
        #expect(try Data(contentsOf: box.url("target.txt")) == Data("old".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.url(".").path) == ["target.txt"])

        let second = try #require(try run.create(box.url("target.txt")))
        try second.write(Data("new".utf8))
        try second.finish()
        #expect(try Data(contentsOf: box.url("target.txt")) == Data("new".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.url(".").path) == ["target.txt"])
    }

    @Test(arguments: [
        (0, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"),
        (1, "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213"),
        (1023, "10108970eeda3eb932baac1428c7a2163b0e924c9a9e25b35bba72b28f70bd11"),
        (1024, "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7"),
        (1025, "d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444"),
        (2048, "e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a"),
        (3072, "b98cb0ff3623be03326b373de6b9095218513e64f1ee2edd2525c7ad1e5cffd2"),
        (65536, "68d647e619a930e7b1082f74f334b0c65a315725569bdc123f0ee11881717bfe"),
        (1_048_576, "74cb441fd087764ca9c3694da742ebe30cbeb3060a17009ca81825c7a8d10343"),
        (1_048_577, "2f053cd7472cf0cd2f9adaf45c1180255b91b9a865404a63671a0ee5f792ed33"),
        (9_000_007, "5719b9667d3fee9292ca79e9aac4d4668a0738cb3b2ef7ee60258adf5aa9e9cf"),
    ])
    func blake3Vectors(count: Int, expected: String) {
        let data = fixPattern(count)
        // Whole (the large inputs are hashed on all cores), in megabyte blocks, and in odd pieces.
        #expect(fixDigest(.blake3, data) == expected)
        #expect(fixDigest(.blake3, data, pieces: 7) == expected)
        #expect(fixDigest(.blake3, data, pieces: 1500) == expected)
    }

    @Test func sha3FallbackAgreesWithTheSelectedImplementation() {
        let data = fixPattern(100_000)
        for length in [32, 48, 64] {
            let fallback = SHA3Hasher(digestLength: length)
            fallback.update(data)
            let method: ChecksumMethod = length == 32 ? .sha3_256 : length == 48 ? .sha3_384 : .sha3_512
            #expect(fallback.finish().hex == fixDigest(method, data, pieces: 5))
        }
    }

    @Test func checksumLinesInOtherForms() {
        let md5 = "d41d8cd98f00b204e9800998ecf8427e"
        let sha224 = String(repeating: "ab", count: 28), sha384 = String(repeating: "cd", count: 48)
        let entries = ChecksumFile.parse("\\\(md5) *a\\\\b\\nc\nSHA2-224(x)= \(sha224)\nSHA2-384(y)= \(sha384)\n", fileName: "list.txt")
        #expect(entries.map(\.name) == ["a\\b\nc", "x", "y"])
        #expect(entries[1].method == .sha224 && entries[2].method == .sha384)
    }

    @Test func aChecksumFileAmongTheOperandsIsNotHashed() throws {
        try Data("one".utf8).write(to: box.url("a.txt"))
        try Data("0".utf8).write(to: box.url("dir.sfv"))
        var options = ChecksumRun.CreateOptions()
        options.method = .crc32
        let written = try ChecksumRun.create(for: [item("a.txt"), item("dir.sfv")], target: box.url("dir.sfv"), options: options, run: run)
        #expect(written == [box.url("dir.sfv")])
        let text = try String(contentsOf: box.url("dir.sfv"), encoding: .utf8)
        #expect(text.contains("a.txt") && !text.contains("dir.sfv"))
    }

    @Test func filesOutsideTheTargetFolderKeepTheirFullPath() throws {
        try box.folder("sub")
        try Data("one".utf8).write(to: box.url("a.txt"))
        try Data("two".utf8).write(to: box.url("sub/b.txt"))
        var options = ChecksumRun.CreateOptions()
        options.method = .md5
        _ = try ChecksumRun.create(for: [item("a.txt")], target: box.url("sub/list.md5"), options: options, run: run)
        let text = try String(contentsOf: box.url("sub/list.md5"), encoding: .utf8)
        #expect(text.contains("*" + box.url("a.txt").path))
        // And Verify reads such a path as it is.
        let report = try ChecksumRun.verify(checksumFiles: [item("sub/list.md5")], run: run)
        #expect(report.errors == 0)
    }

    @Test func verifyHashesTheLikelyMethodFirstAndFindsTheOthers() throws {
        let data = fixPattern(70_000)
        try data.write(to: box.url("f.bin"))
        let blake = fixDigest(.blake3, data), sha3 = fixDigest(.sha3_256, data), sha2 = fixDigest(.sha256, data)
        let report = try ChecksumRun.verify([(item("f.bin"), sha2), (item("f.bin"), sha3), (item("f.bin"), blake),
                                             (item("f.bin"), String(repeating: "0", count: 64))], title: "t", run: run)
        #expect(report.sections[0].rows.map(\.result) == [.ok, .ok, .ok, .wrongChecksum])
    }
}

/// The fixes of the directory comparison and its session.
@Suite struct DirectorySyncFixes {
    let fileSystems = FileSystemRegistry()
    let memory = MemoryFileSystem()
    let early = Date(timeIntervalSince1970: 1_000_000)

    init() {
        fileSystems.register(LocalFileSystem())
        fileSystems.register(memory)
    }

    func file(_ name: String) -> FileItem { FileItem(url: memory.url("/" + name), name: name, isDirectory: false, size: 1, modified: early) }

    @Test func caseInsensitivePairingKeepsItsOrderAndIsFast() {
        // Several names that fold alike pair in order; the rest stays alone.
        let left = ["ab", "AB", "c"].map(file), right = ["Ab", "aB", "d"].map(file)
        let pairs = SyncComparison.pair(left, right)
        #expect(pairs.map { "\($0.left?.name ?? "-")/\($0.right?.name ?? "-")" } == ["ab/Ab", "AB/aB", "c/-", "-/d"])

        let many = 20_000
        let big = SyncComparison.pair((0..<many).map { file("L\($0)") }, (0..<many).map { file("l\($0)") })
        #expect(big.count == many && big.allSatisfy { $0.left != nil && $0.right != nil })
    }

    @Test func subSecondDifferencesAreNotDifferences() {
        var options = SyncOptions()
        options.toleranceSeconds = 0
        let apfs = FileItem(url: memory.url("/a"), name: "a", isDirectory: false, size: 1, modified: early.addingTimeInterval(0.789))
        let fat = FileItem(url: memory.url("/a"), name: "a", isDirectory: false, size: 1, modified: early)
        #expect(SyncComparison.classify(left: apfs, right: fat, options: options).state == .equal)
        let later = FileItem(url: memory.url("/a"), name: "a", isDirectory: false, size: 1, modified: early.addingTimeInterval(1.5))
        #expect(SyncComparison.classify(left: later, right: fat, options: options).state == .leftNewer)
    }

    @Test func aLinkFacingAFileIsNeverActedOn() throws {
        let box = try Sandbox()
        try box.folder("L")
        try box.folder("R")
        try Data("x".utf8).write(to: box.url("L/a.txt"))
        try Data("y".utf8).write(to: box.url("R/target.txt"))
        try FileManager.default.createSymbolicLink(at: box.url("R/a.txt"), withDestinationURL: box.url("R/target.txt"))
        try FileManager.default.createSymbolicLink(at: box.url("L/lonely"), withDestinationURL: box.url("R/target.txt"))
        let result = SyncComparison(options: SyncOptions(), fileSystems: fileSystems).run(left: box.url("L"), right: box.url("R"))
        let row = try #require(result.rows.first { $0.name == "a.txt" })
        #expect(row.state == .excluded && row.action == .none && !row.accepts(.copyToRight))
        #expect(result.rows.contains { $0.name == "target.txt" } && !result.rows.contains { $0.name == "lonely" })
        #expect(SyncPlan(rows: result.rows).toRight.map(\.source) == [])
    }
}

/// The fixes of Compare by content.
@Suite struct CompareContentFixes {
    @Test func savingKeepsTheLinkAndTheTags() throws {
        let box = try Sandbox()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        try Data("old\n".utf8).write(to: box.url("real.txt"))
        try FileManager.default.createSymbolicLink(at: box.url("link.txt"), withDestinationURL: box.url("real.txt"))
        let attribute = "com.example.tag"
        _ = box.url("real.txt").withUnsafeFileSystemRepresentation { path in
            setxattr(path, attribute, "blue", 4, 0, 0)
        }
        try CompareLoader.replace(box.url("link.txt"), with: Data("new\n".utf8), fileSystems: fileSystems)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: box.url("link.txt").path)) != nil)
        #expect(try Data(contentsOf: box.url("real.txt")) == Data("new\n".utf8))
        let size = box.url("real.txt").withUnsafeFileSystemRepresentation { getxattr($0, attribute, nil, 0, 0, 0) }
        #expect(size == 4)
    }

    @Test func hashedKeysFindTheSameDifferencesAsBefore() {
        let options = DiffOptions()
        let left = ["Hello  World", "same", "tab\tx", "ÄÖ", "end"].map { TextLine($0) }
        let right = ["hello world", "same", "tab x", "äö", "END!"].map { TextLine($0) }
        for (one, two) in zip(left, right) { #expect((options.hash(one) == options.hash(two)) == (options.key(one) == options.key(two))) }
        let diff = TextDiff.compute(left: left, right: right, options: options)
        #expect(diff.rows.map(\.kind) == [.equal, .equal, .equal, .equal, .changed])
    }

    @Test func insideALineTheCommonEndsAreTrimmed() {
        let ranges = TextDiff.inline("prefix-OLD-suffix", "prefix-NEWER-suffix")
        #expect(ranges.left == [7..<10] && ranges.right == [7..<12])
    }

    @Test func binaryRowText() {
        let diff = BinaryDiff.compute(left: Data(), right: Data(), bytesPerLine: 8)
        #expect(diff.text(of: Data([0x41, 0x00, 0xFF]), row: 0) == "41 00 FF" + String(repeating: " ", count: 8 * 3 + 1 - 8) + "A..")
    }
}

/// The session of Synchronize directories: cheap toggling and the phase while the job runs.
@MainActor @Suite struct DirectorySyncSessionFixes {
    let memory = MemoryFileSystem()
    let plugin = DirectorySyncPlugin(opensWindows: false)
    let bench: TestBench
    let early = Date(timeIntervalSince1970: 1_000_000)

    init() {
        memory.addFile("/A/new.txt", "from the left", modified: early.addingTimeInterval(500))
        memory.addFile("/B/sub/arrives.txt", "from the right", modified: early)
        memory.addFile("/A/same.txt", "same", modified: early)
        memory.addFile("/B/same.txt", "same", modified: early)
        bench = TestBench(plugins: [plugin], fileSystems: [LocalFileSystem(), memory], left: memory.url("/A"), right: memory.url("/B"),
                          settings: MemorySettings())
    }

    func opened() -> SyncSession {
        bench.commands.perform(.synchronizeDirectories)
        let session = plugin.session!
        session.compare()
        return session
    }

    @Test func togglingTouchesOnlyItsRowsAndKeepsTheCount() {
        let session = opened()
        #expect(session.canSynchronize)
        var touched: [[Int]] = []
        session.onRowsChange = { touched.append($0) }
        let all = session.visibleRows
        session.setAction(.none, rows: all)
        #expect(!session.canSynchronize && touched == [all.filter { session.rows[$0].defaultAction != .none }])
        // Rows already at the wanted action are not reported again.
        session.setAction(.none, rows: all)
        #expect(touched.last == [])
        let new = session.rows.indices.first { session.rows[$0].name == "new.txt" }!
        session.toggle(rows: [new])
        #expect(session.canSynchronize && touched.last == [new] && session.positions[new] >= 0)
        #expect(session.groupIndicator(atEntry: session.entries.count - 1).contains("sub/"))
    }

    @Test func neitherSynchronizeNorCompareStartsWhileTheJobRuns() {
        let session = opened()
        var phases: [SyncSession.Phase] = []
        session.onChange = { phases.append(session.phase) }
        bench.ui.formAnswers = [.accept]
        bench.ui.choiceAnswers = [1]
        session.synchronize()
        #expect(phases.contains(.synchronizing) && session.phase == .compared)
        #expect(phases.first == .synchronizing)
    }
}
