import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// When the changes are appended to a clone of the archive and when the archive is written
/// anew: members behind the directory, headers that are not what the directory says, volumes
/// that cannot clone, and writes that are ended.
@Suite
internal struct CoverageArchivesAppendTests {
    private let bench: ArchiveBench
    private var box: Sandbox { bench.box }

    /// A bench of its own for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    private func read(_ archive: OpenArchive, _ path: String) throws -> String {
        let stream = try archive.open(try #require(archive.entry(path)), slot: nil)
        defer { stream.close() }
        return try #require(String(bytes: try stream.readFully(1 << 20), encoding: .utf8))
    }

    /// Two stored members, `first.txt` and `last`; the directory says the data of `last` runs
    /// on into the directory.
    private func memberRunningIntoTheDirectory(last: String) throws -> URL {
        let url = box.url("running-\(UUID().uuidString).zip")
        let members = [(name: "first.txt", data: Data("first".utf8)), (name: last, data: Data("last".utf8))]
        try CoverageArchives.craft(url, members, localExtra: nil) { record in
            if record.name == last {
                record.compressedSize += 30
            }
        }
        return url
    }

    /// Checks that a member whose data runs into the directory, listed or not, is not cut off
    /// by an append: the archive is written anew with all of it.
    @Test(arguments: ["last.txt", "../unlisted"])
    internal func membersRunningIntoTheDirectoryAreKept(last: String) throws {
        let url = try memberRunningIntoTheDirectory(last: last)
        let archive = try bench.store.archive(at: url, cancellation: nil)
        try archive.move("first.txt", to: "renamed.txt", replacing: false)
        try archive.commit(cancellation: nil) { _, _ in true }
        bench.store.close()
        let reopened = try bench.store.archive(at: url, cancellation: nil)
        #expect(try read(reopened, "renamed.txt") == "first")
        #expect(CoverageArchives.listed(url).sorted() == [last, "renamed.txt"].sorted())
    }

    /// Checks that a member that is copied in the archive while the file is written is
    /// written from the file it was copied from.
    @Test
    internal func aCopyMadeWhileTheFileIsWrittenIsWrittenNextTime() throws {
        let url = try CoverageArchives.zip("copy.zip", in: box, ["file.txt": "file", "other.txt": "other"], options: [])
        let archive = try bench.store.archive(at: url, cancellation: nil)
        try archive.setAttributes(FileAttributes(permissions: 0o600), of: "other.txt")
        bench.environment.whileWriting = { _ = try? archive.duplicate("file.txt", to: "copy.txt") }
        try archive.commit(cancellation: nil) { _, _ in true }
        bench.environment.whileWriting = nil
        try archive.commit(cancellation: nil) { _, _ in true }
        #expect(CoverageArchives.contents(of: "copy.txt", in: url) == "file" && CoverageArchives.isSound(url))
    }

    /// Checks a new time written into the header of a member that stays where it is: without
    /// an exact time, and with extra fields in its header that are not the time.
    @Test(arguments: [0, 1, 2])
    internal func aNewTimeIsWrittenIntoHeadersOfEveryShape(shape: Int) throws {
        let url = box.url("time.zip")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        if shape == 0 {
            _ = try CoverageArchives.zip("time.zip", in: box, ["plain.txt": "plain"], options: ["-X"])
        } else {
            // A field of another kind, then the time without its "modified" flag; or a field
            // whose length runs past the end of the header's fields.
            let local = shape == 1 ? Data([0x75, 0x78, 1, 0, 0, 0x55, 0x54, 1, 0, 0]) : Data([0x55, 0x54, 0xFF, 0])
            try CoverageArchives.craft(url, [(name: "plain.txt", data: Data("plain".utf8))], localExtra: local) { _ in
                // Every record as it is.
            }
        }
        let archive = try bench.store.archive(at: url, cancellation: nil)
        try archive.setAttributes(FileAttributes(modified: stamp), of: "plain.txt")
        try archive.commit(cancellation: nil) { _, _ in true }
        bench.store.close()
        let reopened = try bench.store.archive(at: url, cancellation: nil)
        #expect(try read(reopened, "plain.txt") == "plain")
        #expect(abs((reopened.entry("plain.txt")?.modified ?? .distantPast).timeIntervalSince(stamp)) < 2)
        // (The header of the last shape is damaged on purpose.)
        #expect(CoverageArchives.isSound(url) == (shape != 2))
    }

