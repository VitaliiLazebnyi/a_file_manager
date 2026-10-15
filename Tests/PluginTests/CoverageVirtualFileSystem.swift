import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import VirtualFoldersPlugin

/// The virtual file system asked directly, beyond the other suites: the changing calls that go
/// through to the real files, listings that are cancelled or refused, locations that are not
/// its own, and the surroundings of its folders.
@Suite
internal struct CoverageVirtualFileSystem {
    /// The real files: `/A` with a file and a folder, `/B` empty.
    private let memory = MemoryFileSystem()
    /// The memory files behind a layer that can watch and fail.
    private let files: CoverageSmallFiles
    /// Another file system of its own scheme.
    private let other = MemoryFileSystem(scheme: "disk")
    /// The file systems, the virtual one among them.
    private let fileSystems = FileSystemRegistry()
    /// The file system under test.
    private let virtual: VirtualFileSystem

    /// The files and the registry.
    internal init() {
        memory.addFile("/A/one.txt", "1")
        memory.addFile("/A/sub/two.txt", "22")
        memory.addDirectory("/B")
        other.addFile("/D/x.txt", "x")
        files = CoverageSmallFiles(memory)
        fileSystems.register(files)
        fileSystems.register(other)
        virtual = VirtualFileSystem(fileSystems: fileSystems)
        fileSystems.register(virtual)
    }

    /// The location below the branch view of a real memory path.
    private func below(_ path: String) -> URL {
        VirtualLocation.branch(of: memory.url(path)).url
    }

    /// Every listing of `url`, gathered.
    private func names(_ url: URL) throws -> [String] {
        try virtual.list(url, showHidden: false).map(\.name)
    }

    /// Writing, reading, moving, copying, changing and removing go to the real files.
    @Test
    internal func changesGoToTheRealFiles() throws {
        try virtual.createDirectory(at: below("/A/new"))
        let writer = try virtual.write(below("/A/new/n.txt"))
        try writer.write(Data("abc".utf8))
        try writer.close(attributes: FileAttributes())
        let reader = try virtual.read(below("/A/new/n.txt"))
        #expect(try reader.read(upToCount: 10) == Data("abc".utf8))
        let flagged = try virtual.read(below("/A/new/n.txt"), cancellation: CancellationFlag())
        #expect(try flagged.read(upToCount: 10) == Data("abc".utf8))
        try virtual.move(below("/A/new/n.txt"), to: below("/A/m.txt"), replacing: false)
        try virtual.copy(below("/A/m.txt"), to: below("/A/c.txt")) { _ in true }
        try virtual.setAttributes(FileAttributes(permissions: 0o600), of: below("/A/c.txt"))
        #expect(memory.contents("/A/c.txt") == "abc" && files.changedAttributes == ["/A/c.txt"])
        try virtual.remove(below("/A/c.txt"))
        #expect(!memory.exists("/A/c.txt") && !memory.exists("/A/new/n.txt") && memory.exists("/A/m.txt"))
        files.fails = [.remove]
        #expect(throws: CoverageSmallFiles.Failure.self) { try virtual.trash(below("/A/m.txt")) }
    }

