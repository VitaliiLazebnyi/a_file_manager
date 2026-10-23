import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Review round 2: the temporary folder, room on its volume, and how deep archives nest.
@Suite
internal struct Review2ArchivesScratchTests: ArchiveFixSuite {
    /// The archive file systems in a sandbox of their own.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// What a crashed run left in the temporary folder is swept; what was kept, and others' files, stay (A040).
    @Test
    internal func whatACrashLeftBehindIsSweptAndWhatWasKeptStays() throws {
        let parent = try box.folder("tmp")
        // The number of a process that has ended.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let dead = process.processIdentifier
        let stale = parent.appendingPathComponent("\(ScratchFolder.prefix)\(dead)-AAAA")
        let kept = parent.appendingPathComponent("\(ScratchFolder.prefix)\(dead)-BBBB")
        let alive = parent.appendingPathComponent("\(ScratchFolder.prefix)\(getpid())-CCCC")
        for folder in [stale, kept, alive] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data().write(to: kept.appendingPathComponent("kept-unsaved-changes"))
        let outside = try box.folder("elsewhere")
        let leftover = outside.appendingPathComponent(".1234.afm-zip.tmp")
        let spool = outside.appendingPathComponent(".afm-spool-\(dead)-X")
        let innocent = outside.appendingPathComponent("document.txt")
        try Data("x".utf8).write(to: leftover)
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: innocent)
        try Data("\(leftover.path)\n\(spool.path)\n\(innocent.path)\n".utf8)
            .write(
                to: URL(fileURLWithPath: stale.path + ".external")
            )
        ScratchFolder.sweepLeftovers(in: parent)
        let files = FileManager.default
        #expect(!files.fileExists(atPath: stale.path) && !files.fileExists(atPath: stale.path + ".external"))
        #expect(files.fileExists(atPath: kept.path) && files.fileExists(atPath: alive.path))
        // Only what carries one of the plugin's own temporary names is removed outside.
        #expect(
            !files.fileExists(atPath: leftover.path) && !files.fileExists(atPath: spool.path)
                && files.fileExists(atPath: innocent.path)
        )

        // The folder is the user's alone, and so is what is written into it.
        let scratch = ScratchFolder(in: parent)
        let file = try scratch.newFile("tmp")
        try OutputFile(creating: file, mode: 0o600).close(durably: false)
        #expect((try files.attributesOfItem(atPath: scratch.url.path)[.posixPermissions] as? Int) == 0o700)
        #expect((try files.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
        scratch.removeAll()
        #expect(!files.fileExists(atPath: scratch.url.path))
    }

    /// Without room on the temporary volume no copy is made: streams are read as they are, fetching is refused.
    @Test
    internal func noCopyIsMadeWhenTheTemporaryVolumeHasNoRoomToSpare() throws {
        try bench.makeTree("tree")
        #expect(runTool("/usr/bin/tar", ["-czf", "tree.tgz", "tree"], in: box.root).status == 0)
        #expect(runTool("/usr/bin/zip", ["-qr", "tree.zip", "tree"], in: box.root).status == 0)
        bench.environment.hasRoom = { _, _ in false }
        // A stream archive is listed and read from the stream, without its unpacked copy.
        let inner = bench.inside(box.url("tree.tgz"), "tree", scheme: ArchiveURL.readOnlyScheme)
        #expect(try bench.names(inner, showHidden: true).contains("big.log"))
        let opened = try bench.store.archive(at: box.url("tree.tgz"), cancellation: nil)
        #expect(!opened.allowsParallelReads && opened.scratchBytes == 0)
        #expect(try bench.read(inner.appending(name: "readme.txt")) == Data(contentsOf: box.url("tree/readme.txt")))
        // An archive that would have to be fetched is refused with a message that says why.
        let onServer = bench.memory.url("/store/tree.zip")
        bench.memory.createDirectory(at: bench.memory.url("/store"))
        let writer = try bench.memory.write(onServer)
        try writer.write(try Data(contentsOf: box.url("tree.zip")))
        try writer.close(attributes: FileAttributes())
        #expect { try bench.store.archive(at: onServer, cancellation: nil) } throws: { error in
            if case ArchiveError.noScratchRoom = error {
                return true
            }
            return false
        }
        // That says nothing about the file: with room it opens at once.
        bench.environment.hasRoom = { _, _ in true }
        #expect(
            try bench.names(bench.inside(onServer, "tree", scheme: ArchiveURL.writableScheme), showHidden: true)
                .contains("readme.txt")
        )
    }

    /// Archives inside archives open only as deep as the environment allows.
    @Test
    internal func archivesNestOnlySoDeep() throws {
        try bench.makeTree("tree")
        #expect(runTool("/usr/bin/zip", ["-qr", "inner.zip", "tree"], in: box.root).status == 0)
        #expect(runTool("/usr/bin/zip", ["-q", "outer.zip", "inner.zip"], in: box.root).status == 0)
        let inner = bench.inside(box.url("outer.zip"), "inner.zip", scheme: ArchiveURL.writableScheme)
        #expect(ArchiveURL.nesting(of: box.url("outer.zip")) == 0 && ArchiveURL.nesting(of: inner) == 1)
        #expect(
            try bench.names(bench.inside(inner, "tree", scheme: ArchiveURL.writableScheme), showHidden: true)
                .contains("readme.txt")
        )
        bench.store.close()
        bench.environment.maxNesting = 1
        #expect(throws: ArchiveError.self) {
            try bench.names(bench.inside(inner, "tree", scheme: ArchiveURL.writableScheme), showHidden: true)
        }
    }
}
