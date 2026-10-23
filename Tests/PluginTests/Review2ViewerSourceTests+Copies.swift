import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// The temporary copies for the players: safe names, files kept inside their folder, size limits and removal.
extension Review2ViewerSourceTests {
    // MARK: Temporary copies

    /// The name of a temporary copy is one safe path component of at most 255 bytes, its extension kept.
    @Test
    internal func theNameOfACopyIsOneSafeComponent() {
        for name in [
            "..", ".", "", "../../x", "a/b", "a\\b", "x:y", "..%2F..%2Fx", "\u{0}evil",
            String(repeating: "n", count: 400) + ".mov"
        ] {
            let safe = TemporaryCopies.safeName(name)
            #expect(
                !safe.isEmpty && safe != "." && safe != ".." && !safe.contains("/") && !safe.contains(":")
                    && !safe.contains("\u{0}"),
                "\(name.debugDescription) -> \(safe.debugDescription)"
            )
            #expect(safe.utf8.count <= 255)
        }
        #expect(TemporaryCopies.safeName("../../x") == "_.._.._x")
        #expect(TemporaryCopies.safeName("movie.mp4") == "movie.mp4")
        #expect(TemporaryCopies.safeName(String(repeating: "n", count: 400) + ".mov").hasSuffix(".mov"))
    }

    /// A name with encoded separators is copied into its own folder, not beside it.
    @Test
    internal func aNameWithEncodedSeparatorsStaysInsideItsFolder() throws {
        let provider = Review2HookProvider()
        // As a server sends it: the last component is "../../escape.mp4" once decoded.
        let url = try #require(URL(string: "hook:///a/..%2F..%2Fescape.mp4"))
        #expect(url.lastPathComponent == "../../escape.mp4")
        provider.contents[url.path] = Data("payload".utf8)
        let registry = FileSystemRegistry()
        registry.register(provider)
        let copies = TemporaryCopies()
        defer { copies.removeAll() }
        let copy = try #require(copies.localURL(for: url, fileSystems: registry, cancellation: CancellationFlag()))
        let folder = copy.deletingLastPathComponent().standardizedFileURL
        #expect(copy.standardizedFileURL.deletingLastPathComponent() == folder && !copy.lastPathComponent.contains("/"))
        #expect(try String(contentsOf: copy, encoding: .utf8) == "payload")
        let root = folder.deletingLastPathComponent().deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.mp4").path))
    }

    /// A file too big to copy is refused before a reader is opened.
    @Test
    internal func aFileTooBigToCopyIsRefusedBeforeAByteIsRead() throws {
        let huge = try #require(URL(string: "hook:///huge.mov"))
        let registry = FileSystemRegistry()
        let provider = Review2HookProvider()
        provider.sizes["/huge.mov"] = 50 << 30
        registry.register(provider)
        let copies = TemporaryCopies()
        defer { copies.removeAll() }
        let result = copies.localCopy(
            for: huge,
            fileSystems: registry,
            cancellation: CancellationFlag()
        )
        if case .failure(let refusal) = result {
            #expect(refusal == .tooLarge(50 << 30, limit: 1 << 30) && refusal.message.contains("too large"))
        } else {
            Issue.record("copied")
        }
        #expect(provider.closeCount == 0)
    }

    /// A copy made again after all copies were removed is a new file, not the removed entry.
    @Test
    internal func aCopyIsNotRegisteredForAPaneThatLetGoMeanwhileOrAfterRemoveAll() throws {
        let memory = MemoryFileSystem()
        let registry = FileSystemRegistry()
        registry.register(memory)
        let url = memory.addFile("/a/clip.mp4", String(repeating: "c", count: 1_000))
        let copies = TemporaryCopies()
        defer { copies.removeAll() }
        let owner = ObjectIdentifier(copies)
        let first = try #require(
            copies.localURL(for: url, fileSystems: registry, owner: owner, cancellation: CancellationFlag())
        )
        copies.removeAll()
        copies.waitForCleanup()
        // The folder is gone with its entry: copying again makes a new one.
        #expect(!FileManager.default.fileExists(atPath: first.path))
        let second = try #require(
            copies.localURL(for: url, fileSystems: registry, owner: owner, cancellation: CancellationFlag())
        )
        #expect(FileManager.default.fileExists(atPath: second.path))
    }
}
