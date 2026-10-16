import AFMKernel
import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// One 512-byte TAR header built by hand, for headers the packer never writes.
private func tarBlock(
    name: String,
    type: UInt8 = 48,
    size: UInt64 = 0,
    link: String = "",
    magic: [UInt8] = Array("ustar\u{0}00".utf8),
    patch: (inout [UInt8]) -> Void = { _ in }
) -> Data {
    var block = [UInt8](repeating: 0, count: 512)
    func put(_ bytes: [UInt8], at offset: Int) {
        for (index, byte) in bytes.enumerated() { block[offset + index] = byte }
    }
    func octal(_ value: UInt64, _ length: Int) -> [UInt8] {
        let digits = String(value, radix: 8)
        return Array((String(repeating: "0", count: length - 1 - digits.count) + digits).utf8)
    }
    put(Array(name.utf8), at: 0)
    put(octal(0o644, 8), at: 100)
    put(octal(size, 12), at: 124)
    put(octal(1_600_000_000, 12), at: 136)
    block[156] = type
    put(Array(link.utf8), at: 157)
    put(magic, at: 257)
    patch(&block)
    for index in 148..<156 { block[index] = 32 }
    let sum = block.reduce(0) { $0 + Int($1) }
    put(Array(String(format: "%06o", sum).utf8) + [0, 32], at: 148)
    return Data(block)
}

private func tarData(_ text: String) -> Data {
    var data = Data(text.utf8)
    data.append(Data(count: (512 - data.count % 512) % 512))
    return data
}

private func quarantine(of url: URL) -> String? {
    let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
    guard size > 0 else { return nil }
    var value = [UInt8](repeating: 0, count: size)
    let got = getxattr(url.path, "com.apple.quarantine", &value, size, 0, XATTR_NOFOLLOW)
    return got > 0 ? String(decoding: value.prefix(got), as: UTF8.self) : nil
}

/// The defects found in review of the archives, each held down by a test.
@Suite struct ArchiveFixes {
    let bench: ArchiveBench
    var box: Sandbox { bench.box }

    init() throws {
        bench = try ArchiveBench()
    }

    func makeZip(_ name: String = "tree.zip") throws -> URL {
        try bench.makeTree()
        #expect(runTool("/usr/bin/zip", ["-qr", name, "tree"], in: box.root).status == 0)
        return box.url(name)
    }

    func write(_ text: String, to url: URL) throws {
        let writer = try bench.fileSystems.provider(for: url).write(url)
        try writer.write(Data(text.utf8))
        try writer.close(attributes: FileAttributes())
    }

    func listed(_ archive: URL) -> [String] {
        runTool("/usr/bin/unzip", ["-Z1", archive.path]).output.split(separator: "\n").map(String.init)
    }

    func isSound(_ archive: URL) -> Bool {
        runTool("/usr/bin/unzip", ["-tq", archive.path]).status == 0
    }

    /// A ZIP written record by record, for directories no packer would write.
    func writeZip(_ name: String, limits: ZipLimits = .standard, _ fill: (ZipWriter) throws -> Void) throws -> URL {
        let url = box.url(name)
        let output = try OutputFile(creating: url)
        let writer = ZipWriter(output, limits: limits)
        try fill(writer)
        try writer.finish()
        try output.close()
        return url
    }

    // MARK: A1 – nothing is lost when a write fails

