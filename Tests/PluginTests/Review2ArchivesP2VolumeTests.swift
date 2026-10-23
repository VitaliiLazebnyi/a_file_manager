import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Review round 2, second pass: new members next to an archive on another volume (A046), and the lock of
/// the directory (A104).
@MainActor
@Suite
internal struct Review2ArchivesP2VolumeTests: ArchiveFixSuite {
    /// The archive file systems in a sandbox of their own.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// New members of an archive on another volume wait next to it, in a private folder that goes with them (A046).
    @Test
    internal func newMembersOfAnArchiveOnAnotherVolumeWaitNextToIt() throws {
        let archive = try makeZip()
        let scratch = bench.environment.scratch.url
        // "Another volume": everything outside the temporary folder's own.
        let opened = try bench.store.archive(at: archive, cancellation: nil)
        let asked = Collected<String>()
        // (Weak: the archive holds the environment, which holds this.)
        bench.environment.volume = { [weak opened] path in
            asked.add(path)
            // Asked without the directory's lock: looking into the archive from here would
            // otherwise never return.
            _ = opened?.isBusy
            return path == scratch.deletingLastPathComponent().path ? 1 : 2
        }
        // (Not kept beyond its closing: a writer holds on to its temporary file.)
        var writer: (any FileWriter)? = try bench.zip.write(
            bench.inside(archive, "tree/large.bin", scheme: ArchiveURL.writableScheme)
        )
        try writer?.write(Data(repeating: 7, count: 100_000))
        let folders = try FileManager.default.contentsOfDirectory(atPath: box.root.path)
            .filter { name in name.hasPrefix(".afm-spool-") }
        #expect(folders.count == 1 && asked.all.count == 2)
        let spool = box.url(folders.first ?? "missing")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: spool.path).filter { $0.hasSuffix(".zipdata") }.count
                == 1
        )
        #expect(permissionBits(spool) == 0o700 && ScratchFolder.isOwnExternalName(spool.lastPathComponent))
        // Nothing of it in the temporary folder.
        let inScratch = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
        #expect(!inScratch.contains { $0.hasSuffix(".zipdata") })
        try writer?.close(attributes: FileAttributes())
        writer = nil
        // The volume is asked once per archive, not once per member.
        try write("small", to: bench.inside(archive, "tree/small.txt", scheme: ArchiveURL.writableScheme))
        #expect(asked.all.count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: spool.path).count == 2)
        #expect(
            bench.store.flushAll(cancellation: nil).isEmpty && listed(archive).contains("tree/large.bin")
                && listed(archive).contains("tree/small.txt")
        )
        #expect(runTool("/usr/bin/unzip", ["-tq", archive.path], in: nil).status == 0)
        // Written, the members leave their folder, and the folder goes with the archive.
        #expect(try FileManager.default.contentsOfDirectory(atPath: spool.path).isEmpty)
        // A member that is given up leaves nothing behind either.
        try {
            let abandoned = try bench.zip.write(
                bench.inside(archive, "tree/abandoned.bin", scheme: ArchiveURL.writableScheme)
            )
            try abandoned.write(Data(repeating: 1, count: 10))
            abandoned.interrupt()
            #expect(throws: (any Error).self) { try abandoned.close(attributes: FileAttributes()) }
        }()
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: spool.path).isEmpty && !bench.store.hasPendingChanges
        )
    }

    /// A change asks the disk before it takes the lock of the directory, and every change takes the flag (A104).
    @Test
    internal func aChangeAsksTheDiskBeforeItTakesTheLockOfTheDirectory() throws {
        // An archive that cannot be written says so, as before…
        let archive = try makeZip()
        #expect(chmod(archive.path, 0o444) == 0)
        #expect(throws: (any Error).self) {
            try bench.zip.createDirectory(at: bench.inside(archive, "tree/new", scheme: ArchiveURL.writableScheme))
        }
        #expect(throws: (any Error).self) {
            try bench.zip.write(bench.inside(archive, "tree/new.txt", scheme: ArchiveURL.writableScheme))
        }
        #expect(throws: (any Error).self) {
            try bench.zip.remove(bench.inside(archive, "tree/empty.txt", scheme: ArchiveURL.writableScheme))
        }
        #expect(!bench.store.hasPendingChanges)
        #expect(chmod(archive.path, 0o644) == 0)
        // …and one that is no ZIP says that it cannot be changed, not that the file is locked.
        try bench.pack([box.url("tree")], to: box.url("plain.tar"), innerFolder: "") { $0.format = .tar }
        let tar = try bench.store.archive(at: box.url("plain.tar"), cancellation: nil)
        #expect(chmod(box.url("plain.tar").path, 0o444) == 0)
        do {
            try tar.makeDirectory("tree/new")
            Issue.record("a TAR was changed")
        } catch ArchiveError.readOnly {
            // What a TAR says.
        } catch {
            Issue.record("\(error)")
        }
        try expectEveryChangeTakesTheFlag(archive)
        expectTheRealPlaceAndTheTop(archive)
    }

    /// Each kind of change, with the flag the kernel now passes; a set flag ends it.
    private func expectEveryChangeTakesTheFlag(_ archive: URL) throws {
        let flag = CancellationFlag()
        try bench.zip.createDirectory(
            at: bench.inside(archive, "tree/made", scheme: ArchiveURL.writableScheme),
            cancellation: flag
        )
        try write("x", to: bench.inside(archive, "tree/made/x.txt", scheme: ArchiveURL.writableScheme))
        try bench.zip.move(
            bench.inside(archive, "tree/made/x.txt", scheme: ArchiveURL.writableScheme),
            to: bench.inside(archive, "tree/made/y.txt", scheme: ArchiveURL.writableScheme),
            replacing: false,
            cancellation: flag
        )
        try bench.zip.setAttributes(
            FileAttributes(permissions: 0o600),
            of: bench.inside(archive, "tree/made/y.txt", scheme: ArchiveURL.writableScheme),
            cancellation: flag
        )
        try bench.zip.remove(
            bench.inside(archive, "tree/empty.txt", scheme: ArchiveURL.writableScheme),
            cancellation: flag
        )
        #expect(bench.store.flushAll(cancellation: nil).isEmpty)
        #expect(listed(archive).contains("tree/made/y.txt") && !listed(archive).contains("tree/empty.txt"))
        flag.cancel()
        #expect(throws: (any Error).self) {
            try bench.zip.remove(
                bench.inside(archive, "tree/made/y.txt", scheme: ArchiveURL.writableScheme),
                cancellation: flag
            )
        }
        #expect(throws: (any Error).self) {
            try bench.zip.createDirectory(
                at: bench.inside(archive, "tree/never", scheme: ArchiveURL.writableScheme),
                cancellation: flag
            )
        }
        #expect(!bench.store.hasPendingChanges)
    }

    /// A place that only passes through the archive scheme is the real place, and the top of a location is
    /// where going up one by one ends.
    private func expectTheRealPlaceAndTheTop(_ archive: URL) {
        let outside = bench.inside(archive, "", scheme: ArchiveURL.writableScheme).deletingLastPathComponent()
        #expect(bench.zip.realLocation(of: outside)?.isSameLocation(as: box.root) == true)
        #expect(bench.zip.realLocation(of: bench.inside(archive, "tree", scheme: ArchiveURL.writableScheme)) == nil)
        // The top of a location is told at once, and is where going up one by one ends.
        #expect(runTool("/usr/bin/zip", ["-q0", "outer.zip", "tree.zip"], in: box.root).status == 0)
        let nested = ArchiveURL.make(
            scheme: ArchiveURL.writableScheme,
            archive: bench.inside(box.url("outer.zip"), "tree.zip", scheme: ArchiveURL.writableScheme),
            innerPath: "tree/sub/deep"
        )
        for url in [
            bench.inside(archive, "", scheme: ArchiveURL.writableScheme),
            bench.inside(archive, "tree/sub/deep/x/y/z", scheme: ArchiveURL.writableScheme), outside, nested, box.root
        ] {
            var climbed = url
            while let parent = bench.zip.parent(of: climbed) { climbed = parent }
            #expect(bench.zip.root(of: url) == climbed, "\(url)")
        }
        #expect(
            bench.zip.root(of: bench.inside(archive, "tree/sub", scheme: ArchiveURL.writableScheme))
                .isSameLocation(as: box.root)
        )
    }
}
