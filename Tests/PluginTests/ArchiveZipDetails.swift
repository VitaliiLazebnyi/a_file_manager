import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The fine points of ZIP: ZIP64, very many members, encryption, damage and archives of other systems.
@Suite
internal struct ArchiveZipDetails {
    /// The archive file systems and the sandbox of the test.
    internal let bench: ArchiveBench
    /// The test's own folder on the local disk.
    internal var box: Sandbox { bench.box }

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// ZIP64 is used exactly when a size, an offset or the number of members does not fit the classic fields, and such
    /// archives stay readable after a change.
    @Test
    internal func zip64IsUsedExactlyWhereTheClassicFieldsEnd() throws {
        // The rule itself, at the real limits.
        let limits = ZipLimits.standard
        #expect(limits.maxField == 0xFFFF_FFFE && limits.maxEntries == 0xFFFE)

        func write(_ sizes: [Int], limits: ZipLimits) throws -> (url: URL, zip64: Bool) {
            let url = box.url("z-\(UUID().uuidString).zip")
            let output = try OutputFile(creating: url, mode: 0o600)
            let packer = ZipPacker(output, level: 6, password: nil, encryption: .aes256, limits: limits)
            for (index, size) in sizes.enumerated() {
                var sent = false
                let record = ZipRecord.new(
                    name: "file\(index).txt",
                    isDirectory: false,
                    modified: Date(),
                    permissions: 0o644,
                    isSymbolicLink: false
                )
                try packer.add(record, expectedSize: UInt64(size), stored: false) {
                    defer { sent = true }
                    return sent || size == 0 ? nil : Data(repeating: UInt8(65 + index % 26), count: size)
                }
            }
            try packer.finish(comment: Data())
            try output.close(durably: false)
            return (url, packer.writer.usedZip64)
        }

        // Below every limit: a classic archive.
        var small = try write([100, 200, 0], limits: ZipLimits(maxField: 100_000, maxEntries: 3))
        #expect(
            try !small.zip64
                && !ZipDirectory.read(RandomAccessFile(small.url, shownAs: nil), maxEntries: .max, check: nil).isZip64
        )
        // One member more than the end record can count.
        small = try write([100, 200, 0, 5], limits: ZipLimits(maxField: 100_000, maxEntries: 3))
        #expect(small.zip64)
        var contents = try ZipDirectory.read(RandomAccessFile(small.url, shownAs: nil), maxEntries: .max, check: nil)
        #expect(contents.isZip64 && contents.records.count == 4)
        #expect(runTool("/usr/bin/unzip", ["-tq", small.url.path]).status == 0)
        // A member larger than the size fields, and members behind an offset that does not fit.
        let large = try write([5_000, 300, 300], limits: ZipLimits(maxField: 1_000, maxEntries: 100))
        #expect(large.zip64)
        contents = try ZipDirectory.read(RandomAccessFile(large.url, shownAs: nil), maxEntries: .max, check: nil)
        #expect(contents.records.map(\.uncompressedSize) == [5_000, 300, 300])
        let check = runTool("/usr/bin/unzip", ["-tq", large.url.path])
        #expect(check.status == 0, "\(check.output)")
        let opened = try bench.store.archive(at: large.url, cancellation: nil)
        #expect(ArchiveTester.test(opened, cancellation: CancellationFlag(), counter: nil, members: .all).isEmpty)
        #expect(try bench.read(bench.inside(large.url, "file0.txt")) == Data(repeating: 65, count: 5_000))

