import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Test archive on a compressed TAR whose file was damaged after it was opened, the way a disk
/// damages a file: a byte changed in the middle, the size and the date as they were.
@Suite
internal struct CovSmallArchiveTestTests {
    /// Changes one byte in the middle of the file at `url` in place and gives it back its date,
    /// so that it looks unchanged.
    private static func damage(_ url: URL) throws {
        var before = stat()
        #expect(stat(url.path, &before) == 0)
        let handle = try FileHandle(forUpdating: url)
        let middle = UInt64(before.st_size / 2)
        try handle.seek(toOffset: middle)
        let byte = try #require(try handle.read(upToCount: 1)?.first)
        try handle.seek(toOffset: middle)
        try handle.write(contentsOf: Data([byte ^ 0x01]))
        try handle.close()
        var times = [before.st_atimespec, before.st_mtimespec]
        #expect(utimensat(AT_FDCWD, url.path, &times, 0) == 0)
        var after = stat()
        #expect(stat(url.path, &after) == 0)
        #expect(FileSignature(after) == FileSignature(before))
    }

    /// The damage is found whether the members are read from a copy made when the archive was
    /// opened, or from the file in one pass: the stream is read to its checksum either way.
    @Test(arguments: [true, false])
    internal func aDamagedMiddleIsFound(copied: Bool) throws {
        let bench = try ArchiveBench()
        let box = bench.box
        // Whether there is room for the copy is the test's choice, not what the disk has free
        // while other tests write.
        bench.environment.hasRoom = { _, _ in copied }
        try box.file("tree/a.txt", String(repeating: "abcdefghij", count: 20_000))
        try box.file("tree/b.txt", "b")
        let url = box.url("tree.tar.gz")
        try bench.pack([box.url("tree")], to: url) { options in
            options.format = .compressedTar(.gzip)
            options.level = 0
        }
        let archive = try bench.store.archive(at: url, cancellation: nil)
        #expect(archive.allowsParallelReads == copied)
        #expect(ArchiveTester.test(archive, cancellation: CancellationFlag(), counter: nil, members: .all).isEmpty)
        try Self.damage(url)
        #expect(try bench.store.archive(at: url, cancellation: nil) === archive)
        let problems = ArchiveTester.test(archive, cancellation: CancellationFlag(), counter: nil, members: .all)
        // What the changed byte becomes depends on the times in the TAR headers: the decoder stops at it, or hands
        // on a header that is wrong. Either way the damage is reported, once.
        #expect(problems.count == 1 && problems.first?.hasPrefix("The archive is damaged:") == true)
    }

    /// The members asked for are tested with the whole stream: a damage elsewhere in it is found.
    @Test
    internal func aDamageOutsideTheMembersAskedForIsFound() throws {
        let bench = try ArchiveBench()
        let box = bench.box
        bench.environment.hasRoom = { _, _ in false }
        try box.file("tree/a.txt", "a")
        try box.file("tree/b.txt", String(repeating: "abcdefghij", count: 20_000))
        let url = box.url("tree.tar.gz")
        try bench.pack([box.url("tree")], to: url) { options in
            options.format = .compressedTar(.gzip)
            options.level = 0
        }
        let archive = try bench.store.archive(at: url, cancellation: nil)
        try Self.damage(url)
        let problems = ArchiveTester.test(
            archive,
            cancellation: CancellationFlag(),
            counter: nil,
            members: .paths(["tree/a.txt"])
        )
        #expect(problems.count == 1 && problems.first?.hasPrefix("The archive is damaged:") == true)
    }
}
