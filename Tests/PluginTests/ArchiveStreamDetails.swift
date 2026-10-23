import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// TAR headers, parallel compression and the streams of child processes.
@Suite
internal struct ArchiveStreamDetails {
    /// The archive file systems and the sandbox of the test.
    internal let bench: ArchiveBench
    /// The test's own folder on the local disk.
    internal var box: Sandbox { bench.box }

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// TAR headers carry long names (split at a slash, or as a pax record) and sizes beyond the octal field.
    @Test
    internal func tarHeadersCarryLongNamesAndLargeSizes() throws {
        var header = TarHeader(
            path: "short.txt",
            size: 5,
            modified: Date(timeIntervalSince1970: 1_700_000_000),
            permissions: 0o640
        )
        var parsed = try #require(TarHeader.parse(header.encoded()))
        #expect(
            parsed.header.path == "short.txt" && parsed.header.size == 5 && parsed.header.permissions == 0o640
                && parsed.header.kind == .file
        )

        // A long path is split at a slash when that works, and written as a pax record otherwise.
        let split = String(repeating: "d", count: 90) + "/" + String(repeating: "f", count: 60)
        header.path = split
        #expect(header.encoded().count == 512)
        let unsplittable = String(repeating: "x", count: 300)
        header.path = unsplittable
        header.size = 0o100000000000
        let blocks = header.encoded()
        #expect(blocks.count == 3 * 512)
        let reader = TarReader(DataStream(blocks + Data(count: 1_024)), control: nil)
        let read = try #require(try reader.next())
        #expect(read.path == unsplittable && read.size == 0o100000000000)
        parsed = try #require(TarHeader.parse(TarHeader(path: "dir", kind: .directory).encoded()))
        #expect(parsed.header.kind == .directory && parsed.header.path == "dir/")
        #expect(
            !TarHeader.looksLikeHeader(Data(count: 512)) && !TarHeader.looksLikeHeader(Data(repeating: 65, count: 512))
        )
    }

    /// Compressing in parallel pieces gives one stream the system's tools and the archive code read back whole.
    @Test
    internal func parallelCompressionGivesOneValidStream() throws {
        // Enough data for several pieces per window, ending exactly on a piece boundary.
        var data = Data()
        var line = 0
        while data.count < 3 << 20 {
            data.append(Data("\(line) the quick brown fox jumps over the lazy dog\n".utf8))
            line += 1
        }
        data = data.prefix(3 << 20)
        for (method, name) in [
            (ParallelCompressor.Method.gzip(level: 6), "p.gz"), (.bzip2(level: 9), "p.bz2"), (.xzStream, "p.xz"),
            (.gzip(level: 1), "empty.gz")
        ] {
            let url = box.url(name)
            let output = try OutputFile(creating: url, mode: 0o600)
            let compressor = try ParallelCompressor(method, to: output, modified: Date())
            if name != "empty.gz" {
                try compressor.write(data.prefix(1_000_000))
                try compressor.write(data.dropFirst(1_000_000))
            }
            try compressor.finish()
            try output.close(durably: false)
            let file = try RandomAccessFile(url, shownAs: nil)
            let codec: ArchiveFormat.Codec = name.hasSuffix("gz") ? .gzip : name.hasSuffix("bz2") ? .bzip2 : .xzStream
            let stream = try codec.decompressing(file, control: nil)
            var back = Data()
            while let block = try stream.read(upToCount: 100_000) { back.append(block) }
            stream.close()
            #expect(back == (name == "empty.gz" ? Data() : data), "\(name)")
        }
        #expect(runTool("/usr/bin/gzip", ["-t", box.url("p.gz").path, box.url("empty.gz").path]).status == 0)
        #expect(runTool("/usr/bin/bzip2", ["-t", box.url("p.bz2").path]).status == 0)
        // The checksum of pieces summed separately is the checksum of the whole.
        let (first, second) = (data.prefix(12_345), data.dropFirst(12_345))
        #expect(
            CRC32.combine(CRC32.of(Data(first)), CRC32.of(Data(second)), secondLength: second.count) == CRC32.of(data)
        )
        #expect(CRC32.of(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    /// A file larger than what the compressors hold at once is packed in several rounds into archives the system's
    /// tools accept.
    @Test
    internal func aFileLargerThanOneWindowOfPiecesIsPackedInSeveralRounds() throws {
        // More than the compressors hold before they write: the member stays open across rounds.
        let megabytes = ProcessInfo.processInfo.activeProcessorCount * 2 + 3
        var block = Data()
        for index in 0..<16_384 { block.append(Data(String(format: "%07d %055d\n", index, index &* 7_919).utf8)) }
        #expect(block.count == 1 << 20)
        let handle = try FileHandle(forWritingTo: try box.file("huge.dat", ""))
        for round in 0..<megabytes {
            var piece = block
            piece.replaceSubrange(0..<8, with: Data(String(format: "%08d", round).utf8))
            try handle.write(contentsOf: piece)
        }
        try handle.write(contentsOf: Data("tail".utf8))
        try handle.close()
        let source = box.url("huge.dat")
        let sum = runTool("/usr/bin/cksum", [source.path]).output.split(separator: " ").prefix(2).joined(separator: " ")

        try bench.pack([source], to: box.url("huge.zip"))
        try bench.pack([source], to: box.url("locked.zip")) { options in
            options.password = "pw"
            options.encryption = .legacy
            options.verifies = true
        }
        try bench.pack([source], to: box.url("huge.tgz")) { $0.format = .compressedTar(.gzip) }
        try bench.pack([source], to: box.url("huge.dat.gz")) { $0.format = .compressedFile(.gzip) }
        #expect(try Data(contentsOf: box.url("huge.zip")).count < megabytes << 18)
        #expect(runTool("/usr/bin/unzip", ["-tq", box.url("huge.zip").path]).status == 0)
        #expect(runTool("/usr/bin/unzip", ["-tq", "-P", "pw", box.url("locked.zip").path]).status == 0)
        #expect(runTool("/usr/bin/gzip", ["-t", box.url("huge.tgz").path, box.url("huge.dat.gz").path]).status == 0)
        for name in ["huge.zip", "huge.tgz", "huge.dat.gz"] {
            let folder = try box.folder("out-" + name)
            #expect(try bench.unpack(box.url(name), to: folder).problems.isEmpty)
            let unpacked = runTool("/usr/bin/cksum", [folder.appendingPathComponent("huge.dat").path]).output
                .split(
                    separator: " "
                )
                .prefix(2)
            #expect(unpacked.joined(separator: " ") == sum, "\(name)")
        }
        #expect(bench.monitor.reports.last?.bytesDone == Int64(megabytes << 20 + 4))
    }

    /// A child process is stopped when its stream is closed, a failing tool says why, and file names reach a tool
    /// unchanged.
    @Test
    internal func aChildProcessIsStoppedWhenItsStreamIsClosed() throws {
        let tree = try bench.makeTree()
        try bench.pack([tree], to: box.url("tree.tar.bz2")) { $0.format = .compressedTar(.bzip2) }
        let stream = try ProcessStream(Tool.bzip2, ["-dc", "--", box.url("tree.tar.bz2").path], control: nil)
        #expect(try stream.read(upToCount: 512)?.isEmpty == false)
        stream.close()
        // A tool that fails says why.
        let failing = try ProcessStream(
            Tool.bsdtar,
            ["-cf", "-", "--format", "pax", "@" + box.url("missing.7z").path],
            control: nil
        )
        #expect(throws: ArchiveError.self) {
            while try failing.read(upToCount: 4_096) != nil {
                // Read on to the end, where the failure shows.
            }
        }
        // Arguments reach the tool as they are: no shell reads the name.
        let odd = try box.file("odd $(touch pwned) ; name's \"x\".txt", "odd")
        #expect(runTool("/usr/bin/bzip2", ["-k", odd.path]).status == 0)
        let inner = bench.inside(
            URL(fileURLWithPath: odd.path + ".bz2"),
            odd.lastPathComponent,
            scheme: ArchiveURL.readOnlyScheme
        )
        #expect(try bench.read(inner) == Data("odd".utf8))
        #expect(!box.exists("pwned"))
    }
}
