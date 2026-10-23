import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Review round 2, second pass: the kernel's hooks for the read order and for bringing a file up to date
/// (A041, A044).
@MainActor
@Suite
internal struct Review2ArchivesP2HookTests: ArchiveFixSuite {
    /// The archive file systems in a sandbox of their own.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// Members of a stream archive are read in the order they lie in it, in one pass (A041).
    @Test
    internal func membersOfAStreamArchiveAreReadInTheOrderTheyLieInIt() throws {
        try bench.makeTree("tree")
        for index in 0..<12 { try box.file("tree/many/file\(index).txt", "contents of \(index)") }
        try bench.pack([box.url("tree")], to: box.url("stream.tar.gz"), innerFolder: "") { options in
            options.format = .compressedTar(.gzip)
        }
        try bench.pack([box.url("tree")], to: box.url("plain.zip"), innerFolder: "") { $0.format = .zip }
        // Too large for a temporary copy: every read goes through the stream.
        bench.environment.materializeLimit = 0
        let stream = try bench.store.archive(at: box.url("stream.tar.gz"), cancellation: nil)
        #expect(!stream.allowsParallelReads)
        let folder = bench.inside(box.url("stream.tar.gz"), "tree/many", scheme: ArchiveURL.readOnlyScheme)
        let inArchive = try stream.children(of: "tree/many")
            .sorted { $0.order < $1.order }
            .map { entry in folder.appending(name: entry.name) }
        // Whatever order they come in (by name, backwards), they go out in the archive's.
        let other = URL(fileURLWithPath: "/somewhere/else.txt")
        let ordered = bench.readOnly.readOrder(of: [other] + inArchive.reversed())
        #expect(ordered == [other] + inArchive)
        #expect(
            bench.readOnly.readOrder(of: inArchive.sorted { $0.lastPathComponent < $1.lastPathComponent }) == inArchive
        )
        // Read that way, the archive is gone through once.
        let before = stream.streamStarts
        for url in ordered.dropFirst() { #expect(try bench.read(url).starts(with: Data("contents of ".utf8))) }
        #expect(stream.streamStarts - before == 1)
        // An archive that is read at any place keeps the order it was asked in.
        _ = try bench.store.archive(at: box.url("plain.zip"), cancellation: nil)
        let zipFolder = bench.inside(box.url("plain.zip"), "tree/many", scheme: ArchiveURL.writableScheme)
        let asked = (0..<12).reversed().map { zipFolder.appending(name: "file\($0).txt") }
        #expect(bench.zip.readOrder(of: asked) == asked)
    }

    /// A stream that ends before every member it was to deliver came is an error (A090).
    @Test
    internal func aStreamThatEndsBeforeEveryMemberCameIsAnError() throws {
        // (A090.) The archive is listed, then cut short where it lies: a pass that is to
        // deliver members the stream no longer holds must say so, not return as if done.
        try bench.makeTree("tree")
        for index in 0..<8 { try box.file("tree/many/file\(index).txt", "contents of \(index)") }
        try box.file("little/only.txt", "only")
        try bench.pack([box.url("tree")], to: box.url("full.tar.gz"), innerFolder: "") { options in
            options.format = .compressedTar(.gzip)
        }
        try bench.pack([box.url("little")], to: box.url("short.tar.gz"), innerFolder: "") { options in
            options.format = .compressedTar(.gzip)
        }
        bench.environment.materializeLimit = 0
        let archive = try bench.store.archive(at: box.url("full.tar.gz"), cancellation: nil)
        let wanted = archive.entries.filter { !$0.isDirectory }
        #expect(wanted.count > 8 && !archive.allowsParallelReads)
        var delivered = 0
        try archive.readInOnePass(wanted, cancellation: nil, throughTheEnd: false) { _, stream in
            while try stream.read(upToCount: 1 << 16) != nil {
                // Read to the member's end.
            }
            delivered += 1
        }
        #expect(delivered == wanted.count)
        // The same file, other contents (the archive holds it open).
        let handle = try FileHandle(forWritingTo: box.url("full.tar.gz"))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: try Data(contentsOf: box.url("short.tar.gz")))
        try handle.close()
        delivered = 0
        #expect(throws: (any Error).self) {
            try archive.readInOnePass(wanted, cancellation: nil, throughTheEnd: false) { _, stream in
                while try stream.read(upToCount: 1 << 16) != nil {
                    // Read to the member's end.
                }
                delivered += 1
            }
        }
        #expect(delivered < wanted.count)
    }

    /// An archive file, its folder, or an archive around it is written before somebody else uses it (A044).
    @Test
    internal func aFileIsBroughtUpToDateBeforeSomebodyElseUsesIt() throws {
        let archive = try makeZip()
        let store = bench.store
        bench.fileSystems.addFlusher { url, cancellation in try store.bringUpToDate(url, cancellation: cancellation) }
        let flag = CancellationFlag()
        try write("waiting", to: bench.inside(archive, "tree/waiting.txt", scheme: ArchiveURL.writableScheme))
        #expect(store.hasPendingChanges && !listed(archive).contains("tree/waiting.txt"))
        // Another file: nothing happens, and nothing is opened for it.
        try bench.fileSystems.flushPendingWrites(to: box.url("tree/readme.txt"), cancellation: flag)
        try bench.fileSystems.flushPendingWrites(to: box.url("other.zip"), cancellation: flag)
        #expect(store.hasPendingChanges && store.openArchive(at: box.url("other.zip")) == nil)
        // The archive file itself.
        try bench.fileSystems.flushPendingWrites(to: archive, cancellation: flag)
        #expect(!store.hasPendingChanges && listed(archive).contains("tree/waiting.txt"))
        // The folder it lies in (which is about to be moved or deleted).
        try write("again", to: bench.inside(archive, "tree/again.txt", scheme: ArchiveURL.writableScheme))
        try bench.fileSystems.flushPendingWrites(to: box.root, cancellation: flag)
        #expect(!store.hasPendingChanges && listed(archive).contains("tree/again.txt"))
        // An archive inside it: both are written, the inner one first.
        #expect(runTool("/usr/bin/zip", ["-q0", "outer.zip", "tree.zip"], in: box.root).status == 0)
        let inner = bench.inside(box.url("outer.zip"), "tree.zip", scheme: ArchiveURL.writableScheme)
        try write("deep", to: bench.inside(inner, "tree/deep.txt", scheme: ArchiveURL.writableScheme))
        try bench.fileSystems.flushPendingWrites(to: box.url("outer.zip"), cancellation: flag)
        #expect(!store.hasPendingChanges)
        #expect(
            runTool("/usr/bin/unzip", ["-qo", box.url("outer.zip").path, "-d", box.url("check").path], in: nil).status
                == 0
        )
        #expect(listed(box.url("check/tree.zip")).contains("tree/deep.txt"))
        // A write that cannot be made is the caller's to know of: the file is not what is shown.
        try write("late", to: bench.inside(archive, "tree/late.txt", scheme: ArchiveURL.writableScheme))
        flag.cancel()
        #expect(throws: (any Error).self) { try bench.fileSystems.flushPendingWrites(to: archive, cancellation: flag) }
        #expect(store.hasPendingChanges)
    }
}
