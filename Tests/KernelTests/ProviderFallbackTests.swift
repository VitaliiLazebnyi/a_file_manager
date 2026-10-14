import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// What a file system and an entry need not offer and still have (review 2, cross-requests): the
/// kernel's defaults for the calls with a flag, flushers, and what an entry says about links.
@Suite
internal struct ProviderFallbackTests {
    /// The calls with a flag work as the plain ones while the flag is clear and refuse once it is
    /// set; exclusive folders, volumes, real locations and the read order have defaults.
    @Test
    internal func whatAFileSystemNeedNotOfferHasADefault() throws {
        let memory = MemoryFileSystem(scheme: "mem")
        memory.addFile("/a/x.txt")
        let live = CancellationFlag()
        let cancelled = CancellationFlag()
        cancelled.cancel()
        try memory.createDirectory(at: memory.url("/a/new"), cancellation: live)
        try memory.move(memory.url("/a/x.txt"), to: memory.url("/a/y.txt"), replacing: false, cancellation: live)
        #expect(memory.exists("/a/new"))
        #expect(memory.exists("/a/y.txt"))
        #expect(throws: (any Error).self) { try memory.remove(memory.url("/a/y.txt"), cancellation: cancelled) }
        #expect(throws: (any Error).self) {
            try memory.createDirectory(at: memory.url("/a/never"), cancellation: cancelled)
        }
        #expect(memory.exists("/a/y.txt"))
        #expect(!memory.exists("/a/never"))
        try memory.remove(memory.url("/a/y.txt"), cancellation: live)
        #expect(!memory.exists("/a/y.txt"))
        // A folder that must be new.
        try memory.createDirectory(at: memory.url("/a/fresh"), exclusive: true)
        #expect(throws: (any Error).self) { try memory.createDirectory(at: memory.url("/a/fresh"), exclusive: true) }
        try memory.createDirectory(at: memory.url("/a/fresh"), exclusive: false)
        #expect(memory.volume(of: memory.url("/a"), cancellation: cancelled) == nil)
        #expect(memory.realLocation(of: memory.url("/a")) == nil)
        #expect(!memory.connectsToServer)
        #expect(memory.readOrder(of: [memory.url("/b"), memory.url("/a")]) == [memory.url("/b"), memory.url("/a")])
    }

    /// Whoever keeps changes to a file back is asked to write them before the file is used; a
    /// flusher that fails makes the flush fail; the registry knows the real location.
    @Test
    internal func pendingWritesAreFlushedBeforeAFileIsUsed() throws {
        let memory = MemoryFileSystem(scheme: "mem")
        let registry = FileSystemRegistry()
        registry.register(memory)
        let live = CancellationFlag()
        // The flushers run on this thread, inside the calls below.
        nonisolated(unsafe) var flushed: [String] = []
        registry.addFlusher { url, _ in flushed.append(url.lastPathComponent) }
        registry.addFlusher { url, flag in
            if url.lastPathComponent == "bad" || flag.isCancelled {
                throw FileSystemError.notSupported("Flushing")
            }
        }
        try registry.flushPendingWrites(to: memory.url("/a/archive.zip"), cancellation: live)
        #expect(flushed == ["archive.zip"])
        #expect(throws: (any Error).self) {
            try registry.flushPendingWrites(to: memory.url("/a/bad"), cancellation: live)
        }
        #expect(registry.realLocation(of: memory.url("/a")) == memory.url("/a"))
    }

    /// An entry carries the size of its link's target and its device, which count for equality
    /// but not for being the same entry; two names of one file, hard or followed soft, are one file.
    @Test
    internal func anEntryCanSayWhatItsLinkPointsToAndWhereItLives() throws {
        let folder = URL(fileURLWithPath: "/review2/requests")
        var item = Fixture.file("link", in: folder)
        #expect(item.linkTargetSize == nil)
        #expect(item.device == nil)
        item.linkTargetSize = 0
        item.device = 16_777_233
        #expect(item.linkTargetSize == 0)
        #expect(item.device == 16_777_233)
        #expect(item != Fixture.file("link", in: folder))
        let made = FileItem(url: folder, name: "x", isDirectory: false, linkTargetSize: 77, device: -3)
        #expect(made.linkTargetSize == 77)
        #expect(made.device == -3)
        #expect(made.isSameEntry(as: FileItem(url: folder, name: "x", isDirectory: false)))
        // The same file under two names.
        let sandbox = try Sandbox()
        let original = try sandbox.file("a/original.txt")
        let other = try sandbox.file("a/other.txt")
        try FileManager.default.linkItem(at: original, to: sandbox.url("a/hard.txt"))
        try FileManager.default.createSymbolicLink(at: sandbox.url("a/soft.txt"), withDestinationURL: original)
        #expect(original.isSameFile(as: sandbox.url("a/hard.txt")))
        #expect(original.isSameFile(as: sandbox.url("a/../a/original.txt")))
        #expect(!original.isSameFile(as: other))
        #expect(!original.isSameFile(as: sandbox.url("a/none.txt")))
        #expect(!original.isSameFile(as: sandbox.url("a/soft.txt")))
        #expect(original.isSameFile(as: sandbox.url("a/soft.txt"), followingLinks: true))
        let remote = try #require(URL(string: "ftp://h/a"))
        #expect(remote.isSameFile(as: try #require(URL(string: "ftp://h/a/"))))
    }
}