    /// Checks that a time is not written where the directory points at something that is not
    /// a header: the write fails and changes nothing.
    @Test
    internal func aTimeIsNotWrittenWhereNoHeaderIs() throws {
        let url = box.url("pointing.zip")
        let output = try OutputFile(creating: url, mode: 0o600)
        let writer = ZipWriter(output, limits: .standard)
        var first = ZipRecord.new(
            name: "first.txt",
            isDirectory: false,
            modified: Date(timeIntervalSince1970: 1_600_000_000),
            permissions: 0o644,
            isSymbolicLink: false
        )
        let payload = Data(String(repeating: "first member data ", count: 4).utf8)
        (first.crc, first.compressedSize, first.uncompressedSize) = (
            CRC32.of(payload), UInt64(payload.count), UInt64(payload.count)
        )
        let opened = try writer.begin(first, localExtra: nil, expectedSize: nil)
        try writer.append(payload)
        try writer.end(opened, first, headerChanged: false)
        var second = ZipRecord.new(
            name: "second.txt",
            isDirectory: false,
            modified: Date(timeIntervalSince1970: 1_600_000_000),
            permissions: 0o644,
            isSymbolicLink: false
        )
        (second.crc, second.compressedSize, second.uncompressedSize) = (first.crc, 4, 4)
        // Its header would lie in the middle of the first member's data.
        writer.adopt(second, at: 40)
        try writer.finish(comment: Data())
        try output.close(durably: false)
        let before = try Data(contentsOf: url)
        let archive = try bench.store.archive(at: url, cancellation: nil)
        try archive.setAttributes(
            FileAttributes(modified: Date(timeIntervalSince1970: 1_700_000_000)),
            of: "second.txt"
        )
        #expect {
            try archive.commit(cancellation: nil) { _, _ in true }
        } throws: { error in
            guard case ArchiveError.damaged = error else {
                return false
            }
            return true
        }
        #expect(try Data(contentsOf: url) == before)
    }

    /// Checks that a write that is ended while it copies a member changes nothing.
    @Test
    internal func aWriteEndedWhileItCopiesAMemberChangesNothing() throws {
        let url = try CoverageArchives.zip("ended.zip", in: box, ["a.txt": "a", "b.txt": "b"], options: [])
        let archive = try bench.store.archive(at: url, cancellation: nil)
        try archive.remove("a.txt")
        let before = try Data(contentsOf: url)
        let flag = CancellationFlag()
        #expect {
            try archive.commit(cancellation: flag) { _, _ in
                flag.cancel()
                return true
            }
        } throws: { error in
            guard case ArchiveError.cancelled = error else {
                return false
            }
            return true
        }
        #expect(try Data(contentsOf: url) == before && archive.hasPendingChanges)
    }

    /// Checks that a timer whose write is ended because the program quits tells nobody.
    @Test
    internal func aDelayedWriteEndedByTheQuitIsNotReported() throws {
        let clock = CoverageArchivesClock()
        bench.environment.schedule = { [clock] in clock.schedule($0, $1, $2) }
        bench.environment.flushDelay = 0
        let reported = Signal<Bool>()
        bench.environment.reportFailure = { _, _ in reported.set(true) }
        let url = try CoverageArchives.zip("quit.zip", in: box, ["a.txt": "a"], options: [])
        let archive = try bench.store.archive(at: url, cancellation: nil)
        try archive.remove("a.txt")
        bench.environment.quitting.cancel()
        clock.runDue()
        #expect(reported.wait(seconds: 0) == nil && archive.hasPendingChanges)
    }

    /// Checks archives on a volume that cannot clone: the first change finds that out, or,
    /// when that look could not tell, the first write does; either way the archive is written anew.
    @Test(arguments: [true, false])
    internal func onAVolumeThatCannotCloneTheArchiveIsWrittenAnew(probeTells: Bool) throws {
        guard let image = CoverageArchivesDiskImage(in: box, at: "hfs") else {
            // Fails rather than skips: a skip would leave what the test covers to chance.
            Issue.record("a disk image cannot be attached here (hdiutil)")
            return
        }
        let source = try CoverageArchives.zip("source.zip", in: box, ["a.txt": "a", "b.txt": "b"], options: [])
        let url = image.mountPoint.appendingPathComponent("archive.zip")
        try FileManager.default.copyItem(at: source, to: url)
        let archive = try bench.store.archive(at: url, cancellation: nil)
        if !probeTells {
            // The look at the volume cannot clone a file it cannot read.
            #expect(chmod(url.path, 0o200) == 0)
        }
        try archive.move("a.txt", to: "c.txt", replacing: false)
        #expect(chmod(url.path, 0o644) == 0)
        try archive.commit(cancellation: nil) { _, _ in true }
        #expect(CoverageArchives.listed(url).sorted() == ["b.txt", "c.txt"] && CoverageArchives.isSound(url))
    }
}