        // Changing such an archive keeps it readable.
        bench.environment.limits = ZipLimits(maxField: 1_000, maxEntries: 100)
        try bench.zip.remove(bench.inside(large.url, "file1.txt"))
        try bench.store.flush(large.url, cancellation: nil)
        #expect(runTool("/usr/bin/unzip", ["-tq", large.url.path]).status == 0)
        #expect(try bench.names(bench.inside(large.url)) == ["file0.txt", "file2.txt"])
    }

    /// A ZIP64 archive of 70,000 members is listed from its central directory alone, quickly.
    @Test
    internal func aHugeNumberOfEntriesIsListedFromTheDirectoryAlone() throws {
        // More members than the classic end record can count: a real ZIP64 archive.
        let count = 70_000
        let url = box.url("many.zip")
        let output = try OutputFile(creating: url, mode: 0o600)
        let packer = ZipPacker(output, level: 6, password: nil, encryption: .aes256, limits: .standard)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<count {
            var sent = false
            let record = ZipRecord.new(
                name: "folder\(index % 100)/file\(index).txt",
                isDirectory: false,
                modified: stamp,
                permissions: 0o644,
                isSymbolicLink: false
            )
            try packer.add(record, expectedSize: 4, stored: false) {
                defer { sent = true }
                return sent ? nil : Data("\(index % 10)abc".utf8)
            }
        }
        try packer.finish(comment: Data())
        try output.close(durably: false)
        #expect(packer.writer.usedZip64)

        let started = Date()
        let root = bench.inside(url)
        #expect(try bench.zip.list(root, showHidden: true).count == 100)
        let folder = try bench.zip.list(root.appending(name: "folder7"), showHidden: true)
        #expect(folder.count == 700 && folder.allSatisfy { $0.size == 4 && $0.modified == stamp })
        #expect(Date().timeIntervalSince(started) < 20)
        #expect(try bench.read(root.appending(name: "folder7").appending(name: "file69907.txt")) == Data("7abc".utf8))
        let listed = runTool("/usr/bin/unzip", ["-Z1", url.path])
        #expect(listed.status == 0 && listed.output.split(separator: "\n").count == count)
    }

    /// Reading an encrypted ZIP asks for the password, asks again after a wrong one, remembers the right one, and gives
    /// up after three wrong ones.
    @Test
    internal func encryptedZipsAskForThePassword() throws {
        let tree = try bench.makeTree()
        #expect(runTool("/usr/bin/zip", ["-qr", "-P", "sesame", "locked.zip", "tree"], in: box.root).status == 0)
        let locked = box.url("locked.zip")
        let member = bench.inside(locked, "tree/readme.txt")
        #expect(try bench.item(member).size == 17_600)
        // Listing needs no password; reading does.
        #expect(bench.passwords.asked == 0)
        #expect(throws: ArchiveError.self) { try bench.read(member) }
        #expect(bench.passwords.asked == 1)
        // A wrong one is asked for again; the right one is remembered for the archive.
        bench.passwords.set(["wrong", "sesame"])
        #expect(try bench.read(member) == Data(contentsOf: tree.appendingPathComponent("readme.txt")))
        #expect(bench.passwords.asked == 3)
        #expect(
            try bench.read(bench.inside(locked, "tree/big.log"))
                == Data(contentsOf: tree.appendingPathComponent("big.log"))
        )
        #expect(bench.passwords.asked == 3)
        let unpacked = try bench.unpack(locked, to: box.url("back"))
        #expect(unpacked.problems.isEmpty && snapshot(box.url("back/tree")) == snapshot(tree))

        // What is encrypted here the old way, the system's unzip opens with the password and not without.
        let own = box.url("own.zip")
        try bench.pack([tree], to: own) { options in
            options.password = "open sesame"
            options.encryption = .legacy
            options.verifies = true
        }
        #expect(runTool("/usr/bin/unzip", ["-tq", "-P", "open sesame", own.path]).status == 0)
        #expect(runTool("/usr/bin/unzip", ["-tq", "-P", "nope", own.path]).status != 0)
        #expect(try bench.store.archive(at: own, cancellation: nil).hasEncryptedMembers)

        // Three wrong answers end the attempt with a clear error. (With AES, whose check of the
        // password lets a wrong one through once in 65,536 times; the old way's check, once in 256
        // times, and the member's checksum then tells.)
        let strong = box.url("strong.zip")
        try bench.pack([tree], to: strong) { options in
            options.password = "open sesame"
            options.encryption = .aes256
        }
        let fresh = try ArchiveBench()
        fresh.passwords.set(["a", "b", "c"])
        #expect { try fresh.read(fresh.inside(strong, "tree/readme.txt")) } throws: { error in
            if case ArchiveError.wrongPassword = error {
                return true
            }
            return false
        }
    }

    /// A damaged member is found by the test and by unpacking, which leaves no damaged file behind; a TAR with a broken
    /// header does not open.
    @Test
    internal func aDamagedMemberIsFoundByTheTest() throws {
        let tree = try bench.makeTree()
        let archive = box.url("tree.zip")
        try bench.pack([tree], to: archive) { $0.level = 0 }
        var opened = try bench.store.archive(at: archive, cancellation: nil)
        #expect(ArchiveTester.test(opened, cancellation: CancellationFlag(), counter: nil, members: .all).isEmpty)

        // One byte in the middle of the stored random data is flipped.
        var bytes = try Data(contentsOf: archive)
        let needle = try Data(contentsOf: tree.appendingPathComponent("sub/random.bin")).prefix(64)
        let position = try #require(bytes.range(of: needle)).lowerBound + 1_000
        bytes[position] ^= 0xFF
        try bytes.write(to: archive)
        opened = try bench.store.archive(at: archive, cancellation: nil)
        let problems = ArchiveTester.test(opened, cancellation: CancellationFlag(), counter: nil, members: .all)
        #expect(
            problems.count == 1 && problems.first?.contains("random.bin") == true
                && problems.first?.contains("CRC") == true
        )
        // Unpacking reports it too and does not leave the damaged file behind.
        let result = try bench.unpack(archive, to: box.url("back"))
        #expect(
            result.problems.count == 1 && !box.exists("back/tree/sub/random.bin") && box.exists("back/tree/readme.txt")
        )
        #expect(namesOnDisk(box.url("back/tree/sub")) == [".hidden", "deep"])

        // A deflated member that is cut short, and a TAR with a broken header.
        try bench.pack([tree], to: box.url("deflated.zip"))
        var deflated = try Data(contentsOf: box.url("deflated.zip"))
        let log = try #require(deflated.range(of: Data("tree/big.log".utf8))).upperBound
        deflated.replaceSubrange((log + 2_000)..<(log + 2_040), with: Data(repeating: 0x55, count: 40))
        try deflated.write(to: box.url("deflated.zip"))
        let broken = ArchiveTester.test(
            try bench.store.archive(at: box.url("deflated.zip"), cancellation: nil),
            cancellation: CancellationFlag(),
            counter: nil,
            members: .all
        )
        #expect(broken.count == 1 && broken.first?.contains("big.log") == true)

        try bench.pack([tree], to: box.url("tree.tar")) { $0.format = .tar }
        var tar = try Data(contentsOf: box.url("tree.tar"))
        tar[600] = 0x7F
        tar[512] = 0x7F
        try tar.write(to: box.url("tree.tar"))
        #expect(throws: ArchiveError.self) { try bench.store.archive(at: box.url("tree.tar"), cancellation: nil) }
    }

    /// A ZIP written by a DOS program shows its code-page names, DOS dates and attributes, hides paths that leave the
    /// folder, and keeps its comment.
    @Test
    internal func namesDatesAndAttributesOfForeignZips() throws {
        // A ZIP as a DOS program writes it: backslashes, DOS attributes, a code-page name.
        let url = box.url("dos.zip")
        let output = try OutputFile(creating: url, mode: 0o600)
        let writer = ZipWriter(output, limits: .standard)
        var record = ZipRecord()
        record.versionMadeBy = 20
        // DIR\über.txt in code page 437.
        record.nameBytes = Data([0x44, 0x49, 0x52, 0x5C, 0x81, 0x62, 0x65, 0x72, 0x2E, 0x74, 0x78, 0x74])
        record.externalAttributes = 0x21
        (record.dosTime, record.dosDate) = DOSTime.encode(DOSTime.date(time: 0x6000, date: 0x5221))
        try writer.end(try writer.begin(record, localExtra: nil, expectedSize: nil), record, headerChanged: false)
        // Paths that try to leave the folder they are unpacked into are not shown and not unpacked.
        var evil = ZipRecord.new(
            name: "../../evil.txt",
            isDirectory: false,
            modified: Date(),
            permissions: 0o644,
            isSymbolicLink: false
        )
        evil.setName("../../evil.txt")
        try writer.end(try writer.begin(evil, localExtra: nil, expectedSize: nil), evil, headerChanged: false)
        try writer.finish(comment: Data("a comment".utf8))
        try output.close(durably: false)

        let root = bench.inside(url)
        #expect(try bench.names(root) == ["DIR"])
        let file = try #require(try bench.zip.list(root.appending(name: "DIR"), showHidden: true).first)
        #expect(file.name == "über.txt" && file.permissions == 0o444)
        #expect(
            Calendar.current.dateComponents([.year, .month, .day, .hour], from: file.modified)
                == DateComponents(year: 2_021, month: 1, day: 1, hour: 12)
        )
        try bench.unpack(url, to: box.url("safe/inner"))
        #expect(
            box.exists("safe/inner/DIR/über.txt") && !box.exists("safe/inner/evil.txt") && !box.exists("evil.txt")
                && !box.exists("safe/evil.txt")
        )
        // The comment survives a change of the archive.
        try bench.zip.createDirectory(at: root.appending(name: "new"))
        try bench.store.flush(url, cancellation: nil)
        #expect(runTool("/usr/bin/unzip", ["-z", url.path]).output.contains("a comment"))
    }
}
