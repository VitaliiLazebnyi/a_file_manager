import AFMKernel
import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// What comes out of an archive and what goes into one: the quarantine, set-user-ID bits, members that unpack to more
/// than they say, names that clash and wrong passwords.
@Suite
internal struct ArchiveOutputFixes: ArchiveFixSuite {
    /// The archive file systems and the sandbox of the test.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// Unpacked files carry the quarantine of their archive, also out of an archive inside one; a changed archive keeps
    /// its own.
    @Test
    internal func unpackedFilesCarryTheArchivesQuarantine() throws {
        let archive = try makeZip()
        let mark = "0083;65f0a1b2;Safari;F643CD5F-6071-46AB-83AB-390BA944DEC5"
        #expect(mark.withCString { setxattr(archive.path, "com.apple.quarantine", $0, strlen($0), 0, 0) } == 0)
        let result = try bench.unpack(archive, to: box.url("out"))
        #expect(result.problems.isEmpty)
        for path in ["out/tree/readme.txt", "out/tree/sub/random.bin", "out/tree/hollow", "out/tree/empty.txt"] {
            #expect(quarantineMark(of: box.url(path)) == mark, "\(path)")
        }
        // Changing the archive keeps its mark, and so does an archive inside it.
        try write("new", to: bench.inside(archive, "tree/new.txt"))
        try bench.zip.remove(bench.inside(archive, "tree/empty.txt"))
        try bench.store.flush(archive, cancellation: nil)
        #expect(quarantineMark(of: archive) == mark)
        try bench.pack([box.url("tree")], to: box.url("inner.tar")) { $0.format = .tar }
        try bench.pack([box.url("inner.tar")], to: box.url("outer.zip"))
        #expect(
            mark.withCString { setxattr(box.url("outer.zip").path, "com.apple.quarantine", $0, strlen($0), 0, 0) } == 0
        )
        let inner = bench.inside(box.url("outer.zip"), "inner.tar")
        let nested = try bench.unpack(inner, to: box.url("nested"))
        #expect(nested.problems.isEmpty && quarantineMark(of: box.url("nested/tree/readme.txt")) == mark)
        // An archive without the mark gives none.
        _ = try bench.unpack(try makeZip("clean.zip"), to: box.url("clean"))
        #expect(quarantineMark(of: box.url("clean/tree/readme.txt")) == nil)
    }

    /// Programs come out of an archive without the set-user-ID bit, which a change of the ZIP keeps in the archive.
    @Test
    internal func unpackedProgramsDoNotRunAsTheirOwner() throws {
        try box.file("tree/tool", "#!/bin/sh\n")
        try box.file("tree/plain", "plain")
        #expect(chmod(box.url("tree/tool").path, 0o4755) == 0 && chmod(box.url("tree/plain").path, 0o640) == 0)
        #expect(runTool("/usr/bin/zip", ["-qr", "tools.zip", "tree"], in: box.root).status == 0)
        #expect(runTool("/usr/bin/tar", ["-cf", "tools.tar", "tree"], in: box.root).status == 0)
        for (name, scheme) in [("tools.zip", ArchiveURL.writableScheme), ("tools.tar", ArchiveURL.readOnlyScheme)] {
            #expect(
                try bench.item(bench.inside(box.url(name), "tree/tool", scheme: scheme)).permissions == 0o755,
                "\(name)"
            )
            #expect(
                try bench.item(bench.inside(box.url(name), "tree/plain", scheme: scheme)).permissions == 0o640,
                "\(name)"
            )
            _ = try bench.unpack(box.url(name), to: box.url("out-" + name))
            let mode =
                try
                FileManager.default.attributesOfItem(atPath: box.url("out-\(name)/tree/tool").path)[
                    .posixPermissions
                ] as? Int
            #expect(mode == 0o755, "\(name)")
        }
        // Changing the ZIP does not take the bits from the archive itself.
        try bench.zip.remove(bench.inside(box.url("tools.zip"), "tree/plain"))
        try bench.store.flush(box.url("tools.zip"), cancellation: nil)
        #expect(runTool("/usr/bin/unzip", ["-Z", box.url("tools.zip").path]).output.contains("-rwsr-xr-x"))
    }

    /// A member that unpacks to more than its header says is stopped at that size and not unpacked.
    @Test
    internal func aMemberThatUnpacksToMoreThanItSaysIsStopped() throws {
        let contents = Data(repeating: 0, count: 50 << 20)
        let packed = try Deflater.piece(contents, level: 6, final: true, calls: .zlib)
        let archive = box.url("bomb.zip")
        let output = try OutputFile(creating: archive, mode: 0o600)
        let writer = ZipWriter(output, limits: .standard)
        var record = ZipRecord.new(
            name: "small.txt",
            isDirectory: false,
            modified: Date(),
            permissions: 0o644,
            isSymbolicLink: false
        )
        record.method = ZipRecord.methodDeflate
        record.crc = CRC32.of(contents)
        (record.compressedSize, record.uncompressedSize) = (UInt64(packed.count), 1_000)
        let member = try writer.begin(record, localExtra: nil, expectedSize: nil)
        try writer.append(packed)
        try writer.end(member, record, headerChanged: true)
        try writer.finish(comment: Data())
        try output.close(durably: false)
        let opened = try bench.store.archive(at: archive, cancellation: nil)
        let stream = try opened.open(try #require(opened.entry("small.txt")), slot: nil)
        var read = 0
        #expect(throws: ArchiveError.self) {
            while let block = try stream.read(upToCount: 1 << 16) { read += block.count }
        }
        #expect(read <= 1_000)
        let result = try bench.unpack(archive, to: box.url("out"))
        #expect(result.unpacked == 0 && result.problems.count == 1 && namesOnDisk(box.url("out")).isEmpty)
    }
    /// Files that would share a name in an archive without paths are not packed over each other, and nothing is moved.
    @Test
    internal func filesThatWouldShareANameAreNotPackedOverEachOther() throws {
        try box.file("src/a/same.txt", "first")
        try box.file("src/b/same.txt", "second")
        for format in [ArchiveFormat.zip, .tar] {
            let archive = box.url("flat." + format.defaultExtension)
            #expect(throws: ArchiveError.self) {
                try bench.pack([box.url("src")], to: archive) { options in
                    (options.format, options.storesPaths, options.movesSources) = (format, false, true)
                }
            }
            // Nothing was written, and nothing was deleted.
            #expect(
                !FileManager.default.fileExists(atPath: archive.path) && box.read("src/a/same.txt") == "first"
                    && box.read("src/b/same.txt") == "second"
            )
        }
        try FileManager.default.removeItem(at: box.url("src/b"))
        try bench.pack([box.url("src")], to: box.url("flat.zip")) { $0.storesPaths = false }
        #expect(listed(box.url("flat.zip")) == ["same.txt"])
    }

    /// A wrong password that passes the check byte of the old encryption is asked for again in the same read and not
    /// kept.
    @Test
    internal func aWrongPasswordThatPassesTheCheckByteIsNotKept() throws {
        let tree = try bench.makeTree()
        let archive = box.url("secret.zip")
        try bench.pack([tree.appendingPathComponent("readme.txt")], to: archive) { options in
            options.password = "right"
            options.encryption = .legacy
        }
        bench.store.close()
        // One wrong password in 256 gets past the first twelve bytes. Taken is one whose data does not start like
        // compressed data, which is nearly all of them (the encryption header is random: the few that start like it
        // differ from run to run).
        let record = try #require(
            ZipDirectory.read(RandomAccessFile(archive, shownAs: nil), maxEntries: .max, check: nil).records.first
        )
        guard case .archive(let offset, let file) = record.source else {
            return
        }
        let start = try ZipDirectory.localHeader(of: record, at: offset, in: file).dataOffset
        // Whether `password` passes the check byte and what it decrypts to is not compressed data.
        func isNoCompressedData(_ password: String) -> Bool {
            guard
                let decrypted = try? ZipDecryptStream(
                    FileRangeStream(file, offset: start, length: record.compressedSize),
                    password: password,
                    check: UInt8(record.dosTime >> 8),
                    name: ""
                )
            else { return false }
            let probe = InflateStream(decrypted, wrapping: .raw, control: nil)
            defer { probe.close() }
            do {
                _ = try probe.read(upToCount: 1 << 12)
                return false
            } catch ArchiveError.damaged {
                return true
            } catch {
                return false
            }
        }
        let wrong = try #require((0..<100_000).lazy.map { "wrong\($0)" }.first(where: isNoCompressedData))
        bench.passwords.set([wrong, "right"])
        let member = bench.inside(archive, "readme.txt")
        // What it decrypts to is not compressed data: it is a wrong password like any other, asked
        // for again in the same read (it used to be reported as a damaged archive, and asked
        // for again only at the next read), and it is not kept.
        #expect(try bench.read(member) == Data(contentsOf: tree.appendingPathComponent("readme.txt")))
        #expect(bench.passwords.asked == 2)
        #expect(try bench.read(member).count == 17_600 && bench.passwords.asked == 2)
    }
}
