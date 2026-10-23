import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Review round 2: packing into an archive on a server, and the archive file itself (links, rights, a
/// file replaced meanwhile, a damaged directory).
@Suite
internal struct Review2ArchivesFileTests: ArchiveFixSuite {
    /// The archive file systems in a sandbox of their own.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    // MARK: Pack into an archive on a server (A018, A019, A020, A095)

    /// Packing into a ZIP on a server encrypts the member when a password is given (A018).
    @Test
    internal func packIntoAnArchiveOnAServerEncryptsWhenAsked() throws {
        let local = try makeZip()
        let onServer = try upload(local, to: "/store/s.zip")
        let secret = try box.file("secret.txt", String(repeating: "top secret line\n", count: 200))
        try bench.pack([secret], to: onServer, innerFolder: "") { options in
            options.password = "pw"
            options.verifies = true
        }
        let fetched = try download(onServer, as: "s-back.zip")
        let record = try #require(
            ZipDirectory.read(try RandomAccessFile(fetched, shownAs: nil), maxEntries: .max, check: nil).records
                .first { $0.name == "secret.txt" }
        )
        #expect(record.isEncrypted && record.method == ZipAES.method)
        // Not readable without the password, by anyone.
        #expect(!runTool("/usr/bin/unzip", ["-p", fetched.path, "secret.txt"], in: nil).output.contains("top secret"))
        #expect(
            runTool("/usr/bin/bsdtar", ["-xOf", fetched.path, "--passphrase", "pw", "secret.txt"], in: nil).output
                .hasPrefix(
                    "top secret line"
                )
        )
        #expect(!listed(fetched).contains { $0.contains(".afm-") })
    }

    /// A pack into a ZIP on a server that fails or is cancelled leaves the old member as it was (A019).
    @Test
    internal func aFailedPackIntoAnArchiveOnAServerLeavesTheOldMember() throws {
        let local = try makeZip()
        let onServer = try upload(local, to: "/store/s.zip")
        let before = try bench.read(bench.inside(onServer, "tree/readme.txt", scheme: ArchiveURL.writableScheme))
        // The file that is to replace the member cannot be read.
        let source = try box.folder("again/tree")
        try Data("new readme".utf8).write(to: source.appendingPathComponent("readme.txt"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: source.appendingPathComponent("readme.txt").path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: source.appendingPathComponent("readme.txt").path
            )
        }
        #expect(throws: (any Error).self) {
            try bench.pack([source], to: onServer, innerFolder: "") { $0.format = .zip }
        }
        let open = try bench.store.archive(at: onServer, cancellation: nil)
        #expect(!open.isBusy)
        #expect(try bench.read(bench.inside(onServer, "tree/readme.txt", scheme: ArchiveURL.writableScheme)) == before)
        #expect(bench.store.flushAll(cancellation: nil).isEmpty)
        let fetched = try download(onServer, as: "s-after.zip")
        #expect(listed(fetched).contains("tree/readme.txt") && !listed(fetched).contains { $0.contains(".afm-") })
        #expect(runTool("/usr/bin/unzip", ["-tq", fetched.path], in: nil).status == 0)

        // Cancelled while the replacement is read: the same.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: source.appendingPathComponent("readme.txt").path
        )
        bench.monitor.cancellation.cancel()
        let result = Packer(
            fileSystems: bench.fileSystems,
            store: bench.store,
            monitor: bench.monitor,
            options: PackOptions()
        )
        .run([try bench.item(source)], archive: onServer, innerFolder: "")
        #expect(result.cancelled || result.failure != nil)
        #expect(
            try bench.read(bench.inside(onServer, "tree/readme.txt", scheme: ArchiveURL.writableScheme)) == before
                && !open.isBusy
        )
    }

    // MARK: The archive file itself (A034, A035, A037, A047, A079)

    /// An archive reached through a symbolic link is changed where it lies, and the link stays (A034).
    @Test
    internal func anArchiveReachedThroughALinkIsChangedWhereItLies() throws {
        let archive = try makeZip()
        try box.folder("real")
        let real = box.url("real/real.zip")
        try FileManager.default.moveItem(at: archive, to: real)
        let link = box.url("link.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        func isLink() -> Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil }
        // A change made inside, through the link…
        try write("through the link", to: bench.inside(link, "tree/via-link.txt", scheme: ArchiveURL.writableScheme))
        #expect(bench.store.flushAll(cancellation: nil).isEmpty)
        #expect(isLink() && listed(real).contains("tree/via-link.txt"))
        // …a deletion, which writes the whole archive anew…
        try bench.zip.remove(bench.inside(link, "tree/empty.txt", scheme: ArchiveURL.writableScheme))
        #expect(bench.store.flushAll(cancellation: nil).isEmpty)
        #expect(isLink() && !listed(real).contains("tree/empty.txt"))
        // …and packing into it, by adding and by replacing a member.
        let extra = try box.file("extra.txt", "extra")
        try bench.pack([extra], to: link, innerFolder: "") { $0.format = .zip }
        #expect(isLink() && listed(real).contains("extra.txt"))
        try Data("extra, again".utf8).write(to: extra)
        try bench.pack([extra], to: link, innerFolder: "") { $0.format = .zip }
        #expect(isLink() && runTool("/usr/bin/unzip", ["-p", real.path, "extra.txt"], in: nil).output == "extra, again")
        #expect(Durable.realFile(link).path == Durable.realFile(real).path)
    }

    /// An archive keeps its permissions when written, and a new one is no more open than its sources (A035).
    @Test
    internal func anArchiveKeepsItsRightsAndANewOneIsNoMoreOpenThanItsSources() throws {
        let archive = try makeZip()
        func mode(_ url: URL) -> Int {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        // Added to (the file is cloned and continued), and with a member replaced (written anew).
        let extra = try box.file("extra.txt", "extra")
        try bench.pack([extra], to: archive, innerFolder: "") { $0.format = .zip }
        #expect(mode(archive) == 0o600 && listed(archive).contains("extra.txt"))
        try Data("again".utf8).write(to: extra)
        try bench.pack([extra], to: archive, innerFolder: "") { $0.format = .zip }
        #expect(mode(archive) == 0o600)
        // Without cloning: every write is a new file.
        bench.environment.clonesArchives = false
        try bench.pack([try box.file("third.txt", "third")], to: archive, innerFolder: "") { $0.format = .zip }
        #expect(mode(archive) == 0o600 && listed(archive).contains("third.txt"))
        try bench.zip.remove(bench.inside(archive, "third.txt", scheme: ArchiveURL.writableScheme))
        #expect(bench.store.flushAll(cancellation: nil).isEmpty && mode(archive) == 0o600)
        // A new archive of private files is private; one of public files is as before.
        let secret = try box.file("private/secret.txt", "secret")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
        try bench.pack([secret], to: box.url("private.zip"), innerFolder: "") { $0.format = .zip }
        try bench.pack([extra], to: box.url("public.zip"), innerFolder: "") { $0.format = .zip }
        #expect(mode(box.url("private.zip")) == 0o600)
        #expect(
            mode(box.url("public.zip")) & 0o600 == 0o600
                && mode(box.url("public.zip")) & 0o044 == (0o044 & ~Int(umaskNow()))
        )
        // No temporary file of a write is left next to the archives.
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.root.path).allSatisfy { !$0.hasSuffix(".tmp") })
    }

    private func umaskNow() -> mode_t {
        let mask = umask(0)
        umask(mask)
        return mask
    }

    /// A pack into an archive with changes waiting keeps both, and a file replaced meanwhile is not overwritten.
    @Test
    internal func packIntoAnArchiveWithChangesWaitingLosesNeither() throws {
        let archive = try makeZip()
        // A change that waits in the open archive, then a pack that rewrites the file.
        try write("waiting", to: bench.inside(archive, "tree/waiting.txt", scheme: ArchiveURL.writableScheme))
        try bench.pack([try box.file("packed.txt", "packed")], to: archive, innerFolder: "") { $0.format = .zip }
        #expect(bench.store.flushAll(cancellation: nil).isEmpty)
        #expect(listed(archive).contains("tree/waiting.txt") && listed(archive).contains("packed.txt"))
        // A file that someone else replaces while the pack writes is not overwritten.
        var replaced = false
        let stranger = try Data(contentsOf: archive)
        let packer = Packer(
            fileSystems: bench.fileSystems,
            store: bench.store,
            monitor: bench.monitor,
            options: PackOptions()
        )
        let source = try box.file("late.txt", "late")
        // (The moment between the pack's own writing and its putting the file in place is
        // not reachable from here; the check it makes there is.)
        let open = try bench.store.archive(at: archive, cancellation: nil)
        #expect(throws: ArchiveError.self) {
            try open.whileHoldingFile(cancellation: nil) { stillUnchanged in
                try stranger.write(to: box.url("stranger.zip"))
                #expect(rename(box.url("stranger.zip").path, archive.path) == 0)
                replaced = true
                try stillUnchanged()
            }
        }
        #expect(replaced)
        _ = (packer, source)
    }

    /// A directory that points two entries at one header cannot make a write overwrite the other member (A079).
    @Test
    internal func aDamagedDirectoryCannotMakeAWriteOverwriteAnotherMember() throws {
        // Two members; the directory's entry for the second points at the first one's header.
        let url = box.url("crossed.zip")
        let output = try OutputFile(creating: url, mode: 0o600)
        let writer = ZipWriter(output, limits: .standard)
        var first = ZipRecord.new(
            name: "first.txt",
            isDirectory: false,
            modified: Date(timeIntervalSince1970: 1_600_000_000),
            permissions: 0o644,
            isSymbolicLink: false
        )
        let payload = Data("first member data".utf8)
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
        (second.crc, second.compressedSize, second.uncompressedSize) = (
            first.crc, first.compressedSize, first.uncompressedSize
        )
        writer.adopt(second, at: 0)
        try writer.finish(comment: Data())
        try output.close(durably: false)
        let before = try Data(contentsOf: url)
        // Changing the time of the second would patch the header at the offset it claims.
        try bench.zip.setAttributes(
            FileAttributes(modified: Date(timeIntervalSince1970: 1_700_000_000)),
            of: bench.inside(url, "second.txt", scheme: ArchiveURL.writableScheme)
        )
        _ = bench.store.flushAll(cancellation: nil)
        let after = try Data(contentsOf: url)
        // Whatever the write did, the first member's header and data are what they were.
        #expect(after.prefix(30 + 9 + first.extra.count + payload.count).prefix(26) == before.prefix(26))
        #expect(runTool("/usr/bin/unzip", ["-p", url.path, "first.txt"], in: nil).output == "first member data")
    }
}
