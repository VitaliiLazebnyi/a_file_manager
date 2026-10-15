import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Archives the store lets go (the least recently used, temporary copies beyond the budget),
/// folders brought up to date, and changes that meet an archive the store has just let go.
@Suite
internal struct CoverageArchivesFSLettingGoTests {
    private let bench: ArchiveBench
    private let hooked = CoverageArchivesFSHookedMemory()
    private let zipBytes: Data

    private var box: Sandbox { bench.box }
    private var store: ArchiveStore { bench.store }
    private var memory: MemoryFileSystem { bench.memory }

    /// The archive file systems over the disk, a memory file system and a hooked one, and the
    /// bytes of a small ZIP.
    internal init() throws {
        bench = try ArchiveBench()
        bench.fileSystems.register(hooked)
        try bench.box.file("tree/readme.txt", "read me")
        #expect(runTool("/usr/bin/zip", ["-qr", "tree.zip", "tree"], in: bench.box.root).status == 0)
        zipBytes = try Data(contentsOf: bench.box.url("tree.zip"))
    }

    /// Beyond twelve, the least recently used archives are let go, also the remembered
    /// failure of a file that was no archive; an archive that is being opened is passed over.
    @Test
    internal func theLeastRecentlyUsedArchivesAreLetGo() throws {
        let junk = try box.file("junk.zip", "no archive")
        #expect(throws: ArchiveError.self) { _ = try store.archive(at: junk) }
        let remote = try CoverageArchivesFSHookedMemory.put(zipBytes, at: "/store/tree.zip", on: memory)
        memory.stallsReads = true
        let (shared, first) = (store, Signal<Result<OpenArchive, any Error>>())
        Thread.detachNewThread {
            first.set(Result { try shared.archive(at: remote) })
        }
        #expect(Wait.until { memory.stalledTransfers == 1 })
        var locals: [URL] = []
        for index in 0..<12 {
            let url = box.url("copy\(index).zip")
            try zipBytes.write(to: url)
            locals.append(url)
            _ = try store.archive(at: url)
        }
        memory.releaseStalls()
        let opened = try #require(try first.wait()?.get())
        // The one that was being opened is still there; the oldest of the others went.
        #expect(store.openArchive(at: remote) === opened)
        #expect(store.openArchive(at: locals[0]) == nil && store.openArchive(at: locals[11]) != nil)
    }

    /// Temporary copies beyond the budget are let go, least recently used first.
    @Test
    internal func temporaryCopiesBeyondTheBudgetAreLetGo() throws {
        bench.environment.scratchBudget = 0
        let first = try CoverageArchivesFSHookedMemory.put(zipBytes, at: "/store/one.zip", on: memory)
        let second = try CoverageArchivesFSHookedMemory.put(zipBytes, at: "/store/two.zip", on: memory)
        _ = try store.archive(at: first)
        _ = try store.archive(at: second)
        #expect(store.openArchive(at: first) == nil && store.openArchive(at: second) != nil)
    }

    /// Bringing a folder up to date writes the archives inside archives first.
    @Test
    internal func bringingAFolderUpToDateWritesInnerArchivesFirst() throws {
        try FileManager.default.copyItem(at: box.url("tree.zip"), to: box.url("tree/inner.zip"))
        #expect(runTool("/usr/bin/zip", ["-qr", "outer.zip", "tree"], in: box.root).status == 0)
        let outer = box.url("outer.zip")
        let inner = bench.inside(outer, "tree/inner.zip")
        for url in [bench.inside(outer, "tree/outer-new.txt"), bench.inside(inner, "tree/inner-new.txt")] {
            let writer = try bench.zip.write(url)
            try writer.write(Data("new".utf8))
            try writer.close(attributes: FileAttributes())
        }
        #expect(store.hasPendingChanges)
        try store.bringUpToDate(box.root, cancellation: CancellationFlag())
        #expect(!store.hasPendingChanges)
        #expect(runTool("/usr/bin/unzip", ["-Z1", outer.path]).output.contains("tree/outer-new.txt"))
        let unpacked = runTool("/usr/bin/unzip", ["-qo", outer.path, "tree/inner.zip", "-d", box.url("out").path])
        #expect(unpacked.status == 0)
        let listed = runTool("/usr/bin/unzip", ["-Z1", box.url("out/tree/inner.zip").path]).output
        #expect(listed.contains("tree/inner-new.txt"))
    }

    /// A change that meets an archive the store has just let go is made in the archive the
    /// store has now, and so is a move whose two ends were looked up across the change.
    @Test
    internal func aChangeThatMeetsAnArchiveThatWasLetGoIsMadeAgain() throws {
        let url = try CoverageArchivesFSHookedMemory.put(zipBytes, at: "/store/tree.zip", on: hooked.base)
        _ = try store.archive(at: url)
        let shared = store
        hooked.onNextItem { shared.release(on: url) }
        try bench.zip.createDirectory(at: bench.inside(url, "tree/made"))
        #expect(try bench.names(bench.inside(url, "tree")) == ["made", "readme.txt"])

        // (Another archive: the server is asked about each at most once a second.)
        let other = try CoverageArchivesFSHookedMemory.put(zipBytes, at: "/store/other.zip", on: hooked.base)
        _ = try store.archive(at: other)
        hooked.onNextItem { shared.release(on: other) }
        try bench.zip.move(
            bench.inside(other, "tree/readme.txt"),
            to: bench.inside(other, "tree/moved.txt"),
            replacing: false
        )
        #expect(try bench.names(bench.inside(other, "tree")) == ["moved.txt"])
    }
}
