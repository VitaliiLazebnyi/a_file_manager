import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// One 512-byte TAR header built by hand.
private func tarHeader(name: String, type: UInt8 = 48, size: UInt64 = 0, link: String = "") -> Data {
    var block = [UInt8](repeating: 0, count: 512)
    func put(_ bytes: [UInt8], at offset: Int) {
        for (index, byte) in bytes.enumerated() { block[offset + index] = byte }
    }
    func octal(_ value: UInt64, _ length: Int) -> [UInt8] {
        let digits = String(value, radix: 8)
        return Array((String(repeating: "0", count: length - 1 - digits.count) + digits).utf8)
    }
    put(Array(name.utf8.prefix(100)), at: 0)
    put(octal(0o644, 8), at: 100)
    put(octal(size, 12), at: 124)
    put(octal(1_600_000_000, 12), at: 136)
    block[156] = type
    put(Array(link.utf8.prefix(100)), at: 157)
    put(Array("ustar\u{0}00".utf8), at: 257)
    for index in 148..<156 { block[index] = 32 }
    let sum = block.reduce(0) { $0 + Int($1) }
    put(Array(String(format: "%06o", sum).utf8) + [0, 32], at: 148)
    return Data(block)
}

private func tarBody(_ text: String) -> Data {
    var data = Data(text.utf8)
    data.append(Data(count: (512 - data.count % 512) % 512))
    return data
}

/// Review round 2: what an archive (or a file that only claims to be one) can do to the
/// program and to the disk.
@Suite struct Review2ArchivesSafety {
    let bench: ArchiveBench
    var box: Sandbox { bench.box }

    init() throws {
        bench = try ArchiveBench()
    }

    /// A ZIP written record by record, for names no packer would write.
    func writeZip(_ name: String, limits: ZipLimits = .standard, names: [String]) throws -> URL {
        let url = box.url(name)
        let output = try OutputFile(creating: url)
        let writer = ZipWriter(output, limits: limits)
        for name in names {
            var record = ZipRecord.new(name: name, isDirectory: false, modified: Date(), permissions: 0o644)
            record.setName(name)
            try writer.end(try writer.begin(record), record, headerChanged: false)
        }
        try writer.finish()
        try output.close()
        return url
    }

    // MARK: Paths (A005, A030, A077, A013, A029)