    /// Moving or copying between two file systems is for the caller to do; a list cannot be
    /// changed, and a location that is not virtual is not this file system's.
    @Test
    internal func whatCannotBeChanged() {
        let elsewhere = VirtualLocation.branch(of: other.url("/D/y.txt")).url
        let moved = #expect(throws: FileSystemError.self) {
            try virtual.move(below("/A/one.txt"), to: elsewhere, replacing: false)
        }
        let copied = #expect(throws: FileSystemError.self) {
            try virtual.copy(below("/A/one.txt"), to: elsewhere) { _ in true }
        }
        for error in [moved, copied] {
            guard case .crossesVolumes? = error else {
                Issue.record("not refused as crossing volumes: \(String(describing: error))")
                continue
            }
        }
        let list = virtual.register(files: [memory.url("/A/one.txt")], title: "Found", origin: nil)
        #expect(throws: (any Error).self) { try virtual.remove(list) }
        #expect(throws: (any Error).self) { try virtual.read(memory.url("/A/one.txt")) }
        #expect(throws: (any Error).self) { try virtual.copyMetadata(from: list, to: below("/A/one.txt")) }
    }

    /// Metadata comes from a real location as well as from a virtual one; a list has nothing to
    /// make durable or to say about quarantine, and is measured by listing it.
    @Test
    internal func metadataCommitsQuarantineAndSizes() throws {
        memory.keepsMetadata = true
        try virtual.copyMetadata(from: memory.url("/A/one.txt"), to: below("/A/sub/two.txt"))
        let list = virtual.register(files: [memory.url("/A/one.txt")], title: "Found", origin: nil)
        try virtual.commit(list, cancellation: CancellationFlag())
        try virtual.commit(below("/A"), cancellation: CancellationFlag())
        #expect(memory.commits == ["/A"])
        #expect(virtual.quarantine(of: list) == nil)
        #expect(virtual.totalSize(of: list, cancellation: CancellationFlag()) == 1)
        #expect(virtual.totalSize(of: below("/A"), cancellation: CancellationFlag()) == 3)
    }

    /// What is not a virtual folder, or not one with entries of its own, has none; a list that
    /// was forgotten is judged like every virtual folder.
    @Test
    internal func locationsWithoutEntries() throws {
        #expect(virtual.entries(of: memory.url("/A")) == nil && virtual.entries(of: below("/A")) == nil)
        let forgotten = VirtualLocation.list(id: 1, title: "Gone", origin: nil).url
        #expect(virtual.capabilities(for: forgotten) == virtual.capabilities)
        #expect(throws: (any Error).self) { try names(memory.url("/A")) }
        let picked = VirtualLocation.picked(id: 1, in: memory.url("/A")).url
        #expect(throws: VirtualFileSystem.ForgottenList.self) { try names(picked) }
    }

    /// The items of virtual locations: a folder below a branch is a virtual folder, a file is
    /// the real file, a list is its title, and anything else is nothing of this file system's.
    @Test
    internal func itemsOfVirtualLocations() throws {
        let folder = try #require(virtual.item(at: below("/A/sub")))
        #expect(folder.url == below("/A/sub") && folder.isDirectory)
        #expect(virtual.item(at: below("/A/one.txt"))?.url == memory.url("/A/one.txt"))
        let list = virtual.register(files: [], title: "Found", origin: nil)
        #expect(virtual.item(at: list)?.name == "Found" && virtual.item(at: memory.url("/A")) == nil)
        #expect(virtual.displayPath(memory.url("/A")) == memory.url("/A").absoluteString)
        #expect(virtual.volume(of: memory.url("/A")) == nil)
        let gone = VirtualLocation.list(id: 2, title: "Gone", origin: nil).url
        #expect(virtual.volume(of: gone)?.isLocal == true)
    }

    /// What `displayPath` writes reads back, for lists and selected branches; other texts that
    /// look alike do not.
    @Test
    internal func displayPathsReadBack() {
        let picked = virtual.registerPicked([memory.url("/A/one.txt")], in: memory.url("/A"))
        let list = virtual.register(files: [memory.url("/A/one.txt")], title: "Found", origin: nil)
        #expect(virtual.location(from: virtual.displayPath(picked)) == picked)
        #expect(virtual.location(from: virtual.displayPath(list)) == list)
        #expect(virtual.location(from: "Other " + virtual.displayPath(list)) == nil)
        #expect(virtual.location(from: " (branch)") == nil && virtual.location(from: "vfolder:nothing") == nil)
        #expect(virtual.location(from: "Found (other 5)") == nil)
    }

    /// Files of other servers are told apart by host and port.
    @Test
    internal func filesOfOtherServersAreToldApart() throws {
        let servers = try ["sftp://h:22/x", "sftp://h:2222/x", "sftp://g:22/x", "sftp://h:22/x"]
            .map { try #require(URL(string: $0)) }
        let list = virtual.register(files: servers, title: "Servers", origin: nil)
        #expect(virtual.entries(of: list)?.count == 3)
    }

    /// When every remembered list is shown, none is forgotten for a new one.
    @Test
    internal func shownListsAreNotForgotten() {
        files.watches = true
        var tokens: [any WatchToken] = []
        var lists: [URL] = []
        for index in 0..<VirtualFileSystem.listLimit {
            let list = virtual.register(files: [memory.url("/A/one.txt")], title: "L\(index)", origin: nil)
            lists.append(list)
            tokens += [virtual.watch([list]) { _ in /* nothing */ }].compactMap(\.self)
        }
        _ = virtual.register(files: [memory.url("/A/one.txt")], title: "One more", origin: nil)
        #expect(tokens.count == lists.count && lists.allSatisfy { virtual.entries(of: $0) != nil })
    }

    /// Items go to the Trash on the file system they are on.
    @Test
    internal func itemsGoToTheTrashOfTheirFileSystem() throws {
        try virtual.trash(below("/A/one.txt"))
        #expect(!memory.exists("/A/one.txt") && files.trashed == ["/A/one.txt"])
    }

    /// Listings that are cancelled, or whose receiver wants no more, end; files that are not
    /// there or of no file system are left out.
    @Test
    internal func listingsThatEndEarly() throws {
        let picked = virtual.registerPicked([memory.url("/A/one.txt"), memory.url("/A/sub")], in: memory.url("/A"))
        let list = virtual.register(
            files: [memory.url("/A/one.txt"), try #require(URL(string: "zzz:/x")), try #require(URL(string: "a.txt"))],
            title: "Found",
            origin: nil
        )
        let cancelled = CancellationFlag()
        cancelled.cancel()
        for url in [picked, list] {
            #expect(try virtual.list(url, showHidden: false, cancellation: cancelled).isEmpty)
            var batches = 0
            try virtual.list(url, showHidden: false) { _ in
                batches += 1
                return false
            }
            #expect(batches == 1)
        }
        #expect(try names(list) == [memory.displayPath(memory.url("/A/one.txt"))])
    }

    /// Many virtual folders read one after the other are all remembered as far as is useful.
    @Test
    internal func manyFoldersReadOneAfterTheOther() throws {
        for index in 0..<33 {
            memory.addFile("/M/f\(index)/a.txt")
            #expect(try names(below("/M/f\(index)")) == ["a.txt"])
        }
        #expect(virtual.capabilities.contains(.write))
    }
}