    @Test func aFailedWriteKeepsEveryChangeForTheNextAttempt() throws {
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        try write("precious", to: tree.appending(name: "new.txt"))
        try bench.zip.createDirectory(at: tree.appending(name: "made"))
        // The folder cannot be written to: no new file can be put next to the archive.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: box.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: box.root.path) }
        let before = FileSignature.of(archive.path)
        for _ in 0..<2 {
            #expect(bench.store.flushAll().count == 1)
            // The archive is untouched, and the member is still there to read.
            #expect(FileSignature.of(archive.path) == before && isSound(archive))
            #expect(try bench.read(tree.appending(name: "new.txt")) == Data("precious".utf8))
            #expect(try bench.names(tree).contains("made") && bench.store.archive(at: archive).hasPendingChanges)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: box.root.path)
        #expect(bench.store.flushAll().isEmpty && isSound(archive))
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/new.txt"]).output == "precious")
        #expect(listed(archive).contains("tree/made/"))
    }

    @Test func aCopiedFileIsInTheArchiveFileBeforeTheJobIsDone() throws {
        let archive = try makeZip()
        try box.file("in/one.txt", "one")
        try box.file("in/two.txt", String(repeating: "two ", count: 100_000))
        let result = runJob(
            .move,
            [box.url("in/one.txt"), box.url("in/two.txt")],
            to: TargetSpec(directory: bench.inside(archive, "tree")),
            fileSystems: bench.fileSystems
        )
        #expect(result.completed.count == 2 && !box.exists("in/one.txt"))
        // Nothing was asked to write: the rename of each file did.
        #expect(try !bench.store.archive(at: archive).hasPendingChanges)
        #expect(isSound(archive) && Set(listed(archive)).isSuperset(of: ["tree/one.txt", "tree/two.txt"]))
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/two.txt"]).output.count == 400_000)
        #expect(namesOnDisk(box.root).filter { $0.hasSuffix(".tmp") }.isEmpty)
    }

    @Test(arguments: [true, false]) func manyThreadsBringFilesInAtOnce(clones: Bool) throws {
        bench.environment.clonesArchives = clones
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        let failures = SharedCounter()
        // Each thread does what a copy job does: a temporary name, then the real one. Others
        // list and read meanwhile.
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            do {
                if index % 4 == 3 {
                    _ = try bench.names(tree)
                    _ = try bench.read(tree.appending(name: "readme.txt"))
                    return
                }
                let temporary = tree.appending(name: ".afm-\(index).tmp")
                let writer = try bench.zip.write(temporary)
                try writer.write(Data(String(repeating: "file \(index) ", count: 2_000 * (index + 1)).utf8))
                try writer.close(attributes: FileAttributes())
                try bench.zip.move(temporary, to: tree.appending(name: "file\(index).txt"), replacing: false)
            } catch {
                failures.add(1)
            }
        }
        #expect(failures.value == 0)
        #expect(bench.store.flushAll().isEmpty && isSound(archive))
        let names = listed(archive)
        #expect(names.filter { $0.hasPrefix("tree/file") }.count == 18 && !names.contains { $0.hasSuffix(".tmp") })
        #expect(
            runTool("/usr/bin/unzip", ["-p", archive.path, "tree/file5.txt"]).output
                == String(repeating: "file 5 ", count: 12_000)
        )
        #expect(namesOnDisk(box.root).filter { $0.hasSuffix(".tmp") }.isEmpty)
    }

    @Test func aMoveKeepsItsSourceWhenTheArchiveCannotTakeTheFile() throws {
        let archive = try makeZip()
        try box.file("in/one.txt", "one")
        // The disk is full: the member is refused when its writer closes.
        bench.environment.hasRoom = { _, _ in false }
        let answers = Answers()
        var result = runJob(
            .move,
            [box.url("in/one.txt")],
            to: TargetSpec(directory: bench.inside(archive, "tree")),
            answers: answers,
            fileSystems: bench.fileSystems
        )
        #expect(result.completed.isEmpty && answers.errors.count == 1 && box.read("in/one.txt") == "one")
        #expect(try !bench.names(bench.inside(archive, "tree")).contains("one.txt"))
        bench.environment.hasRoom = { _, _ in true }

        // The write into the archive fails at the rename (something that is no archive lies in
        // its place): the rename fails with it and is taken back.
        try write("data", to: bench.inside(archive, "tree/.part"))
        let opened = try bench.store.archive(at: archive)
        let sound = try Data(contentsOf: archive)
        try Data("no archive".utf8).write(to: archive)
        #expect(throws: ArchiveError.self) { try opened.move("tree/.part", to: "tree/final.txt", replacing: false) }
        #expect(opened.entry("tree/final.txt") == nil && opened.entry("tree/.part") != nil && opened.hasPendingChanges)
        try sound.write(to: archive)
        try opened.move("tree/.part", to: "tree/final.txt", replacing: false)
        #expect(!opened.hasPendingChanges && listed(archive).contains("tree/final.txt") && isSound(archive))
        result = runJob(
            .move,
            [box.url("in/one.txt")],
            to: TargetSpec(directory: bench.inside(archive, "tree")),
            fileSystems: bench.fileSystems
        )
        #expect(result.completed.count == 1 && !box.exists("in/one.txt") && listed(archive).contains("tree/one.txt"))
    }

    @Test func aFailedUploadIsRepeated() throws {
        let tree = try bench.makeTree()
        let onServer = bench.memory.url("/store/tree.zip")
        try bench.pack([tree], to: onServer)
        let root = ArchiveURL.make(scheme: "zip", archive: onServer)
        try write("late", to: root.appending(name: "late.txt"))
        // The server loses the folder: the changed copy cannot be sent.
        bench.memory.removeTree("/store")
        #expect(bench.store.flushAll().count == 1)
        #expect(try bench.store.archive(at: onServer).hasPendingChanges)
        _ = bench.memory.addDirectory("/store")
        #expect(bench.store.flushAll().isEmpty)
        let reader = try bench.memory.read(onServer)
        var bytes = Data()
        while let block = try reader.read(upToCount: 1 << 20) { bytes.append(block) }
        try bytes.write(to: box.url("fetched.zip"))
        #expect(isSound(box.url("fetched.zip")) && listed(box.url("fetched.zip")).contains("late.txt"))
    }

    @Test func membersThatCannotBeWrittenAreSavedInAnArchiveOfTheirOwn() throws {
        let archive = try makeZip()
        try write("only copy", to: bench.inside(archive, "tree/rescued.txt"))
        let opened = try bench.store.archive(at: archive)
        // Another program leaves something that is no archive in its place.
        try Data("not a zip".utf8).write(to: archive)
        #expect(bench.store.flushAll().count == 1 && opened.hasPendingChanges)
        guard case .saved(let saved) = opened.rescue() else {
            Issue.record("nothing was saved")
            return
        }
        #expect(saved.lastPathComponent == "tree (unsaved changes).zip")
        #expect(runTool("/usr/bin/unzip", ["-p", saved.path, "tree/rescued.txt"]).output == "only copy")
        // Renames and deletions alone leave nothing to save.
        let other = try makeZip("other.zip")
        try bench.zip.remove(bench.inside(other, "tree/empty.txt"))
        guard case .nothingToSave = try bench.store.archive(at: other).rescue() else {
            Issue.record("something was saved")
            return
        }
    }

    @Test func newMembersSurviveAChangeFromOutside() throws {
        let archive = try makeZip()
        try write("ours", to: bench.inside(archive, "tree/readme.txt.new"))
        try write("ours too", to: bench.inside(archive, "tree/sub/.hidden2"))
        try bench.zip.remove(bench.inside(archive, "tree/empty.txt"))
        Thread.sleep(forTimeInterval: 0.02)
        try box.file("tree/readme.txt.new", "theirs")
        #expect(runTool("/usr/bin/zip", ["-q", "tree.zip", "tree/readme.txt.new"], in: box.root).status == 0)
        // The deletion cannot be carried over and is reported; the new members are added to
        // the archive as it is now, the one whose name was taken under a name of its own.
        let failures = bench.store.flushAll()
        #expect(
            failures.count == 1
                && failures.first?.error.localizedDescription.contains("changed by another program") == true
        )
        #expect(isSound(archive))
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/readme.txt.new"]).output == "theirs")
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/readme.txt (2).new"]).output == "ours")
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/sub/.hidden2"]).output == "ours too")
        #expect(listed(archive).contains("tree/empty.txt") && bench.store.flushAll().isEmpty)
    }

    // MARK: A2 – crafted archives are refused, not crashed on

    @Test func aDirectoryWithImpossibleOffsetsIsDamaged() throws {
        func archive(offset: UInt64, stub: Int) throws -> URL {
            var central = Data()
            central.appendLE(UInt32(0x0201_4B50))
            for value in [UInt16(45), 45, 0, 0, 0, 0x21] { central.appendLE(value) }
            for value in [UInt32(0), 0, 0] { central.appendLE(value) }
            for value in [UInt16(1), 12, 0, 0, 0] { central.appendLE(value) }
            central.appendLE(UInt32(0))
            central.appendLE(UInt32(0xFFFF_FFFF))
            central.append(UInt8(ascii: "a"))
            central.appendLE(UInt16(1))
            central.appendLE(UInt16(8))
            central.appendLE(offset)
            var file = Data(count: stub)
            file.append(central)
            file.appendLE(UInt32(0x0605_4B50))
            for value in [UInt16(0), 0, 1, 1] { file.appendLE(value) }
            file.appendLE(UInt32(central.count))
            // The directory is said to start at 0 and starts behind the stub: every offset shifts.
            file.appendLE(UInt32(0))
            file.appendLE(UInt16(0))
            let url = box.url("crafted-\(stub)-\(offset % 7).zip")
            try file.write(to: url)
            return url
        }
        #expect(throws: ArchiveError.self) { try ZipDirectory.read(RandomAccessFile(archive(offset: .max, stub: 1))) }
        #expect(throws: ArchiveError.self) { try bench.names(bench.inside(archive(offset: .max - 5, stub: 300))) }
        // Without a shift the directory can be read; the member is refused when it is opened.
        let plain = try archive(offset: .max, stub: 0)
        #expect(try bench.names(bench.inside(plain)) == ["a"])
        #expect(throws: ArchiveError.self) { try bench.read(bench.inside(plain, "a")) }
        let opened = try bench.store.archive(at: plain)
        #expect(ArchiveTester.test(opened, cancellation: CancellationFlag()).count == 1)
    }

    @Test func tarHeadersWithImpossibleSizesAreDamaged() throws {
        // GNU's binary size field with every bit set.
        var data = tarBlock(name: "huge.bin") { block in
            block[124] = 0x80
            for index in 125..<136 { block[index] = 0xFF }
        }
        data.append(TarHeader.endOfArchive)
        try data.write(to: box.url("binary.tar"))
        #expect(throws: ArchiveError.self) {
            try bench.names(bench.inside(box.url("binary.tar"), scheme: ArchiveURL.readOnlyScheme))
        }
        // The same through a pax record.
        let record = "29 size=18446744073709551615\n"
        #expect(record.utf8.count == 29)
        data = tarBlock(name: "PaxHeader/x", type: 120, size: 29)
        data.append(tarData(record))
        data.append(tarBlock(name: "huge.bin"))
        data.append(TarHeader.endOfArchive)
        try data.write(to: box.url("pax.tar"))
        #expect(throws: ArchiveError.self) {
            try bench.names(bench.inside(box.url("pax.tar"), scheme: ArchiveURL.readOnlyScheme))
        }
        // A size just below the limit is refused when its data turns out not to be there.
        data = tarBlock(name: "claims.bin") { block in
            block[124] = 0x80
            block[128] = 0x7F
        }
        try data.write(to: box.url("claims.tar"))
        #expect(throws: ArchiveError.self) {
            try bench.names(bench.inside(box.url("claims.tar"), scheme: ArchiveURL.readOnlyScheme))
        }
    }

    @Test func paxRecordsShorterThanTheirOwnLengthEndTheList() {
        for text in ["1 ", "01 ", "0000002 a", "3 a", "0 ", "-5 x=y\n", "99999999999999999999999 a=b\n", " ", "5", ""] {
            #expect(TarHeader.paxRecords(Data(text.utf8)).isEmpty, "\(text)")
        }
        #expect(TarHeader.paxRecords(Data("12 path=abc\n1 ".utf8)) == ["path": "abc"])
        #expect(TarHeader.paxRecords(Data("12 path=abc\n8 a=bcd\n".utf8)) == ["path": "abc", "a": "bcd"])
        // Times no calendar knows do not get far.
        #expect(
            TarHeader.date(.nan) == Date(timeIntervalSince1970: 0)
                && TarHeader.date(.infinity).timeIntervalSince1970 < 3e11
        )
        var record = ZipRecord.new(
            name: "a",
            isDirectory: false,
            modified: Date(timeIntervalSince1970: .nan),
            permissions: 0o644
        )
        record.setModified(Date(timeIntervalSince1970: .infinity))
        #expect(record.extra.count == 9)
    }

    @Test func sizesThatSumPastTheLargestNumberAreOnlyNumbers() throws {
        #expect(Int64.max.addingSaturated(5) == Int64.max)
        #expect(Int64(3).addingSaturated(4) == 7)
        #expect(UInt64.max.plusClamped(1) == UInt64.max)
        let archive = try writeZip("claims.zip") { writer in
            for index in 0..<3 {
                var record = ZipRecord.new(
                    name: "claim\(index).bin",
                    isDirectory: false,
                    modified: Date(),
                    permissions: 0o644
                )
                record.uncompressedSize = 1 << 62 + UInt64(index)
                try writer.copyMember(record)
            }
        }
        let opened = try bench.store.archive(at: archive)
        #expect(opened.entries.map(\.size) == [1 << 62, 1 << 62 + 1, 1 << 62 + 2])
        // Unpacking and testing add the sizes up for their progress.
        let result = try bench.unpack(archive, to: box.url("claimed"))
        #expect(result.unpacked == 3 && !result.cancelled)
        #expect(bench.monitor.reports.last?.bytesTotal == .max)
        #expect(ArchiveTester.test(opened, cancellation: CancellationFlag()).count == 3)
    }

    @Test func extraFieldsThatFillAnEntryMakeWayInsteadOfOverflowing() throws {
        // One field of nearly 64 KB, as the largest an entry can carry.
        var extra = Data()
        extra.appendLE(UInt16(0xCAFE))
        extra.appendLE(UInt16(0xFFFF - 4))
        extra.append(Data(repeating: 7, count: 0xFFFF - 4))
        var record = ZipRecord()
        record.nameBytes = Data("full.txt".utf8)
        record.extra = extra
        // The time field no longer fits beside it: the old field goes.
        var dated = record
        dated.setModified(Date(timeIntervalSince1970: 1_650_000_000))
        #expect(dated.extra.count == 9 && dated.modified == Date(timeIntervalSince1970: 1_650_000_000))
        // The 64-bit field no longer fits beside it either, in both headers.
        let limits = ZipLimits(maxField: 10, maxEntries: 100)
        let archive = try writeZip("full.zip", limits: limits) { writer in
            try writer.copyMember(record)
            var large = record
            large.uncompressedSize = 500
            try writer.copyMember(large)
            try writer.copyMember(dated)
        }
        let contents = try ZipDirectory.read(RandomAccessFile(archive))
        #expect(
            contents.records.map(\.uncompressedSize) == [0, 500, 0]
                && contents.records.map(\.extra.count) == [0xFFFF, 0, 9]
        )
        // A name longer than a header can say is an error, not a crash.
        var long = ZipRecord()
        long.nameBytes = Data(repeating: 97, count: 70_000)
        #expect(throws: ArchiveError.self) { try writeZip("long.zip") { try $0.copyMember(long) } }
        // A stretch that reaches past the end of the file ends with the file.
        let file = try RandomAccessFile(archive)
        let stream = FileRangeStream(file, offset: file.size - 2, length: .max)
        #expect(try stream.read(upToCount: 100)?.count == 2)
        #expect(throws: ArchiveError.self) { try FileRangeStream(file, offset: .max, length: .max).skip(1) }
    }

    // MARK: A3 – an archive that is being written to is not let go

    @Test func anArchiveWithAnOpenWriterStaysInTheStore() throws {
        let first = try makeZip("first.zip")
        let opened = try bench.store.archive(at: first)
        let writer = try bench.zip.write(bench.inside(first, "tree/slow.txt"))
        try writer.write(Data("slow".utf8))
        // More archives than the store keeps.
        for index in 0..<20 {
            let url = try writeZip("filler\(index).zip") { _ in }
            _ = try bench.store.archive(at: url)
        }
        #expect(try bench.store.archive(at: first) === opened)
        try writer.close(attributes: FileAttributes())
        for index in 0..<20 { _ = try bench.store.archive(at: box.url("filler\(index).zip")) }
        #expect(try bench.store.archive(at: first) === opened && opened.hasPendingChanges)
        #expect(bench.store.flushAll().isEmpty && listed(first).contains("tree/slow.txt"))
        // With nothing waiting it goes like any other.
        for index in 0..<20 { _ = try bench.store.archive(at: box.url("filler\(index).zip")) }
        #expect(try bench.store.archive(at: first) !== opened)
    }

    @Test func pendingChangesKeepAnArchiveAliveUntilTheyAreWritten() throws {
        let archive = try makeZip()
        bench.environment.flushDelay = 0.05
        // (The urgent timer follows the patient one closely: see `changesAreWrittenShortlyAfterTheLastOne`.)
        bench.environment.escalationDelay = 0.3
        let changed = DispatchSemaphore(value: 0)
        bench.environment.contentsChanged = { _ in changed.signal() }
        // Opened outside the store, and no reference kept beyond the writer's.
        var writer: (any FileWriter)? = try OpenArchive(
            archiveURL: archive,
            localURL: archive,
            fetchedCopy: nil,
            remoteStamp: nil,
            environment: bench.environment
        )
        .write("tree/kept.txt")
        try writer?.write(Data("kept".utf8))
        try writer?.close(attributes: FileAttributes())
        writer = nil
        // (A generous wait: the timer runs at low priority, behind whatever else the machine does.)
        #expect(changed.wait(timeout: .now() + 60) == .success)
        #expect(listed(archive).contains("tree/kept.txt") && isSound(archive))
    }

    // MARK: A4 – a reader that was opened before the archive was rewritten

    @Test(arguments: [true, false]) func anOpenReaderSurvivesTheRewriteOfItsArchive(clones: Bool) throws {
        bench.environment.clonesArchives = clones
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        let expected = try Data(contentsOf: box.url("tree/readme.txt"))
        let opened = try bench.store.archive(at: archive)
        let entry = try #require(opened.entry("tree/readme.txt"))
        let reader = try bench.zip.read(tree.appending(name: "readme.txt"))
        #expect(try reader.read(upToCount: 100)?.count == 100)
        // Members in front of it go, and others arrive: every position in the file changes.
        try bench.zip.remove(tree.appending(name: "big.log"))
        try bench.zip.remove(tree.appending(name: "empty.txt"))
        try write("new", to: tree.appending(name: "new.txt"))
        try bench.store.flush(archive)
        try reader.seek(to: 0)
        var data = Data()
        while let block = try reader.read(upToCount: 5_000) { data.append(block) }
        reader.close()
        #expect(data == expected)
        // The entry looked up before the rewrite reads the same bytes, and so does a new one.
        let stream = try opened.open(entry)
        #expect(try stream.readFully(1 << 20) == expected)
        #expect(try bench.read(tree.appending(name: "readme.txt")) == expected && isSound(archive))
    }

    // MARK: A5 – the time of an encrypted member

    @Test func changingTheTimeOfAnEncryptedMemberKeepsItReadable() throws {
        let tree = try bench.makeTree()
        let archive = box.url("secret.zip")
        // The old encryption, whose check byte is the time; `unzip` reads no other.
        try bench.pack([tree.appendingPathComponent("readme.txt")], to: archive) {
            $0.password = "sesame"
            $0.encryption = .legacy
        }
        let member = bench.inside(archive, "readme.txt")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try bench.zip.setAttributes(FileAttributes(modified: stamp), of: member)
        try bench.store.flush(archive)
        bench.store.close()
        bench.passwords.set(["sesame"])
        #expect(try bench.item(member).modified == stamp)
        #expect(try bench.read(member) == Data(contentsOf: tree.appendingPathComponent("readme.txt")))
        let check = runTool("/usr/bin/unzip", ["-P", "sesame", "-tq", archive.path])
        #expect(check.status == 0, "\(check.output)")
    }

    // MARK: A6 – changes are appended

    @Test func addingRenamingAndDatingLeaveTheOldMembersWhereTheyAre() throws {
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        let original = try Data(contentsOf: archive)
        let old = try ZipDirectory.read(RandomAccessFile(archive))
        func offsets() throws -> [String: UInt64] {
            var found: [String: UInt64] = [:]
            for record in try ZipDirectory.read(RandomAccessFile(archive)).records {
                if case .archive(let offset, _) = record.source { found[record.name] = offset }
            }
            return found
        }
        let before = try offsets()
        let stamp = Date(timeIntervalSince1970: 1_650_000_000)

        try write("appended", to: tree.appending(name: "added.txt"))
        try bench.zip.createDirectory(at: tree.appending(name: "folder"))
        try bench.zip.setAttributes(
            FileAttributes(modified: stamp, permissions: 0o600),
            of: tree.appending(name: "readme.txt")
        )
        try bench.zip.move(tree.appending(name: "empty.txt"), to: tree.appending(name: "void.txt"), replacing: false)
        try bench.store.flush(archive)

        // The members' data was not written again: the file starts as it did, but for the
        // four bytes of the time that was changed.
        var now = try Data(contentsOf: archive)
        let after = try offsets()
        let patched = Int(try #require(before["tree/readme.txt"])) + 10
        #expect(now.count > original.count)
        now.replaceSubrange(patched..<patched + 4, with: original[patched..<patched + 4])
        let stampAt = try #require(now.range(of: Data([0x55, 0x54]), in: patched..<patched + 200))
        now.replaceSubrange(
            stampAt.lowerBound + 5..<stampAt.lowerBound + 9,
            with: original[stampAt.lowerBound + 5..<stampAt.lowerBound + 9]
        )
        #expect(now.prefix(Int(old.directoryOffset)) == original.prefix(Int(old.directoryOffset)))
        for (name, offset) in before where name != "tree/empty.txt" { #expect(after[name] == offset, "\(name)") }
        #expect(
            try #require(after["tree/added.txt"]) >= old.directoryOffset
                && #require(after["tree/void.txt"]) >= old.directoryOffset
        )
        #expect(after["tree/empty.txt"] == nil && after["tree/folder/"] != nil)

        // Every reader agrees with the result, the system's included.
        let check = runTool("/usr/bin/unzip", ["-tq", archive.path])
        #expect(check.status == 0, "\(check.output)")
        try box.folder("unzipped")
        #expect(runTool("/usr/bin/unzip", ["-q", archive.path, "-d", box.url("unzipped").path]).status == 0)
        let attributes = try FileManager.default.attributesOfItem(atPath: box.url("unzipped/tree/readme.txt").path)
        #expect(attributes[.modificationDate] as? Date == stamp && attributes[.posixPermissions] as? Int == 0o600)
        #expect(
            box.read("unzipped/tree/added.txt") == "appended" && box.exists("unzipped/tree/void.txt")
                && box.exists("unzipped/tree/folder")
        )
        bench.store.close()
        #expect(try bench.names(tree) == ["added.txt", "big.log", "folder", "hollow", "readme.txt", "sub", "void.txt"])
        #expect(try bench.item(tree.appending(name: "readme.txt")).modified == stamp)

        // A deletion writes the archive anew, and with that the stretch the rename left is gone.
        let grown = try Data(contentsOf: archive).count
        try bench.zip.remove(tree.appending(name: "big.log"))
        try bench.store.flush(archive)
        #expect(try Data(contentsOf: archive).count < grown / 2 && isSound(archive))
        #expect(namesOnDisk(box.root).filter { $0.hasSuffix(".tmp") }.isEmpty)
    }

    @Test func manyRenamesEndInOneRewriteInsteadOfAnArchiveFullOfHoles() throws {
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        let size = try Data(contentsOf: archive).count
        // Renaming the largest member again and again appends it each time, until the unused
        // stretches would be a quarter of the file.
        var name = "big.log"
        for round in 0..<6 {
            try bench.zip.move(
                tree.appending(name: name),
                to: tree.appending(name: "big\(round).log"),
                replacing: false
            )
            name = "big\(round).log"
            try bench.store.flush(archive)
            #expect(isSound(archive))
        }
        #expect(try Data(contentsOf: archive).count < size * 2)
        #expect(try bench.read(tree.appending(name: name)) == Data(contentsOf: box.url("tree/big.log")))
    }

    @Test(arguments: [true, false]) func aSelfExtractingArchiveKeepsItsProgram(clones: Bool) throws {
        bench.environment.clonesArchives = clones
        let plain = try makeZip("plain.zip")
        let stub =
            Data("#!/bin/sh\necho this would unpack what follows\nexit 0\n".utf8) + Data(repeating: 0x90, count: 5_000)
        let archive = box.url("sfx.zip")
        try (stub + Data(contentsOf: plain)).write(to: archive)
        let tree = bench.inside(archive, "tree")
        #expect(try bench.names(tree).count == 5)
        try write("added", to: tree.appending(name: "added.txt"))
        try bench.store.flush(archive)
        #expect(try Data(contentsOf: archive).prefix(stub.count) == stub)
        try bench.zip.remove(tree.appending(name: "big.log"))
        try bench.store.flush(archive)
        #expect(try Data(contentsOf: archive).prefix(stub.count) == stub)
        bench.store.close()
        #expect(try bench.names(tree) == ["added.txt", "empty.txt", "hollow", "readme.txt", "sub"])
        #expect(try bench.read(tree.appending(name: "readme.txt")) == Data(contentsOf: box.url("tree/readme.txt")))
        // The offsets now count from the start of the file, which is what unzip expects.
        let check = runTool("/usr/bin/unzip", ["-tq", archive.path])
        #expect(check.status == 0, "\(check.output)")
    }

    @Test func anArchiveThatListsANameTwiceIsNotChanged() throws {
        let archive = try writeZip("twice.zip") { writer in
            for _ in 0..<2 {
                try writer.copyMember(.new(name: "same.txt", isDirectory: false, modified: Date(), permissions: 0o644))
            }
            try writer.copyMember(.new(name: "/", isDirectory: true, modified: Date(), permissions: 0o755))
            try writer.copyMember(.new(name: "other.txt", isDirectory: false, modified: Date(), permissions: 0o644))
        }
        #expect(try bench.names(bench.inside(archive)) == ["other.txt", "same.txt"])
        #expect(throws: ArchiveError.self) { try bench.zip.remove(bench.inside(archive, "other.txt")) }
        #expect(throws: ArchiveError.self) { _ = try bench.zip.write(bench.inside(archive, "new.txt")) }
        #expect(listed(archive).count == 4)
        // An entry without a usable name is not shown, and stays when the archive is changed.
        let odd = try writeZip("odd.zip") { writer in
            try writer.copyMember(.new(name: "/", isDirectory: true, modified: Date(), permissions: 0o755))
            try writer.copyMember(.new(name: "other.txt", isDirectory: false, modified: Date(), permissions: 0o644))
        }
        for clones in [true, false] {
            bench.environment.clonesArchives = clones
            try write("x", to: bench.inside(odd, "new\(clones).txt"))
            try bench.store.flush(odd)
            #expect(listed(odd).contains("/") && listed(odd).contains("new\(clones).txt"))
        }
    }

    @Test func packingIntoAnExistingArchiveAddsToItAndTestsOnlyWhatIsNew() throws {
        let archive = try makeZip()
        let original = try Data(contentsOf: archive)
        let directory = try ZipDirectory.read(RandomAccessFile(archive)).directoryOffset
        // An old member is damaged where its data lies; the test after packing does not read it.
        var damaged = original
        let file = try RandomAccessFile(archive)
        let random = try #require(ZipDirectory.read(file).records.first { $0.name == "tree/sub/random.bin" })
        guard case .archive(let offset, _) = random.source else { return }
        damaged[Int(try ZipDirectory.localHeader(of: random, at: offset, in: file).dataOffset) + 1_000] ^= 0xFF
        try damaged.write(to: archive)
        try box.file("extra/one.txt", "one")
        try box.file("extra/two.txt", String(repeating: "two", count: 500_000))
        try bench.pack([box.url("extra")], to: archive, innerFolder: "tree") { $0.verifies = true }
        let now = try Data(contentsOf: archive)
        #expect(now.prefix(Int(directory)) == damaged.prefix(Int(directory)))
        #expect(Set(listed(archive)).isSuperset(of: ["tree/extra/one.txt", "tree/extra/two.txt", "tree/readme.txt"]))
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/extra/two.txt"]).output.count == 1_500_000)
        // The whole test still finds the damage.
        #expect(try !ArchiveTester.test(bench.store.archive(at: archive), cancellation: CancellationFlag()).isEmpty)
        // Replacing a member writes the archive anew.
        try original.write(to: archive)
        try box.file("tree/readme.txt", "shorter")
        try bench.pack([box.url("tree/readme.txt")], to: archive, innerFolder: "tree") { $0.verifies = true }
        #expect(
            isSound(archive) && runTool("/usr/bin/unzip", ["-p", archive.path, "tree/readme.txt"]).output == "shorter"
        )
        #expect(listed(archive).filter { $0 == "tree/readme.txt" }.count == 1)
    }

    @Test func aMemberWrittenThroughTheFileSystemIsCompressedInPieces() throws {
        let archive = try makeZip()
        // Larger than one window of pieces on any machine, with a tail that is no whole piece.
        var data = Data()
        var line = 0
        while data.count < (ProcessInfo.processInfo.activeProcessorCount + 3) * (1 << 20) + 12_345 {
            data.append(Data("line \(line) of a long file that is written through the file system\n".utf8))
            line += 1
        }
        let member = bench.inside(archive, "tree/long.txt")
        let writer = try bench.zip.write(member)
        var offset = 0
        while offset < data.count {
            let end = min(offset + 300_000, data.count)
            try writer.write(data.subdata(in: offset..<end))
            offset = end
        }
        try writer.close(attributes: FileAttributes())
        #expect(try bench.read(member) == data)
        try bench.store.flush(archive)
        #expect(isSound(archive))
        try box.folder("long")
        #expect(
            runTool("/usr/bin/unzip", ["-q", archive.path, "tree/long.txt", "-d", box.url("long").path]).status == 0
        )
        #expect(try Data(contentsOf: box.url("long/tree/long.txt")) == data)
        let entry = try #require(try bench.store.archive(at: archive).entry("tree/long.txt"))
        #expect(entry.size == Int64(data.count) && entry.packedSize < entry.size / 3)
        // A size that is exactly a number of windows ends in an empty last piece.
        let exact = bench.inside(archive, "tree/exact.bin")
        let window = Data(repeating: 65, count: max(2, ProcessInfo.processInfo.activeProcessorCount) << 20)
        let second = try bench.zip.write(exact)
        try second.write(window)
        try second.close(attributes: FileAttributes())
        try bench.store.flush(archive)
        #expect(try isSound(archive) && bench.read(exact) == window)
    }

    // MARK: A7 – sizes without unpacking, one pass for many members

    @Test func theSizeOfACompressedFileIsReadFromItsEnd() throws {
        let tree = try bench.makeTree()
        let source = tree.appendingPathComponent("big.log")
        let size = try Data(contentsOf: source).count
        bench.environment.materializeLimit = 0
        for codec in [ArchiveFormat.Codec.gzip, .xz, .bzip2] {
            let archive = box.url("big.log." + ArchiveFormat.suffix(codec))
            try bench.pack([source], to: archive) { $0.format = .compressedFile(codec) }
            let opened = try bench.store.archive(at: archive)
            let entry = try #require(opened.entries.first)
            #expect(entry.size == Int64(size) && entry.sizeIsExact == (codec != .gzip), "\(codec)")
            #expect(ArchiveTester.test(opened, cancellation: CancellationFlag()).isEmpty)
        }
        // Several streams in a row with padding between them, as parallel compressors write.
        let parts = [Data(repeating: 1, count: 70_000), Data(), Data(repeating: 2, count: 300)]
        var joined = Data()
        for part in parts {
            joined.append(try XZCoder.compress(part))
            joined.append(Data(count: 8))
        }
        try joined.write(to: box.url("joined.xz"))
        #expect(try CompressedSize.ofXZ(RandomAccessFile(box.url("joined.xz"))) == 70_300)
        let stream = try XZStream(FileRangeStream(RandomAccessFile(box.url("joined.xz"))))
        #expect(try stream.readFully(1 << 20) == parts.reduce(Data(), +))
        // Anything that is not an index is "unknown", whatever it claims.
        for cut in [1, 5, 13, 40] {
            try joined.dropLast(cut).write(to: box.url("cut.xz"))
            #expect(try CompressedSize.ofXZ(RandomAccessFile(box.url("cut.xz"))) == nil)
        }
        var forged = joined
        forged.replaceSubrange(forged.count - 16..<forged.count - 12, with: [0xFF, 0xFF, 0xFF, 0x7F])
        try forged.write(to: box.url("forged.xz"))
        #expect(try CompressedSize.ofXZ(RandomAccessFile(box.url("forged.xz"))) == nil)
        // What a file says that is too small to be true is raised by the steps it lost.
        let gz = box.url("big.log.gz")
        var bytes = try Data(contentsOf: gz)
        #expect(try CompressedSize.claimedByGzip(RandomAccessFile(gz)) == UInt64(size))
        bytes.replaceSubrange(bytes.count - 4..<bytes.count, with: [5, 0, 0, 0])
        try bytes.write(to: gz)
        #expect(try CompressedSize.claimedByGzip(RandomAccessFile(gz)) == 5 + 1 << 32)
    }

    @Test func membersOfAStreamReadOneAfterTheOtherCostOnePass() throws {
        let tree = try bench.makeTree()
        let archive = box.url("tree.tar.gz")
        try bench.pack([tree], to: archive) { $0.format = .compressedTar(.gzip) }
        bench.environment.materializeLimit = 0
        let opened = try bench.store.archive(at: archive)
        let files = opened.entries.filter { !$0.isDirectory }
        #expect(files.count == 6 && opened.streamStarts == 0)
        // In archive order, as a copy job reads them.
        for entry in files {
            let stream = try opened.open(entry)
            let data = try stream.readFully(1 << 24)
            stream.close()
            #expect(data == (try Data(contentsOf: box.url(entry.path))), "\(entry.path)")
        }
        #expect(opened.streamStarts == 1)
        // A member that lies behind the reader starts a new pass; one left half read does not hurt.
        let half = try opened.open(files[2])
        _ = try half.read(upToCount: 10)
        half.close()
        #expect(try opened.open(files[4]).readFully(1 << 24) == Data(contentsOf: box.url(files[4].path)))
        #expect(opened.streamStarts == 2)
        // The copy job gets every file right this way.
        try box.folder("out")
        let root = bench.inside(archive, "tree", scheme: ArchiveURL.readOnlyScheme)
        let result = runJob(.copy, [root], to: TargetSpec(directory: box.url("out")), fileSystems: bench.fileSystems)
        #expect(result.completed.count == 1 && snapshot(box.url("out/tree")) == snapshot(tree))
    }

    @Test func aMemberThatLiesInAFileIsReadAtAnyPlace() throws {
        let tree = try bench.makeTree()
        let archive = box.url("tree.tar")
        try bench.pack([tree], to: archive) { $0.format = .tar }
        let expected = try Data(contentsOf: tree.appendingPathComponent("big.log"))
        let reader = try bench.readOnly.read(bench.inside(archive, "tree/big.log", scheme: ArchiveURL.readOnlyScheme))
        for offset in [5_000_000, 44, 0, expected.count - 3, expected.count + 10, 1_000_000] {
            try reader.seek(to: UInt64(offset))
            let wanted =
                offset < expected.count ? expected.subdata(in: offset..<min(offset + 100, expected.count)) : nil
            #expect(try reader.read(upToCount: 100) == wanted, "\(offset)")
        }
        reader.close()
    }

    // MARK: A8 – what comes out of an archive

    @Test func unpackedFilesCarryTheArchivesQuarantine() throws {
        let archive = try makeZip()
        let mark = "0083;65f0a1b2;Safari;F643CD5F-6071-46AB-83AB-390BA944DEC5"
        #expect(mark.withCString { setxattr(archive.path, "com.apple.quarantine", $0, strlen($0), 0, 0) } == 0)
        let result = try bench.unpack(archive, to: box.url("out"))
        #expect(result.problems.isEmpty)
        for path in ["out/tree/readme.txt", "out/tree/sub/random.bin", "out/tree/hollow", "out/tree/empty.txt"] {
            #expect(quarantine(of: box.url(path)) == mark, "\(path)")
        }
        // Changing the archive keeps its mark, and so does an archive inside it.
        try write("new", to: bench.inside(archive, "tree/new.txt"))
        try bench.zip.remove(bench.inside(archive, "tree/empty.txt"))
        try bench.store.flush(archive)
        #expect(quarantine(of: archive) == mark)
        try bench.pack([box.url("tree")], to: box.url("inner.tar")) { $0.format = .tar }
        try bench.pack([box.url("inner.tar")], to: box.url("outer.zip"))
        #expect(
            mark.withCString { setxattr(box.url("outer.zip").path, "com.apple.quarantine", $0, strlen($0), 0, 0) } == 0
        )
        let inner = bench.inside(box.url("outer.zip"), "inner.tar")
        let nested = try bench.unpack(inner, to: box.url("nested"))
        #expect(nested.problems.isEmpty && quarantine(of: box.url("nested/tree/readme.txt")) == mark)
        // An archive without the mark gives none.
        _ = try bench.unpack(try makeZip("clean.zip"), to: box.url("clean"))
        #expect(quarantine(of: box.url("clean/tree/readme.txt")) == nil)
    }

    @Test func unpackedProgramsDoNotRunAsTheirOwner() throws {
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
        try bench.store.flush(box.url("tools.zip"))
        #expect(runTool("/usr/bin/unzip", ["-Z", box.url("tools.zip").path]).output.contains("-rwsr-xr-x"))
    }

    @Test func aMemberThatUnpacksToMoreThanItSaysIsStopped() throws {
        let contents = Data(repeating: 0, count: 50 << 20)
        let packed = try Deflater.piece(contents, level: 6, final: true)
        let archive = box.url("bomb.zip")
        let output = try OutputFile(creating: archive)
        let writer = ZipWriter(output)
        var record = ZipRecord.new(name: "small.txt", isDirectory: false, modified: Date(), permissions: 0o644)
        record.method = ZipRecord.methodDeflate
        record.crc = CRC32.of(contents)
        (record.compressedSize, record.uncompressedSize) = (UInt64(packed.count), 1_000)
        let member = try writer.begin(record)
        try writer.append(packed)
        try writer.end(member, record)
        try writer.finish()
        try output.close()
        let opened = try bench.store.archive(at: archive)
        let stream = try opened.open(try #require(opened.entry("small.txt")))
        var read = 0
        #expect(throws: ArchiveError.self) {
            while let block = try stream.read(upToCount: 1 << 16) { read += block.count }
        }
        #expect(read <= 1_000)
        let result = try bench.unpack(archive, to: box.url("out"))
        #expect(result.unpacked == 0 && result.problems.count == 1 && namesOnDisk(box.url("out")).isEmpty)
    }

    // MARK: A9 – the same results, faster

    @Test func theTreeKeepsItsOrderAndItsFolders() {
        var tree = ArchiveTree()
        let paths = ["a/b/c/one.txt", "a/b/c/two.txt", "a/b/three.txt", "x.txt", "a/b/c/d/e/four.txt", "a/z.txt"]
        for path in paths { tree.insert(ArchiveEntry(path: path, isDirectory: false)) }
        #expect(tree.ordered.filter { !$0.isDirectory }.map(\.path) == paths)
        #expect(Set(tree.ordered.filter(\.isImplicit).map(\.path)) == ["a", "a/b", "a/b/c", "a/b/c/d", "a/b/c/d/e"])
        #expect(
            tree.children(of: "a/b")?.map(\.name).sorted() == ["c", "three.txt"]
                && tree.children(of: "")?.map(\.name).sorted() == ["a", "x.txt"]
        )
        // The remembered order follows every change.
        tree.remove("a/b/c/two.txt")
        tree.insert(ArchiveEntry(path: "a/b/c/five.txt", isDirectory: false))
        tree.update("x.txt") { $0.size = 7 }
        #expect(
            tree.ordered.filter { !$0.isDirectory }.map(\.path) == [
                "a/b/c/one.txt", "a/b/three.txt", "x.txt", "a/b/c/d/e/four.txt", "a/z.txt", "a/b/c/five.txt"
            ]
        )
        #expect(tree.ordered.first { $0.path == "x.txt" }?.size == 7)
        // A folder that was taken out is made up again with the next thing inside it.
        for path in ["a/b/c/d/e/four.txt", "a/b/c/d/e", "a/b/c/d"] { tree.remove(path) }
        tree.insert(ArchiveEntry(path: "a/b/c/d/e/six.txt", isDirectory: false))
        #expect(tree.isDirectory("a/b/c/d") && tree.children(of: "a/b/c/d/e")?.map(\.name) == ["six.txt"])
        #expect(tree.children(of: "a/b/c")?.map(\.name).sorted() == ["d", "five.txt", "one.txt"])
    }

    @Test func encryptionWorksInPlaceAndBothWays() {
        var data = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let plain = data
        var (encrypting, decrypting) = (ZipCrypto(password: "pässword"), ZipCrypto(password: "pässword"))
        // A block that does not start at index zero, as blocks cut from larger ones do.
        var slice = data.dropFirst(10)
        encrypting.encrypt(&slice)
        #expect(slice != plain.dropFirst(10) && slice.count == plain.count - 10)
        var first = Data(slice.prefix(777))
        var rest = Data(slice.dropFirst(777))
        decrypting.decrypt(&first)
        decrypting.decrypt(&rest)
        #expect(first + rest == plain.dropFirst(10))
        data = plain
        var again = ZipCrypto(password: "pässword")
        #expect(again.encrypt(data.dropFirst(10)) == slice)
    }

    // MARK: A10 – TAR

    @Test func hardLinksAreFilesOfTheirOwnWhereverTheirTargetStands() throws {
        // A link to a member that comes later, a link to a link, and a link to nothing.
        var data = tarBlock(name: "early-link", type: 49, link: "dir/real.txt")
        data.append(tarBlock(name: "second-link", type: 49, link: "early-link"))
        data.append(tarBlock(name: "dir/real.txt", size: 9))
        data.append(tarData("the bytes"))
        data.append(tarBlock(name: "late-link", type: 49, link: "dir/real.txt"))
        data.append(tarBlock(name: "broken-link", type: 49, link: "nowhere"))
        data.append(TarHeader.endOfArchive)
        try data.write(to: box.url("links.tar"))
        #expect(runTool("/usr/bin/gzip", ["-k", "links.tar"], in: box.root).status == 0)
        for (name, limit) in [("links.tar", UInt64(1 << 20)), ("links.tar.gz", 1 << 20), ("links.tar.gz", 0)] {
            bench.store.close()
            bench.environment.materializeLimit = limit
            let root = bench.inside(box.url(name), scheme: ArchiveURL.readOnlyScheme)
            for link in ["early-link", "second-link", "late-link", "dir/real.txt"] {
                #expect(
                    try bench.item(bench.inside(box.url(name), link, scheme: ArchiveURL.readOnlyScheme)).size == 9,
                    "\(name) \(link)"
                )
            }
            #expect(try bench.read(root.appending(name: "second-link")) == Data("the bytes".utf8))
            // Unpacked in one pass, every name gets the contents.
            let target = box.url("out-\(name)-\(limit)")
            let result = try bench.unpack(box.url(name), to: target)
            #expect(result.problems.isEmpty, "\(result.problems)")
            let unpacked = snapshot(target)
            for link in ["early-link", "second-link", "late-link", "dir/real.txt"] {
                #expect(unpacked[link] == Data("the bytes".utf8), "\(name) \(link)")
            }
            #expect(unpacked["broken-link"] == Data())
        }
    }

    @Test func oldGnuHeadersHaveNoPathPrefix() throws {
        // GNU tar's old format keeps times where POSIX has the prefix of a long path.
        var data = tarBlock(name: "gnu.txt", size: 3, magic: Array("ustar  \u{0}".utf8)) { block in
            for (index, byte) in "14000000000\u{0}14000000001\u{0}".utf8.enumerated() { block[345 + index] = byte }
        }
        data.append(tarData("gnu"))
        data.append(
            tarBlock(name: "posix.txt", size: 5) { block in
                for (index, byte) in "some/long/prefix".utf8.enumerated() { block[345 + index] = byte }
            }
        )
        data.append(tarData("posix"))
        data.append(TarHeader.endOfArchive)
        try data.write(to: box.url("gnu.tar"))
        let root = bench.inside(box.url("gnu.tar"), scheme: ArchiveURL.readOnlyScheme)
        #expect(try bench.names(root) == ["gnu.txt", "some"])
        #expect(try bench.read(root.appending(name: "gnu.txt")) == Data("gnu".utf8))
        #expect(
            try bench.read(
                bench.inside(box.url("gnu.tar"), "some/long/prefix/posix.txt", scheme: ArchiveURL.readOnlyScheme)
            )
                == Data("posix".utf8)
        )
    }

    @Test func sparseFilesAreShownAndRefused() throws {
        // The old GNU form: type S, the real size in the header, the list of pieces going on
        // in a block of its own.
        var data = tarBlock(name: "holes.img", type: 83, size: 512, magic: Array("ustar  \u{0}".utf8)) { block in
            for (index, byte) in "00004000000\u{0}".utf8.enumerated() { block[483 + index] = byte }
            block[482] = 1
        }
        data.append(Data(count: 512))
        data.append(Data(repeating: 65, count: 512))
        data.append(tarBlock(name: "after.txt", size: 5))
        data.append(tarData("after"))
        // The pax form: the name and the size in records of their own.
        let records = [
            "22 GNU.sparse.major=1\n", "22 GNU.sparse.minor=0\n", "29 GNU.sparse.name=pax-holes\n",
            "29 GNU.sparse.realsize=70000\n"
        ]
        #expect(records.map(\.utf8.count) == [22, 22, 29, 29])
        data.append(tarBlock(name: "PaxHeader/x", type: 120, size: UInt64(records.joined().utf8.count)))
        data.append(tarData(records.joined()))
        data.append(tarBlock(name: "GNUSparseFile.0/pax-holes", size: 1_024))
        data.append(Data(repeating: 66, count: 1_024))
        data.append(tarBlock(name: "last.txt", size: 4))
        data.append(tarData("last"))
        data.append(TarHeader.endOfArchive)
        try data.write(to: box.url("sparse.tar"))
        let archive = box.url("sparse.tar")
        func inner(_ path: String) -> URL { bench.inside(archive, path, scheme: ArchiveURL.readOnlyScheme) }
        #expect(try bench.names(inner("")) == ["after.txt", "holes.img", "last.txt", "pax-holes"])
        #expect(try bench.item(inner("holes.img")).size == 1 << 20 && bench.item(inner("pax-holes")).size == 70_000)
        #expect(
            try bench.read(inner("after.txt")) == Data("after".utf8)
                && bench.read(inner("last.txt")) == Data("last".utf8)
        )
        for name in ["holes.img", "pax-holes"] {
            #expect(throws: ArchiveError.self) { try bench.read(inner(name)) }
        }
        let result = try bench.unpack(archive, to: box.url("out"))
        #expect(
            result.unpacked == 2 && result.problems.count == 2
                && namesOnDisk(box.url("out")) == ["after.txt", "last.txt"]
        )
    }

    // MARK: A11

    @Test func filesThatWouldShareANameAreNotPackedOverEachOther() throws {
        try box.file("src/a/same.txt", "first")
        try box.file("src/b/same.txt", "second")
        for format in [ArchiveFormat.zip, .tar] {
            let archive = box.url("flat." + format.defaultExtension)
            #expect(throws: ArchiveError.self) {
                try bench.pack([box.url("src")], to: archive) {
                    ($0.format, $0.storesPaths, $0.movesSources) = (format, false, true)
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

    @Test func aWrongPasswordThatPassesTheCheckByteIsNotKept() throws {
        let tree = try bench.makeTree()
        let archive = box.url("secret.zip")
        try bench.pack([tree.appendingPathComponent("readme.txt")], to: archive) {
            $0.password = "right"
            $0.encryption = .legacy
        }
        bench.store.close()
        // One wrong password in 256 gets past the first twelve bytes.
        let record = try #require(ZipDirectory.read(RandomAccessFile(archive)).records.first)
        guard case .archive(let offset, let file) = record.source else { return }
        let start = try ZipDirectory.localHeader(of: record, at: offset, in: file).dataOffset
        let wrong = try #require(
            (0..<100_000).lazy.map { "wrong\($0)" }
                .first { candidate in
                    (try? ZipDecryptStream(
                        FileRangeStream(file, offset: start, length: 12),
                        password: candidate,
                        check: UInt8(record.dosTime >> 8),
                        name: ""
                    )) != nil
                }
        )
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