    @Test func pathsAreCutAtTheByteNotAtTheCharacter() {
        // A slash followed by a combining mark is one Character and still a separator.
        #expect(ArchiveTree.normalized("../\u{301}evil.txt") == nil)
        #expect(ArchiveTree.normalized("a/\u{301}b") == nil)
        #expect(ArchiveTree.normalized("a/\u{200D}b/c") == nil)
        // A character that binds what follows it hides the separator from the other side.
        #expect(ArchiveTree.normalized("a\u{0600}/b") == nil)
        #expect(ArchiveTree.normalized("a/../b") == nil && ArchiveTree.normalized("..") == nil)
        #expect(ArchiveTree.normalized("a/b\u{0}c") == nil)
        #expect(ArchiveTree.normalized("/abs//./x") == "abs/x")
        #expect(ArchiveTree.normalized("dir/é/日本.txt") == "dir/é/日本.txt")
        #expect(ArchiveTree.normalized("...") == "..." && ArchiveTree.normalized("a/..b") == "a/..b")
        #expect(ArchiveTree.name(of: "a/b/c.txt") == "c.txt" && ArchiveTree.parent(of: "a/b/c.txt") == "a/b")
        #expect(ArchiveTree.relative("a/b/c", to: "a") == "b/c" && ArchiveTree.relative("ab/c", to: "a") == nil)
        // Too deep, or too long: every name would be a folder kept under its whole path.
        #expect(
            ArchiveTree.normalized(Array(repeating: "a", count: ArchiveTree.maxDepth + 1).joined(separator: "/")) == nil
        )
        #expect(
            ArchiveTree.normalized(Array(repeating: "a", count: ArchiveTree.maxDepth).joined(separator: "/")) != nil
        )
        #expect(ArchiveTree.normalized(String(repeating: "x", count: ArchiveTree.maxPathBytes + 1)) == nil)
    }

    @Test func aSlashWithACombiningMarkCannotLeaveTheTargetFolder() throws {
        let names = ["../\u{301}evil.txt", "ok/\u{301}hidden.txt", "fine.txt"]
        let zip = try writeZip("slash.zip", names: names)
        var tar = Data()
        for name in names {
            tar.append(tarHeader(name: name, size: 4))
            tar.append(tarBody("data"))
        }
        tar.append(Data(count: 1_024))
        try tar.write(to: box.url("slash.tar"))
        var archives = [zip, box.url("slash.tar")]
        // The reproducers the fuzzer left, when they are there.
        let repro = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fuzz/repro/arch")
        for name in ["containment-slash-combining-mark.zip", "containment-slash-combining-mark.tar"] {
            let fixture = repro.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: fixture.path) else { continue }
            let copy = box.url("fuzz-" + name)
            try FileManager.default.copyItem(at: fixture, to: copy)
            archives.append(copy)
        }
        for (index, archive) in archives.enumerated() {
            let target = try box.folder("out\(index)/deep/target")
            _ = try bench.unpack(archive, to: target)
            let outside = try FileManager.default.subpathsOfDirectory(atPath: box.url("out\(index)").path)
                .filter {
                    !$0.hasPrefix("deep/target") && $0 != "deep"
                }
            #expect(outside.isEmpty, "\(archive.lastPathComponent) wrote \(outside)")
        }
        #expect(box.exists("out0/deep/target/fine.txt") && box.exists("out1/deep/target/fine.txt"))
        #expect(
            Unpacker.lies(box.url("a/b"), below: box.url("a"))
                && !Unpacker.lies(box.url("a/../b"), below: box.url("a"))
        )
        #expect(
            !Unpacker.lies(box.url("ab"), below: box.url("a")) && !Unpacker.lies(box.url("a"), below: box.url("a"))
        )
    }

    @Test func deepPathsAreRefusedBeforeTheyFillTheMemory() throws {
        // One member 300 folders deep is not shown (and costs nothing).
        let deep = Array(repeating: "d", count: 300).joined(separator: "/") + "/f.txt"
        let one = try writeZip("deep.zip", names: [deep, "plain.txt"])
        #expect(try bench.names(bench.inside(one)) == ["plain.txt"])
        // Many members, each with its own chain of long folder names, are refused as a whole.
        var names: [String] = []
        for member in 0..<160 {
            let part = String(format: "%03d", member) + String(repeating: "n", count: 12)
            names.append(Array(repeating: part, count: 250).joined(separator: "/"))
        }
        let many = try writeZip("chains.zip", names: names)
        #expect { try bench.store.archive(at: many) } throws: { error in
            if case ArchiveError.unsupported = error {
                return true
            }
            return false
        }
        // An archive with more entries than the memory is to hold is refused, not read.
        bench.environment.maxEntries = 3
        let crowded = try writeZip("crowded.zip", names: (0..<6).map { "f\($0).txt" })
        #expect(throws: ArchiveError.self) { try bench.store.archive(at: crowded) }
    }

    @Test func theOrderOfTheTreeIsKeptWhileEntriesComeAndGo() {
        var tree = ArchiveTree()
        var generator = SystemRandomNumberGenerator()
        for index in 0..<40 { tree.insert(ArchiveEntry(path: "d\(index % 7)/f\(index)", isDirectory: false)) }
        _ = tree.ordered
        for round in 0..<400 {
            let path = "d\(Int.random(in: 0..<7, using: &generator))/f\(Int.random(in: 0..<60, using: &generator))"
            switch round % 3 {
            case 0:
                tree.insert(ArchiveEntry(path: path, isDirectory: false))

            case 1:
                tree.remove(path)

            default:
                // A rename: out, and in again elsewhere with the position it had.
                if var entry = tree.remove(path) {
                    entry.path = "moved/" + ArchiveTree.name(of: path) + "-\(round)"
                    tree.insert(entry, keepingOrder: true)
                }
            }
            let kept = tree.ordered.map(\.path)
            let sorted = tree.unordered.sorted { $0.order < $1.order }.map(\.path)
            #expect(kept == sorted)
            if kept != sorted { break }
        }
    }

    // MARK: Unpacking (A096, A097)

    @Test func nothingIsUnpackedThroughALinkThatAlreadyStandsInTheTarget() throws {
        let outside = try box.folder("outside")
        let target = try box.folder("target")
        try FileManager.default.createSymbolicLink(
            at: target.appendingPathComponent("dir"),
            withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            atPath: target.appendingPathComponent("loose.txt").path,
            withDestinationPath: outside.path + "/nowhere.txt"
        )
        let archive = try writeZip("through.zip", names: ["dir/planted.txt", "loose.txt", "safe/ok.txt"])
        let result = try bench.unpack(archive, to: target)
        #expect(result.problems.count == 1 && box.exists("target/safe/ok.txt"), "\(result.problems)")
        // Nothing went through either link: the one that stood where a file was to go was
        // replaced by the file (the bench answers "overwrite"), not followed.
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: target.appendingPathComponent("loose.txt").path))
                == nil
        )
        // The links are what they were.
        #expect(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: target.appendingPathComponent("dir").path))
                == outside.path
        )
    }

    // MARK: Files that are handed to bsdtar (A038, A087)

    @Test func aTextFileNamedLikeAnArchiveIsNotGivenToBsdtar() throws {
        let secret = try box.file("secret.txt", "TOP-SECRET-CONTENT")
        for (name, head) in [
            ("holiday.7z", "#mtree\n"), ("list.rar", ""),
            ("lha.lzh", "ab-lh5- type=file contents=\(secret.path)\n#mtree\n")
        ] {
            let url = box.url(name)
            try Data((head + "photo.jpg type=file contents=\(secret.path)\n").utf8).write(to: url)
            #expect { try bench.store.archive(at: url) } throws: { error in
                if case ArchiveError.notAnArchive = error {
                    return true
                }
                return false
            }
        }
        // By the first bytes, with a zero byte before the first line ends: only then.
        func kind(_ bytes: [UInt8], padding: Int = 64) throws -> ForeignArchive.Kind? {
            let url = box.url("probe-\(UUID().uuidString)")
            try Data(bytes + [UInt8](repeating: 0x41, count: padding)).write(to: url)
            return ForeignArchive.kind(of: try RandomAccessFile(url))
        }
        #expect(try kind([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 4]) == .libarchive)
        #expect(try kind([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x0A, 0]) == nil)
        #expect(try kind(Array("Rar!".utf8) + [0x1A, 0x07, 0]) == .libarchive)
        #expect(try kind(Array("#mtree\n".utf8)) == nil && kind(Array("!<arch>\n".utf8)) == nil)
        #expect(try kind([0x1F, 0x9D, 0x90]) == .compressedTar)
        #expect(try kind(Array("070707 type=file\n".utf8) + [0]) == nil)
    }

    @Test func realForeignArchivesStillOpen() throws {
        try bench.makeTree()
        #expect(runTool("/usr/bin/bsdtar", ["--format", "7zip", "-cf", "tree.7z", "tree"], in: box.root).status == 0)
        #expect(
            runTool("/usr/bin/bsdtar", ["--format", "cpio", "-cf", "tree.cpio", "tree"], in: box.root).status == 0
        )
        for name in ["tree.7z", "tree.cpio"] {
            let inner = bench.inside(box.url(name), "tree", scheme: ArchiveURL.readOnlyScheme)
            #expect(try bench.names(inner).contains("readme.txt"), "\(name)")
            #expect(
                try bench.read(inner.appending(name: "readme.txt")) == Data(contentsOf: box.url("tree/readme.txt")),
                "\(name)"
            )
        }
    }

    // MARK: Typed paths (A001, A002, A056)

    @Test func aTypedPathIsOnlyAskedAboutOnLocalDisks() throws {
        try box.file("real/a.zip", "x")
        try box.folder("folder.zip")
        try FileManager.default.createSymbolicLink(at: box.url("link"), withDestinationURL: box.url("real"))
        #expect(Volume.isOnLocalVolume(box.root.path) && !Volume.isOnLocalVolume("relative/path"))
        #expect(Volume.kind(ofLocalPath: box.url("real/a.zip").path) == .regularFile)
        #expect(Volume.kind(ofLocalPath: box.url("link/a.zip").path) == .regularFile)
        #expect(Volume.kind(ofLocalPath: box.url("folder.zip").path) == .directory)
        #expect(Volume.kind(ofLocalPath: box.url("missing.zip").path) == .missing)
        #expect(Volume.kind(ofLocalPath: box.url("real/a.zip/x").path) == .missing)
        // A folder named like an archive, reached by an archive location all the same (as a
        // typed path on a server is read): the place is the folder's.
        try box.file("folder.zip/inside.txt", "inside")
        let through = ArchiveURL.make(scheme: ArchiveURL.writableScheme, archive: box.url("folder.zip"))
        #expect(try bench.names(through) == ["inside.txt"])
    }

    // MARK: Formats

    @Test func longPaddingBetweenXZStreamsIsRead() throws {
        var file = try XZCoder.compress(Data("first ".utf8))
        file.append(Data(count: 200_000))
        file.append(try XZCoder.compress(Data("second".utf8)))
        file.append(Data(count: 65_536))
        try file.write(to: box.url("padded.xz"))
        let stream = try XZStream(FileRangeStream(try RandomAccessFile(box.url("padded.xz"))))
        var data = Data()
        while let block = try stream.read(upToCount: 1 << 16) { data.append(block) }
        #expect(String(decoding: data, as: UTF8.self) == "first second")
    }

    @Test func aZip64EndRecordIsFoundBehindASelfExtractorStub() throws {
        let plain = try writeZip(
            "wide.zip",
            limits: ZipLimits(maxField: 0xFFFF_FFFE, maxEntries: 2),
            names: ["a.txt", "b.txt", "c.txt", "d.txt"]
        )
        var stubbed = Data(repeating: 0x90, count: 5_000)
        stubbed.append(try Data(contentsOf: plain))
        try stubbed.write(to: box.url("sfx.zip"))
        let contents = try ZipDirectory.read(try RandomAccessFile(box.url("sfx.zip")))
        #expect(contents.isZip64 && contents.records.map(\.name) == ["a.txt", "b.txt", "c.txt", "d.txt"])
        #expect(try bench.names(bench.inside(box.url("sfx.zip"))) == ["a.txt", "b.txt", "c.txt", "d.txt"])
    }

    @Test func aFileThatTakesOverTheNameOfAHardLinkKeepsItsOwnContents() throws {
        var tar = Data()
        tar.append(tarHeader(name: "target.txt", size: 6))
        tar.append(tarBody("target"))
        tar.append(tarHeader(name: "name.txt", type: 49, link: "target.txt"))
        tar.append(tarHeader(name: "name.txt", size: 3))
        tar.append(tarBody("own"))
        tar.append(Data(count: 1_024))
        try tar.write(to: box.url("links.tar"))
        let root = bench.inside(box.url("links.tar"), scheme: ArchiveURL.readOnlyScheme)
        #expect(try bench.read(root.appending(name: "name.txt")) == Data("own".utf8))
        #expect(try bench.read(root.appending(name: "target.txt")) == Data("target".utf8))
    }

    // MARK: Encryption (A023, A048, A042, A098)

    @Test func newArchivesAreEncryptedWithAESAndOldOnesStillOpen() throws {
        let tree = try bench.makeTree()
        let archive = box.url("aes.zip")
        try bench.pack([tree], to: archive) {
            $0.password = "open sesame"
            $0.verifies = true
        }
        let records = try ZipDirectory.read(try RandomAccessFile(archive)).records.filter { !$0.isDirectory }
        #expect(
            !records.isEmpty
                && records.allSatisfy {
                    $0.method == ZipAES.method && $0.aes?.strength == 3 && $0.aes?.version == 2 && $0.crc == 0
                }
        )
        // libarchive reads what was written, with the password and not without.
        let listed = runTool(
            "/usr/bin/bsdtar",
            ["-xOf", archive.path, "--passphrase", "open sesame", "tree/sub/deep/übung – ñ 日本.txt"]
        )
        #expect(listed.status == 0 && listed.output == "unicode name")
        #expect(
            runTool("/usr/bin/bsdtar", ["-xOf", archive.path, "--passphrase", "nope", "tree/readme.txt"]).status != 0
        )
        // Read back here: a wrong password is asked for again, the right one is kept.
        bench.store.close()
        bench.passwords.set(["wrong", "open sesame"])
        #expect(
            try bench.read(bench.inside(archive, "tree/big.log"))
                == Data(contentsOf: tree.appendingPathComponent("big.log"))
        )
        #expect(bench.passwords.asked == 2)
        #expect(try bench.read(bench.inside(archive, "tree/empty.txt")).isEmpty && bench.passwords.asked == 2)
        let back = try bench.unpack(archive, to: box.url("back"))
        #expect(back.problems.isEmpty && snapshot(box.url("back/tree")) == snapshot(tree))

        // What another program encrypted with AES (libarchive writes AE-1, with a checksum).
        #expect(
            runTool(
                "/usr/bin/bsdtar",
                ["-a", "-cf", "theirs.zip", "--options", "zip:encryption=aes256", "--passphrase", "pw", "tree"],
                in: box.root
            )
            .status == 0
        )
        let fresh = try ArchiveBench()
        fresh.passwords.set(["pw"])
        #expect(
            try fresh.read(fresh.inside(box.url("theirs.zip"), "tree/readme.txt"))
                == Data(contentsOf: tree.appendingPathComponent("readme.txt"))
        )
        fresh.store.close()
        // The old encryption is still written on request, for programs that know no other.
        try bench.pack([tree.appendingPathComponent("readme.txt")], to: box.url("old.zip")) {
            $0.password = "pw"
            $0.encryption = .legacy
        }
        #expect(runTool("/usr/bin/unzip", ["-tq", "-P", "pw", box.url("old.zip").path]).status == 0)
        #expect(ArchiveCommands.legacyLabel.contains("weak") && ArchiveCommands.encryptionNote.contains("AES-256"))
    }

    @Test func theCipherMatchesItselfAcrossBlockSizes() throws {
        var plain = Data(count: 100_003)
        plain.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        let salt = Data((0..<16).map { UInt8($0) })
        let (encrypting, decrypting) = (
            try ZipAES.Cipher(password: "pässword", salt: salt, keyLength: 32),
            try ZipAES.Cipher(password: "pässword", salt: salt, keyLength: 32)
        )
        var encrypted = Data()
        var offset = 0
        // Blocks of every awkward length, so the key stream is carried over correctly.
        for size in [1, 15, 16, 17, 31, 4_096, 65_537, 30_000] {
            let end = min(plain.count, offset + size)
            encrypted.append(encrypting.encrypt(plain.subdata(in: offset..<end)))
            offset = end
        }
        encrypted.append(encrypting.encrypt(plain.subdata(in: offset..<plain.count)))
        var whole = encrypted
        decrypting.decrypt(&whole)
        #expect(whole == plain && encrypted != plain)
        #expect(encrypting.authentication() == decrypting.authentication())
        #expect(try ZipAES.Cipher(password: "other", salt: salt, keyLength: 32).verifier != encrypting.verifier)
    }

    @Test func aDeclinedPasswordIsNotAskedForAgainByTheSameOperation() throws {
        let tree = try bench.makeTree()
        let archive = box.url("locked.zip")
        try bench.pack([tree], to: archive) { $0.password = "sesame" }
        bench.store.close()
        // Unpacking with nobody answering asks once, however many members there are and
        // however many threads read them.
        let refused = try bench.unpack(archive, to: box.url("refused"))
        #expect(!refused.problems.isEmpty && bench.passwords.asked == 1)
        // The next operation asks again, once, and every member opens with the answer.
        bench.passwords.set(["sesame"])
        let opened = try bench.unpack(archive, to: box.url("opened"))
        #expect(
            opened.problems.isEmpty && bench.passwords.asked == 2 && snapshot(box.url("opened/tree")) == snapshot(tree)
        )
        // Outside an operation a refusal is remembered for as long as the environment says.
        let fresh = try ArchiveBench()
        fresh.environment.passwordRefusalMemory = 60
        for name in ["readme.txt", "big.log", "empty.txt"] {
            #expect(throws: ArchiveError.self) { try fresh.read(fresh.inside(archive, "tree/" + name)) }
        }
        #expect(fresh.passwords.asked == 1)
        fresh.store.close()
    }

    @Test func unpackingPlainMembersOfAPartlyEncryptedArchiveAsksNothing() throws {
        let tree = try bench.makeTree()
        let archive = box.url("mixed.zip")
        try bench.pack([tree.appendingPathComponent("readme.txt")], to: archive)
        try bench.pack([tree.appendingPathComponent("big.log")], to: archive) { $0.password = "pw" }
        bench.store.close()
        let open = try bench.store.archive(at: archive)
        let unpacker = Unpacker(fileSystems: bench.fileSystems, monitor: bench.monitor, options: UnpackOptions()) {
            _,
            _ in .overwrite
        }
        let result = unpacker.run([Unpacker.Source(archive: open, selection: ["readme.txt"])], into: box.url("plain"))
        #expect(result.problems.isEmpty && box.exists("plain/readme.txt") && bench.passwords.asked == 0)
    }

    // MARK: The temporary folder (A040, A058, A083)

    @Test func whatACrashLeftBehindIsSweptAndWhatWasKeptStays() throws {
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
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: stale.path) && !fm.fileExists(atPath: stale.path + ".external"))
        #expect(fm.fileExists(atPath: kept.path) && fm.fileExists(atPath: alive.path))
        // Only what carries one of the plugin's own temporary names is removed outside.
        #expect(
            !fm.fileExists(atPath: leftover.path) && !fm.fileExists(atPath: spool.path)
                && fm.fileExists(atPath: innocent.path)
        )

        // The folder is the user's alone, and so is what is written into it.
        let scratch = ScratchFolder(in: parent)
        let file = try scratch.newFile()
        try OutputFile(creating: file).close()
        #expect((try fm.attributesOfItem(atPath: scratch.url.path)[.posixPermissions] as? Int) == 0o700)
        #expect((try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
        scratch.removeAll()
        #expect(!fm.fileExists(atPath: scratch.url.path))
    }

    @Test func noCopyIsMadeWhenTheTemporaryVolumeHasNoRoomToSpare() throws {
        try bench.makeTree()
        #expect(runTool("/usr/bin/tar", ["-czf", "tree.tgz", "tree"], in: box.root).status == 0)
        #expect(runTool("/usr/bin/zip", ["-qr", "tree.zip", "tree"], in: box.root).status == 0)
        bench.environment.hasRoom = { _, _ in false }
        // A stream archive is listed and read from the stream, without its unpacked copy.
        let inner = bench.inside(box.url("tree.tgz"), "tree", scheme: ArchiveURL.readOnlyScheme)
        #expect(try bench.names(inner).contains("big.log"))
        let opened = try bench.store.archive(at: box.url("tree.tgz"))
        #expect(!opened.allowsParallelReads && opened.scratchBytes == 0)
        #expect(try bench.read(inner.appending(name: "readme.txt")) == Data(contentsOf: box.url("tree/readme.txt")))
        // An archive that would have to be fetched is refused with a message that says why.
        let onServer = bench.memory.url("/store/tree.zip")
        bench.memory.createDirectory(at: bench.memory.url("/store"))
        let writer = try bench.memory.write(onServer)
        try writer.write(try Data(contentsOf: box.url("tree.zip")))
        try writer.close(attributes: FileAttributes())
        #expect { try bench.store.archive(at: onServer) } throws: { error in
            if case ArchiveError.noScratchRoom = error {
                return true
            }
            return false
        }
        // That says nothing about the file: with room it opens at once.
        bench.environment.hasRoom = { _, _ in true }
        #expect(try bench.names(bench.inside(onServer, "tree")).contains("readme.txt"))
    }

    @Test func archivesNestOnlySoDeep() throws {
        try bench.makeTree()
        #expect(runTool("/usr/bin/zip", ["-qr", "inner.zip", "tree"], in: box.root).status == 0)
        #expect(runTool("/usr/bin/zip", ["-q", "outer.zip", "inner.zip"], in: box.root).status == 0)
        let inner = bench.inside(box.url("outer.zip"), "inner.zip")
        #expect(ArchiveURL.nesting(of: box.url("outer.zip")) == 0 && ArchiveURL.nesting(of: inner) == 1)
        #expect(try bench.names(bench.inside(inner, "tree")).contains("readme.txt"))
        bench.store.close()
        bench.environment.maxNesting = 1
        #expect(throws: ArchiveError.self) { try bench.names(bench.inside(inner, "tree")) }
    }
}
