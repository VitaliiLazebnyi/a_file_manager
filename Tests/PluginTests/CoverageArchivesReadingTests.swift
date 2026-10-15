import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Reading the members of archives that can only be read front to back: the readers that wait
/// behind a member, the housekeeping that closes them, and streams that end too early.
@Suite
internal struct CoverageArchivesReadingTests {
    private let bench: ArchiveBench
    private let clock = CoverageArchivesClock()
    private var box: Sandbox { bench.box }

    /// A bench whose housekeeping runs on a clock the test turns, and a compressed TAR of
    /// three files that is read from the stream (it is too large for its copy).
    internal init() throws {
        bench = try ArchiveBench()
        bench.environment.housekeeping = { [clock] in clock.schedule($0, $1, $2) }
        bench.environment.unpackedLimit = 10
        for name in ["a", "b", "c"] {
            try bench.box.file("tree/\(name).txt", String(repeating: name, count: 3_000))
        }
        #expect(
            runTool("/usr/bin/tar", ["--no-mac-metadata", "-czf", "tree.tar.gz", "tree"], in: bench.box.root).status
                == 0
        )
    }

    private func archive() throws -> OpenArchive {
        try bench.store.archive(at: box.url("tree.tar.gz"))
    }

    /// Reads a whole member.
    private func read(_ archive: OpenArchive, _ entry: ArchiveEntry) throws -> Data {
        let stream = try archive.open(entry)
        defer { stream.close() }
        return try stream.readFully(1 << 20)
    }

    /// The n-th file of an archive, in archive order.
    private func entry(_ archive: OpenArchive, _ number: Int) throws -> ArchiveEntry {
        let files = archive.entries.filter { !$0.isDirectory }
        return try #require(files.count > number ? files[number] : nil)
    }

    /// Checks that a reader that delivered a member waits for the next one while it is young,
    /// and is closed by the housekeeping once it has waited long enough.
    @Test
    internal func readersThatNobodyComesBackForAreClosed() throws {
        let opened = try archive()
        // A young reader is kept: the sweep finds nothing to close and looks again later.
        _ = try read(opened, try entry(opened, 0))
        #expect(opened.streamStarts == 1)
        #expect(clock.runDue() == 1)
        _ = try read(opened, try entry(opened, 1))
        #expect(opened.streamStarts == 1)
        // One that has waited its time is closed: the next member starts a new pass.
        bench.store.close()
        bench.environment.readerParkTime = 0
        let again = try archive()
        _ = try read(again, try entry(again, 0))
        clock.take().last?.work()
        #expect(clock.take().isEmpty)
        _ = try read(again, try entry(again, 1))
        #expect(again.streamStarts == 2)
    }

    /// Checks that the housekeeping of an archive that is gone does nothing.
    @Test
    internal func theHousekeepingOfAnArchiveThatIsGoneDoesNothing() throws {
        var opened: OpenArchive? = try archive()
        let first = try entry(try #require(opened), 0)
        _ = try read(try #require(opened), first)
        bench.store.close()
        opened = nil
        #expect(clock.runDue() == 1)
        #expect(clock.take().isEmpty)
    }

    /// Checks that a member that is read to its end after its archive was let go leaves no
    /// reader behind: there is nobody to keep it for.
    @Test
    internal func aMemberThatOutlivesItsArchiveClosesItsReader() throws {
        var opened: OpenArchive? = try archive()
        let stream = try #require(opened).open(try entry(try #require(opened), 0))
        bench.store.close()
        opened = nil
        _ = try? stream.readFully(1 << 20)
        stream.close()
        #expect(clock.take().isEmpty)
    }

    /// Checks that a member the stream does not reach, alone or in one pass with others, is
    /// taken for a sign that the archive is another one now.
    @Test
    internal func aStreamThatEndsBeforeTheMemberIsAnotherArchive() throws {
        let opened = try archive()
        var beyond = try entry(opened, 2)
        beyond.content = .member(index: 99)
        #expect {
            _ = try read(opened, beyond)
        } throws: { error in
            guard case ArchiveError.changedOutside = error else {
                return false
            }
            return true
        }
        #expect {
            try opened.readInOnePass([try entry(opened, 0), beyond]) { _, _ in
                // Nothing is read.
            }
        } throws: { error in
            guard case ArchiveError.changedOutside = error else {
                return false
            }
            return true
        }
    }

    /// Checks that entries that do not belong to an archive of this kind are not found in it.
    @Test
    internal func entriesOfAnotherKindOfArchiveAreNotFound() throws {
        try box.file("zip/one.txt", "one")
        #expect(runTool("/usr/bin/zip", ["-qr", "one.zip", "zip"], in: box.root).status == 0)
        let zip = try bench.store.archive(at: box.url("one.zip"))
        var stranger = try #require(zip.entry("zip/one.txt"))
        for content in [ArchiveEntry.Content.whole, .member(index: 0)] {
            stranger.content = content
            #expect {
                _ = try read(zip, stranger)
            } throws: { error in
                guard case ArchiveError.notFound = error else {
                    return false
                }
                return true
            }
        }
    }

    /// Checks that no more than four readers wait at a time: the oldest is let go.
    @Test
    internal func noMoreThanFourReadersWait() throws {
        for name in ["d", "e", "f"] {
            try box.file("tree/\(name).txt", String(repeating: name, count: 3_000))
        }
        #expect(runTool("/usr/bin/tar", ["--no-mac-metadata", "-czf", "six.tar.gz", "tree"], in: box.root).status == 0)
        let opened = try bench.store.archive(at: box.url("six.tar.gz"))
        // Read backwards, each member needs a pass of its own and leaves a reader behind.
        for number in (0..<5).reversed() {
            #expect(try read(opened, try entry(opened, number)).count == 3_000)
        }
        #expect(opened.streamStarts == 5)
        // The one behind the fifth file was let go: the sixth is read from the one behind the fourth.
        #expect(try read(opened, try entry(opened, 5)).count == 3_000)
        #expect(opened.streamStarts == 5)
    }
}
