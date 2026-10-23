import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FileToolsPlugin

/// Checksum files beyond the other suites: names that need escapes, texts that are no text,
/// files that cannot be read while they are hashed or verified, and names that collide.
@Suite
internal struct CoverageFileToolsChecksums {
    /// The files: `/A` with two files and a folder.
    private let memory = MemoryFileSystem()
    /// The memory files behind a layer that fails what a test names.
    private let files: CoverageSmallFiles
    /// The layer, as the tools find it.
    private let fileSystems = FileSystemRegistry()

    /// A run that overwrites and asks nothing.
    private var run: ToolRun { ToolRun(fileSystems: fileSystems) }

    /// The files and the registry.
    internal init() {
        memory.addFile("/A/one.txt", "one")
        memory.addFile("/A/s1/x.txt", "x1")
        memory.addFile("/A/s2/x.txt", "x2")
        memory.addDirectory("/B")
        files = CoverageSmallFiles(memory)
        fileSystems.register(files)
    }

    /// The item of a memory path.
    private func item(_ path: String) throws -> FileItem {
        try #require(memory.item(at: memory.url(path)))
    }

    /// The CRC32 of a text, as a checksum file has it.
    private func crc(_ text: String) -> String {
        let hasher = CRC32Hasher()
        hasher.update(Data(text.utf8))
        return hasher.finish().hex
    }

    /// Lines: an empty name, and a name with a backslash and a carriage return.
    @Test
    internal func linesOfOddNames() {
        #expect(ChecksumFile.line(name: "", digest: [1, 2, 3, 4], method: .crc32) == " 01020304")
        #expect(ChecksumFile.line(name: "a\\b\rc", digest: [1], method: .md5) == "\\01 *a\\\\b\\rc")
        #expect(VerifyReport.row("x", .readError) == "Error reading file x!")
    }

    /// Texts: damaged UTF-16 and bytes that are neither UTF-8 nor the code page.
    @Test
    internal func textsThatAreNoText() {
        #expect(ChecksumFile.text(from: Data([0xFF, 0xFE, 0x00, 0xD8])).contains("\u{FFFD}"))
        #expect(ChecksumFile.text(from: Data([0x81])) == "\u{FFFD}")
    }

    /// Escaped lines: one without a backslash in its name, and escapes of every kind.
    @Test
    internal func escapedLines() {
        let digest = String(repeating: "a", count: 32)
        let parsed = ChecksumFile.parse("\\\(digest) *plain\n\\\(digest) *a\\rb\\xc\n", fileName: "list.md5")
        #expect(parsed.map(\.name) == ["plain", "a\rbxc"])
    }

    /// A checksum file per folder at a root is named `checksums`.
    @Test
    internal func aChecksumFileAtARoot() throws {
        memory.addFile("/top.txt")
        var options = ChecksumRun.CreateOptions()
        options.separatePerFolder = true
        let url = ChecksumRun.outputURL(for: try item("/top.txt"), target: memory.url("/B/x.sfv"), options: options)
        #expect(url == memory.url("/checksums.sfv"))
    }

    /// A file that cannot be read fails the whole; files that would share one separate checksum
    /// file under one name are refused.
    @Test
    internal func checksumFilesThatCannotBeMade() throws {
        files.failingPaths = ["/A/one.txt"]
        #expect(throws: ToolError.self) {
            try ChecksumRun.create(
                for: [try item("/A/one.txt")],
                target: memory.url("/B/all.sfv"),
                options: ChecksumRun.CreateOptions(),
                run: run
            )
        }
        files.failingPaths = []
        var options = ChecksumRun.CreateOptions()
        options.separatePerFile = true
        #expect(throws: ToolError.failed("Several files with the same name would get the same checksum file.")) {
            try ChecksumRun.create(
                for: [try item("/A/s1"), try item("/A/s2")],
                target: memory.url("/B/*.*.sfv"),
                options: options,
                run: run
            )
        }
        #expect(!memory.allPaths.contains { $0.hasPrefix("/B/") })
    }

    /// Verify: a checksum file that cannot be read, a checksum of a length the file's kind does
    /// not have, a name of a folder, and a file that cannot be read.
    @Test
    internal func verifyingWhatCannotBeChecked() throws {
        let sha256 = String(repeating: "0", count: 64)
        memory.addFile(
            "/A/sums.md5",
            "\(sha256) *one.txt\n\(crc("x")) *s1\n\(String(repeating: "0", count: 32)) *two.txt\n"
        )
        memory.addFile("/A/two.txt", "two")
        memory.addFile("/A/bad.md5", "x")
        files.failingPaths = ["/A/bad.md5", "/A/two.txt"]
        let report = try ChecksumRun.verify(checksumFiles: [try item("/A/sums.md5"), try item("/A/bad.md5")], run: run)
        let rows = report.sections.flatMap(\.rows).map(\.result)
        #expect(rows == [.wrongChecksum, .notFound, .readError, .unreadable])
        let flag = CancellationFlag()
        files.onFailure = { _ in flag.cancel() }
        #expect(throws: ToolError.cancelled) {
            try ChecksumRun.verify(
                checksumFiles: [try item("/A/bad.md5")],
                run: ToolRun(
                    fileSystems: fileSystems,
                    cancellation: flag,
                    report: { _ in
                        // Not watched here.
                    },
                    askExisting: { _ in .overwrite }
                )
            )
        }
    }

    /// A checksum given from outside for a file that cannot be read is a read error.
    @Test
    internal func aGivenChecksumOfAnUnreadableFile() throws {
        files.failingPaths = ["/A/one.txt"]
        let report = try ChecksumRun.verify([(try item("/A/one.txt"), crc("one"))], title: "Given", run: run)
        #expect(report.sections.first?.rows.map(\.result) == [.readError])
    }
}
