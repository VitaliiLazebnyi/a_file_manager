import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The kernel's per-location capabilities, as the archives adopt them.
@Suite
internal struct ArchiveAdoption: ArchiveFixSuite {
    /// The archive file systems and the sandbox of the test.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// Each archive says what it can do: a ZIP can be changed later, a ZIP that lists a name twice and the other
    /// formats cannot, and none continues a file.
    @Test
    internal func eachArchiveSaysWhatItCanDo() throws {
        let archive = try makeZip()
        let root = bench.inside(archive)
        // Not opened yet: the scheme's word. Opened: the archive's own.
        #expect(bench.zip.capabilities(for: root) == [.write, .deferredWrites])
        _ = try bench.store.archive(at: archive, cancellation: nil)
        #expect(bench.zip.capabilities(for: root.appending(name: "tree")) == [.write, .deferredWrites])
        #expect(
            bench.readOnly.capabilities(for: bench.inside(archive, "tree", scheme: ArchiveURL.readOnlyScheme)).isEmpty
        )

        // A ZIP that lists a name twice is read-only like the formats that cannot be changed.
        let twice = box.url("twice.zip")
        let output = try OutputFile(creating: twice, mode: 0o600)
        let writer = ZipWriter(output, limits: .standard)
        for _ in 0..<2 {
            try writer.copyMember(
                .new(name: "same.txt", isDirectory: false, modified: Date(), permissions: 0o644, isSymbolicLink: false),
                check: nil
            )
        }
        try writer.finish(comment: Data())
        try output.close(durably: false)
        _ = try bench.store.archive(at: twice, cancellation: nil)
        #expect(bench.zip.capabilities(for: bench.inside(twice)).isEmpty)
        try bench.pack([box.url("tree")], to: box.url("plain.tar")) { $0.format = .tar }
        _ = try bench.store.archive(at: box.url("plain.tar"), cancellation: nil)
        #expect(bench.zip.capabilities(for: bench.inside(box.url("plain.tar"))).isEmpty)

        // Nothing here continues a file.
        for provider in [bench.zip, bench.readOnly] {
            #expect(!provider.capabilities.contains(.append) && !provider.capabilities(for: root).contains(.append))
        }
        #expect(throws: FileSystemError.self) {
            _ = try bench.zip.append(
                to: root.appending(name: "tree/readme.txt"),
                at: nil,
                cancellation: CancellationFlag()
            )
        }
    }

    /// A place outside the archive answers with the capabilities of its own file system, and can be continued and
    /// committed there.
    @Test
    internal func aPlaceOutsideTheArchiveAnswersForItsOwnFileSystem() throws {
        let archive = try makeZip()
        let root = bench.inside(archive)
        let local = try outside(root, box.url("elsewhere.txt").path)
        #expect(bench.zip.capabilities(for: local) == bench.fileSystems.capabilities(for: box.url("elsewhere.txt")))

        // On a server that can continue files, the archive scheme can too, for places outside.
        bench.memory.capabilitiesAt = { _ in [.write, .append, .deferredWrites] }
        _ = bench.memory.addFile("/store/log.txt", "start")
        let onServer = bench.memory.url("/store/tree.zip")
        let serverRoot = ArchiveURL.make(scheme: "zip", archive: onServer, innerPath: "")
        let place = try outside(serverRoot, "/store/log.txt")
        #expect(bench.zip.capabilities(for: place) == [.write, .append, .deferredWrites])
        let appender = try bench.zip.append(to: place, at: nil, cancellation: CancellationFlag())
        try appender.write(Data(" more".utf8))
        try appender.close(attributes: FileAttributes())
        #expect(bench.memory.contents("/store/log.txt") == "start more")
        try bench.zip.commit(place, cancellation: CancellationFlag())
        #expect(bench.memory.commits == ["/store/log.txt"])
    }

    /// An archive on a server that cannot be written to cannot be changed, until the server can be written to.
    @Test
    internal func anArchiveOnAServerThatCannotBeWrittenToCannotBeChanged() throws {
        let tree = try bench.makeTree()
        let onServer = bench.memory.url("/store/tree.zip")
        try bench.pack([tree], to: onServer)
        bench.store.close()
        bench.memory.capabilitiesAt = { _ in [] }
        let root = ArchiveURL.make(scheme: "zip", archive: onServer, innerPath: "")
        _ = try bench.names(root)
        #expect(bench.zip.capabilities(for: root).isEmpty)
        #expect(throws: ArchiveError.self) { _ = try bench.zip.write(root.appending(name: "new.txt")) }
        bench.memory.capabilitiesAt = { _ in [.write] }
        #expect(bench.zip.capabilities(for: root) == [.write, .deferredWrites])
        try write("late", to: root.appending(name: "late.txt"))
    }
}
