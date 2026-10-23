import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Opening archives of every kind: what is listed, and what is refused, when the archive is
/// damaged, too large to copy, or not what its first bytes promise.
@Suite
internal struct CoverageArchivesOpeningTests {
    private let bench: ArchiveBench
    private var box: Sandbox { bench.box }

    /// A bench of its own for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// Runs a tool and fails the test when it does not succeed.
    private func run(_ tool: String, _ arguments: [String]) {
        let result = runTool(tool, arguments, in: box.root)
        #expect(result.status == 0, "\(tool) \(arguments): \(result.output)")
    }

    /// Reads a whole member.
    private func read(_ archive: OpenArchive, _ path: String) throws -> Data {
        let entry = try #require(archive.entry(path))
        let stream = try archive.open(entry, slot: nil)
        defer { stream.close() }
        return try stream.readFully(1 << 20)
    }

    /// Checks that a GZIP whose data is damaged is not taken for a TAR, and fails to open.
    @Test
    internal func aDamagedGzipIsNoTarAndCannotBeOpened() throws {
        var bytes = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3])
        bytes.append(Data(repeating: 0xFF, count: 600))
        try bytes.write(to: box.url("broken.gz"))
        #expect(throws: (any Error).self) { try bench.store.archive(at: box.url("broken.gz"), cancellation: nil) }
    }

    /// Checks that a file with the signature of a foreign format that bsdtar does not recognise
    /// is no archive.
    @Test
    internal func aForeignFileBsdtarDoesNotRecogniseIsNoArchive() throws {
        var bytes = Data("xar!".utf8)
        bytes.append(contentsOf: [0, 0x1C, 0, 1])
        bytes.append(Data("garbage that is no table of contents".utf8))
        try bytes.write(to: box.url("bad.xar"))
        #expect {
            try bench.store.archive(at: box.url("bad.xar"), cancellation: nil)
        } throws: { error in
            guard case ArchiveError.notAnArchive = error else {
                return false
            }
            return true
        }
    }

    /// Checks that a foreign archive too large to copy reads its members from the tool each
    /// time, and notices when the file was replaced meanwhile.
    @Test
    internal func aForeignArchiveThatIsNotCopiedNoticesItsReplacement() throws {
        try box.file("tree/a.txt", "first")
        try box.file("tree/b.txt", "second")
        run("/usr/bin/bsdtar", ["--format", "7zip", "-cf", "tree.7z", "tree"])
        bench.environment.materializeLimit = 0
        let archive = try bench.store.archive(at: box.url("tree.7z"), cancellation: nil)
        #expect(!archive.allowsParallelReads)
        #expect(try read(archive, "tree/a.txt") == Data("first".utf8))
        try CoverageArchives.replace(box.url("tree.7z"), with: box.url("tree/b.txt"))
        #expect {
            _ = try read(archive, "tree/b.txt")
        } throws: { error in
            guard case ArchiveError.changedOutside = error else {
                return false
            }
            return true
        }
    }

    /// Checks that the old `compress` format is read when it holds a TAR, refused when it
    /// holds anything else, and notices its replacement when it is not copied.
    @Test
    internal func compressedTarsOfTheOldFormatAreRead() throws {
        try box.file("tree/a.txt", "hello")
        run("/usr/bin/tar", ["--no-mac-metadata", "-cf", "tree.tar", "tree"])
        run("/usr/bin/compress", ["-f", "tree.tar"])
        let archive = try bench.store.archive(at: box.url("tree.tar.Z"), cancellation: nil)
        #expect(try read(archive, "tree/a.txt") == Data("hello".utf8))
        bench.store.close()

        bench.environment.materializeLimit = 0
        let streamed = try bench.store.archive(at: box.url("tree.tar.Z"), cancellation: nil)
        try CoverageArchives.replace(box.url("tree.tar.Z"), with: box.url("tree/a.txt"))
        #expect(throws: ArchiveError.self) { try read(streamed, "tree/a.txt") }

        try box.file("plain.txt", "no archive at all")
        run("/usr/bin/compress", ["-f", "plain.txt"])
        #expect {
            try bench.store.archive(at: box.url("plain.txt.Z"), cancellation: nil)
        } throws: { error in
            guard case ArchiveError.notAnArchive = error else {
                return false
            }
            return true
        }
    }

    /// Checks that an archive whose folders inside folders would fill the memory is refused.
    @Test
    internal func anArchiveWithTooManyFoldersInsideFoldersIsRefused() throws {
        // Every member lies 255 folders deep, in folders of its own.
        let deep = Array(repeating: String(repeating: "x", count: 15), count: 254).joined(separator: "/")
        let members = (0..<110).map { index in (name: "top\(index)/\(deep)/file", data: Data()) }
        try CoverageArchives.craft(box.url("deep.zip"), members, localExtra: nil) { _ in
            // Every record as it is.
        }
        #expect {
            try bench.store.archive(at: box.url("deep.zip"), cancellation: nil)
        } throws: { error in
            guard case ArchiveError.unsupported(let what) = error else {
                return false
            }
            return what.contains("folders inside folders")
        }
    }

    /// Checks that a compressed TAR that unpacks to more than its copy may hold is read from
    /// the stream instead.
    @Test
    internal func aStreamTooLargeForItsCopyIsReadFromTheStream() throws {
        try box.file("tree/a.txt", String(repeating: "spacious ", count: 200))
        run("/usr/bin/tar", ["--no-mac-metadata", "-czf", "tree.tar.gz", "tree"])
        bench.environment.unpackedLimit = 100
        let archive = try bench.store.archive(at: box.url("tree.tar.gz"), cancellation: nil)
        #expect(archive.scratchBytes == 0 && !archive.allowsParallelReads)
        #expect(try read(archive, "tree/a.txt") == Data(String(repeating: "spacious ", count: 200).utf8))
    }

    /// Checks the name of the file inside a compressed file: from the file's own name, and a
    /// made-up one when that name says nothing.
    @Test
    internal func theFileInsideACompressedFileIsNamed() throws {
        try box.file("content.txt", "inside")
        let gzip = runTool("/bin/sh", ["-c", "/usr/bin/gzip -n -c content.txt > blob; cp blob ...gz"], in: box.root)
        #expect(gzip.status == 0)
        let blob = try bench.store.archive(at: box.url("blob"), cancellation: nil)
        #expect(blob.entries.map(\.path) == ["blob.unpacked"])
        #expect(try read(blob, "blob.unpacked") == Data("inside".utf8))
        let dots = try bench.store.archive(at: box.url("...gz"), cancellation: nil)
        #expect(dots.entries.map(\.path) == ["unpacked"])
    }

    /// Checks that a compressed file that is not copied (too large for its copy, or no room
    /// for one) is listed with the size it claims, or the size it unpacks to.
    @Test(arguments: [false, true])
    internal func aCompressedFileWithoutACopyIsListedWithItsSize(roomForTheCopy: Bool) throws {
        let text = String(repeating: "compressible line\n", count: 500)
        try box.file("data.txt", text)
        run("/usr/bin/gzip", ["-k", "data.txt"])
        run("/usr/bin/bzip2", ["-k", "data.txt"])
        if roomForTheCopy {
            bench.environment.unpackedLimit = 100
        } else {
            bench.environment.hasRoom = { _, _ in false }
        }
        for name in ["data.txt.gz", "data.txt.bz2"] {
            let archive = try bench.store.archive(at: box.url(name), cancellation: nil)
            let entry = try #require(archive.entry("data.txt"))
            #expect(entry.size == Int64(text.utf8.count) && archive.scratchBytes == 0)
            #expect(try read(archive, "data.txt") == Data(text.utf8))
        }
    }

    /// Checks that a TAR that lists more entries than an archive may hold is refused.
    @Test
    internal func aTarWithTooManyEntriesIsRefused() throws {
        for name in ["a", "b", "c"] {
            try box.file("many/\(name).txt", name)
        }
        run("/usr/bin/tar", ["--no-mac-metadata", "-cf", "many.tar", "many"])
        bench.environment.maxEntries = 2
        #expect {
            try bench.store.archive(at: box.url("many.tar"), cancellation: nil)
        } throws: { error in
            guard case ArchiveError.unsupported(let what) = error else {
                return false
            }
            return what.contains("more than 2 entries")
        }
    }

    /// Checks that a file of the old `compress` format that cannot be unpacked is no archive,
    /// and that bsdtar's own words about a damaged foreign archive are passed on.
    @Test
    internal func damagedFilesOfOtherFormatsSayWhatIsWrong() throws {
        var compressed = Data([0x1F, 0x9D, 0x90])
        compressed.append(Data(repeating: 0xFF, count: 64))
        try compressed.write(to: box.url("broken.Z"))
        #expect {
            try bench.store.archive(at: box.url("broken.Z"), cancellation: nil)
        } throws: { error in
            guard case ArchiveError.notAnArchive = error else {
                return false
            }
            return true
        }
        var sevenZip = Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 4])
        sevenZip.append(Data("garbage garbage garbage garbage".utf8))
        try sevenZip.write(to: box.url("broken.7z"))
        #expect {
            try bench.store.archive(at: box.url("broken.7z"), cancellation: nil)
        } throws: { error in
            guard case ArchiveError.toolFailed = error else {
                return false
            }
            return true
        }
    }
}
