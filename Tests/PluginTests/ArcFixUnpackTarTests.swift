import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Unpacking a compressed TAR in one pass (no copy of it fits on the disk) reads the stream to
/// its end, so that its checksum is checked: a damaged end is reported.
@Suite
internal struct ArcFixUnpackTarTests {
    private let bench: ArchiveBench
    private var box: Sandbox { bench.box }
    private let url: URL

    /// A `.tar.gz` of a small and a large file, read in one pass.
    internal init() throws {
        bench = try ArchiveBench()
        bench.environment.hasRoom = { _, _ in false }
        url = bench.box.url("tree.tar.gz")
        try bench.box.file("tree/a.txt", "a")
        try bench.box.file("tree/b.txt", String(repeating: "abcdefghij", count: 20_000))
        try bench.pack([bench.box.url("tree")], to: url) { options in
            options.format = .compressedTar(.gzip)
        }
    }

    /// Changes the first byte of the checksum the GZIP file ends with, and gives the file back its
    /// date, so that it looks unchanged.
    private func damageTheChecksum() throws {
        var before = stat()
        #expect(stat(url.path, &before) == 0)
        let handle = try FileHandle(forUpdating: url)
        let place = UInt64(before.st_size - 8)
        try handle.seek(toOffset: place)
        let byte = try #require(try handle.read(upToCount: 1)?.first)
        try handle.seek(toOffset: place)
        try handle.write(contentsOf: Data([byte ^ 0x01]))
        try handle.close()
        var times = [before.st_atimespec, before.st_mtimespec]
        #expect(utimensat(AT_FDCWD, url.path, &times, 0) == 0)
    }

    /// Unpacks the archive (only `selection`, when it names anything) into a new folder; the result.
    private func unpack(_ selection: [String] = []) throws -> UnpackResult {
        let archive = try bench.store.archive(at: url, cancellation: nil)
        #expect(!archive.allowsParallelReads)
        let target = try box.folder("out-\(UUID().uuidString)")
        let (files, monitor, options) = (bench.fileSystems, bench.monitor, UnpackOptions())
        let unpacker = Unpacker(fileSystems: files, monitor: monitor, options: options, whileUnpacking: nil) { _, _ in
            .overwrite
        }
        let source = Unpacker.Source(archive: archive, selection: selection.isEmpty ? .all : .paths(selection))
        return unpacker.run([source], into: target)
    }

    /// A sound archive unpacks without a problem, every file of it and its first file alone.
    @Test
    internal func aSoundArchiveUnpacksWithoutAProblem() throws {
        let all = try unpack()
        #expect(all.problems.isEmpty && all.unpacked == 3)
        let first = try unpack(["tree/a.txt"])
        #expect(first.problems.isEmpty && first.unpacked == 1)
    }

    /// A damaged checksum is reported, whether the last file was unpacked or only the first.
    @Test(arguments: [[], ["tree/a.txt"]])
    internal func aDamagedChecksumIsReported(selection: [String]) throws {
        _ = try bench.store.archive(at: url, cancellation: nil)
        try damageTheChecksum()
        let result = try unpack(selection)
        #expect(result.problems == [ArchiveError.damaged("the compressed data cannot be decoded").localizedDescription])
    }
}
