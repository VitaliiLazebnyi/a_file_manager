import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import ArchivesPlugin

/// A monitor for packing and unpacking outside a job service.
final class QuietMonitor: JobMonitor {
    let cancellation = CancellationFlag()
    private let lock = NSLock()
    private var all: [JobProgress] = []

    var reports: [JobProgress] {
        lock.lock()
        defer { lock.unlock() }
        return all
    }

    func report(_ progress: JobProgress) {
        lock.lock()
        all.append(progress)
        lock.unlock()
    }

    func ask<Answer>(_ question: () -> Answer) -> Answer { question() }
}

/// The archive file systems on top of the local disk and a memory file system, without a kernel.
final class ArchiveBench {
    let box: Sandbox
    let environment = ArchiveEnvironment()
    let store: ArchiveStore
    let fileSystems = FileSystemRegistry()
    let memory = MemoryFileSystem()
    let zip: ArchiveFileSystem
    let readOnly: ArchiveFileSystem
    let monitor = QuietMonitor()
    let passwords = Passwords()

    /// The answers to password questions, and how often one was asked.
    final class Passwords {
        private let lock = NSLock()
        private var answers: [String?] = []
        private var count = 0

        func set(_ answers: [String?]) {
            lock.lock()
            self.answers = answers
            lock.unlock()
        }

        var asked: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func next() -> String? {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    init() throws {
        box = try Sandbox()
        environment.flushDelay = nil
        store = ArchiveStore(environment: environment)
        zip = ArchiveFileSystem(scheme: ArchiveURL.writableScheme, store: store)
        readOnly = ArchiveFileSystem(scheme: ArchiveURL.readOnlyScheme, store: store)
        [LocalFileSystem(), memory, zip, readOnly].forEach(fileSystems.register)
        environment.fileSystems = { [weak fileSystems] in fileSystems }
        environment.askPassword = { [passwords] _, _ in passwords.next() }
    }

    deinit { store.close() }

    /// A small tree with text, binary data, an empty file, an empty folder and odd names.
    @discardableResult
    func makeTree(_ name: String = "tree") throws -> URL {
        try box.file(
            "\(name)/readme.txt", String(repeating: "All work and no play makes Jack a dull boy.\n", count: 400))
        try box.file("\(name)/empty.txt", "")
        try box.file("\(name)/sub/deep/übung – ñ 日本.txt", "unicode name")
        try box.file("\(name)/sub/.hidden", "hidden")
        try box.folder("\(name)/hollow")
        var random = Data(count: 300_000)
        random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try random.write(to: box.url("\(name)/sub/random.bin"))
        // Larger than one piece of the parallel compressor, and compressible.
        var big = Data()
        for index in 0..<120_000 { big.append(Data("line \(index) of a file that spans several pieces\n".utf8)) }
        try big.write(to: box.url("\(name)/big.log"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: box.url("\(name)/readme.txt").path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
            ofItemAtPath: box.url("\(name)/readme.txt").path)
        return box.url(name)
    }

    func item(_ url: URL) throws -> FileItem {
        try #require(fileSystems.item(at: url))
    }

    @discardableResult
    func pack(
        _ sources: [URL], to archive: URL, innerFolder: String = "",
        _ configure: (inout PackOptions) -> Void = { _ in }
    ) throws -> PackResult {
        var options = PackOptions()
        options.limits = environment.limits
        configure(&options)
        let packer = Packer(fileSystems: fileSystems, store: store, monitor: monitor, options: options)
        let result = packer.run(try sources.map(item), archive: archive, innerFolder: innerFolder)
        if let failure = result.failure { throw failure }
        return result
    }

    @discardableResult
    func unpack(_ archive: URL, to target: URL, _ configure: (inout UnpackOptions) -> Void = { _ in }) throws
        -> UnpackResult
    {
        var options = UnpackOptions()
        configure(&options)
        let unpacker = Unpacker(fileSystems: fileSystems, monitor: monitor, options: options) { _, _ in .overwrite }
        return unpacker.run([Unpacker.Source(archive: try store.archive(at: archive))], into: target)
    }

    /// The location of a path inside an archive file.
    func inside(_ archive: URL, _ path: String = "", scheme: String = ArchiveURL.writableScheme) -> URL {
        ArchiveURL.make(scheme: scheme, archive: archive, innerPath: path)
    }

    func read(_ url: URL) throws -> Data {
        let reader = try fileSystems.provider(for: url).read(url)
        defer { reader.close() }
        var data = Data()
        while let block = try reader.read(upToCount: 70_000) { data.append(block) }
        return data
    }

    func names(_ url: URL, showHidden: Bool = true) throws -> [String] {
        try fileSystems.provider(for: url).list(url, showHidden: showHidden).map(\.name).sorted()
    }
}

/// Runs a program of the system and returns its exit status and output.
@discardableResult
func runTool(_ path: String, _ arguments: [String], in directory: URL? = nil) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return (-1, "\(error)") }
    let output = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output, as: UTF8.self))
}

/// Every regular file below a folder with its contents, by relative path; empty folders as nil.
func snapshot(_ folder: URL) -> [String: Data?] {
    var found: [String: Data?] = [:]
    let base = folder.resolvingSymlinksInPath().path
    guard let walker = FileManager.default.enumerator(atPath: base) else { return found }
    for case let path as String in walker {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: base + "/" + path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            if ((try? FileManager.default.contentsOfDirectory(atPath: base + "/" + path)) ?? []).isEmpty {
                found[path.precomposedStringWithCanonicalMapping] = .some(nil)
            }
        } else {
            found[path.precomposedStringWithCanonicalMapping] = FileManager.default.contents(atPath: base + "/" + path)
        }
    }
    return found
}

@Suite struct ArchiveFormats {
    let bench: ArchiveBench
    var box: Sandbox { bench.box }

    init() throws {
        bench = try ArchiveBench()
    }

    // MARK: Round trips

    @Test(arguments: [ArchiveFormat.zip, .tar, .compressedTar(.gzip), .compressedTar(.bzip2), .compressedTar(.xz)])
    func packListUnpackGivesTheSameBytes(format: ArchiveFormat) throws {
        let tree = try bench.makeTree()
        let archive = box.url("out/tree." + format.defaultExtension)
        let result = try bench.pack([tree], to: archive) { $0.format = format }
        #expect(result.archives == [archive] && result.completed == [tree])
        // No temporary file stays next to the archive.
        #expect(namesOnDisk(box.url("out")) == [archive.lastPathComponent])

        let opened = try bench.store.archive(at: archive)
        #expect(opened.format == format)
        let root = bench.inside(
            archive, scheme: format == .zip ? ArchiveURL.writableScheme : ArchiveURL.readOnlyScheme)
        #expect(try bench.names(root) == ["tree"])
        #expect(
            try bench.names(root.appending(name: "tree")) == ["big.log", "empty.txt", "hollow", "readme.txt", "sub"])
        #expect(
            try bench.names(root.appending(name: "tree").appending(name: "sub"), showHidden: false) == [
                "deep", "random.bin"
            ])
        let readme = try bench.item(root.appending(name: "tree").appending(name: "readme.txt"))
        #expect(
            readme.size == 17_600 && readme.permissions == 0o755
                && readme.modified == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(
            try bench.read(readme.url)
                == FileManager.default.contents(atPath: tree.appendingPathComponent("readme.txt").path))

        let unpacked = try bench.unpack(archive, to: box.url("back"))
        #expect(unpacked.problems.isEmpty && !unpacked.cancelled)
        let (original, copy) = (snapshot(tree), snapshot(box.url("back/tree")))
        #expect(original.count == 7 && original == copy)
        let attributes = try FileManager.default.attributesOfItem(atPath: box.url("back/tree/readme.txt").path)
        #expect(attributes[.posixPermissions] as? Int == 0o755)
        #expect(attributes[.modificationDate] as? Date == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(ArchiveTester.test(opened, cancellation: CancellationFlag()).isEmpty)
    }

    @Test(arguments: [ArchiveFormat.Codec.gzip, .bzip2, .xz])
    func singleCompressedFilesRoundTrip(codec: ArchiveFormat.Codec) throws {
        let tree = try bench.makeTree()
        let source = tree.appendingPathComponent("big.log")
        let format = ArchiveFormat.compressedFile(codec)
        let archive = box.url("big.log." + format.defaultExtension)
        try bench.pack([source], to: archive) { $0.format = format }
        let original = try Data(contentsOf: source)
        #expect(try Data(contentsOf: archive).count < original.count / 4)

        // It is shown as a folder holding the one file, at its unpacked size.
        let root = bench.inside(archive, scheme: ArchiveURL.readOnlyScheme)
        let items = try bench.readOnly.list(root, showHidden: true)
        #expect(items.map(\.name) == ["big.log"] && items.first?.size == Int64(original.count))
        #expect(try bench.read(root.appending(name: "big.log")) == original)
        try bench.unpack(archive, to: box.url("back"))
        #expect(try Data(contentsOf: box.url("back/big.log")) == original)

        // A folder does not fit into such a file.
        #expect(throws: ArchiveError.self) {
            try bench.pack([tree], to: box.url("tree." + format.defaultExtension)) { $0.format = format }
        }
        #expect(!box.exists("tree." + format.defaultExtension))
    }

    @Test func aLargeArchiveIsStreamedInsteadOfUnpackedToATemporaryFile() throws {
        let tree = try bench.makeTree()
        let archive = box.url("tree.tar.gz")
        try bench.pack([tree], to: archive) { $0.format = .compressedTar(.gzip) }
        // Nothing may be kept in a temporary copy: every read decompresses from the start.
        bench.environment.materializeLimit = 0
        let opened = try bench.store.archive(at: archive)
        #expect(!opened.allowsParallelReads)
        let root = bench.inside(archive, "tree", scheme: ArchiveURL.readOnlyScheme)
        #expect(
            try bench.read(root.appending(name: "big.log")) == Data(contentsOf: tree.appendingPathComponent("big.log")))
        let reader = try bench.readOnly.read(root.appending(name: "readme.txt"))
        try reader.seek(to: 44)
        #expect(try reader.read(upToCount: 8).map { String(decoding: $0, as: UTF8.self) } == "All work")
        try reader.seek(to: 4)
        #expect(try reader.read(upToCount: 4).map { String(decoding: $0, as: UTF8.self) } == "work")
        reader.close()
        // Unpacking takes one pass, and so does the test.
        let unpacked = try bench.unpack(archive, to: box.url("back"))
        #expect(unpacked.problems.isEmpty && snapshot(box.url("back/tree")) == snapshot(tree))
        #expect(ArchiveTester.test(opened, cancellation: CancellationFlag()).isEmpty)

        let single = box.url("big.log.gz")
        try bench.pack([tree.appendingPathComponent("big.log")], to: single) { $0.format = .compressedFile(.gzip) }
        let item = try bench.item(bench.inside(single, "big.log", scheme: ArchiveURL.readOnlyScheme))
        #expect(item.size == Int64(try Data(contentsOf: tree.appendingPathComponent("big.log")).count))
        #expect(try bench.read(item.url) == Data(contentsOf: tree.appendingPathComponent("big.log")))
    }

    // MARK: The system's tools

    @Test func systemToolsReadWhatIsWritten() throws {
        let tree = try bench.makeTree()
        let expected = snapshot(tree)

        let zip = box.url("tree.zip")
        try bench.pack([tree], to: zip)
        #expect(runTool("/usr/bin/unzip", ["-tq", zip.path]).status == 0)
        try box.folder("unzipped")
        #expect(runTool("/usr/bin/unzip", ["-q", zip.path, "-d", box.url("unzipped").path]).status == 0)
        #expect(snapshot(box.url("unzipped/tree")) == expected)
        let mode =
            try FileManager.default.attributesOfItem(atPath: box.url("unzipped/tree/readme.txt").path)[
                .posixPermissions] as? Int
        #expect(mode == 0o755)

        for format in [ArchiveFormat.tar, .compressedTar(.gzip), .compressedTar(.bzip2), .compressedTar(.xz)] {
            let archive = box.url("tree." + format.defaultExtension)
            try bench.pack([tree], to: archive) { $0.format = format }
            let folder = try box.folder("untar-" + format.defaultExtension)
            let run = runTool("/usr/bin/tar", ["-xf", archive.path, "-C", folder.path])
            #expect(run.status == 0, "\(format.title): \(run.output)")
            #expect(snapshot(folder.appendingPathComponent("tree")) == expected, "\(format.title)")
        }

        let big = tree.appendingPathComponent("big.log")
        try bench.pack([big], to: box.url("big.log.gz")) { $0.format = .compressedFile(.gzip) }
        try bench.pack([big], to: box.url("big.log.bz2")) { $0.format = .compressedFile(.bzip2) }
        #expect(runTool("/usr/bin/gzip", ["-t", box.url("big.log.gz").path]).status == 0)
        #expect(runTool("/usr/bin/bzip2", ["-t", box.url("big.log.bz2").path]).status == 0)
        try FileManager.default.copyItem(at: box.url("big.log.gz"), to: box.url("copy.log.gz"))
        #expect(runTool("/usr/bin/gzip", ["-d", box.url("copy.log.gz").path]).status == 0)
        #expect(try Data(contentsOf: box.url("copy.log")) == Data(contentsOf: big))
    }

    @Test func archivesOfTheSystemToolsAreRead() throws {
        let tree = try bench.makeTree()
        try FileManager.default.createSymbolicLink(
            atPath: tree.appendingPathComponent("link").path, withDestinationPath: "readme.txt")
        let longName = String(repeating: "long-name-", count: 14) + ".txt"
        try box.file("tree/\(longName)", "long")
        var expected = snapshot(tree)
        expected["link"] = nil

        func check(_ archive: URL, _ format: ArchiveFormat, sourceLocation: Testing.SourceLocation = #_sourceLocation)
            throws
        {
            let opened = try bench.store.archive(at: archive)
            #expect(opened.format == format, sourceLocation: sourceLocation)
            let folder = try box.folder("out-" + archive.lastPathComponent)
            let result = try bench.unpack(archive, to: folder)
            #expect(result.problems.isEmpty, "\(result.problems)", sourceLocation: sourceLocation)
            var unpacked = snapshot(folder.appendingPathComponent("tree"))
            unpacked["link"] = nil
            #expect(unpacked == expected, "\(archive.lastPathComponent)", sourceLocation: sourceLocation)
            // Formats that keep links hand them back as links.
            if format != .foreign || archive.pathExtension == "cpio" {
                #expect(
                    (try? FileManager.default.destinationOfSymbolicLink(
                        atPath: folder.appendingPathComponent("tree/link").path)) == "readme.txt",
                    "\(archive.lastPathComponent)", sourceLocation: sourceLocation)
            }
            #expect(
                ArchiveTester.test(opened, cancellation: CancellationFlag()).isEmpty, sourceLocation: sourceLocation)
        }

        #expect(runTool("/usr/bin/zip", ["-qry", "sys.zip", "tree"], in: box.root).status == 0)
        try check(box.url("sys.zip"), .zip)
        for (name, flags, format) in [
            ("sys.tar", "-cf", ArchiveFormat.tar), ("sys.tgz", "-czf", .compressedTar(.gzip)),
            ("sys.tar.bz2", "-cjf", .compressedTar(.bzip2)), ("sys.tar.xz", "-cJf", .compressedTar(.xz))
        ] {
            #expect(runTool("/usr/bin/tar", [flags, name, "tree"], in: box.root).status == 0)
            try check(box.url(name), format)
        }
        // What only libarchive reads: 7z and cpio stand for the family.
        #expect(runTool("/usr/bin/bsdtar", ["-cf", "sys.7z", "--format", "7zip", "tree"], in: box.root).status == 0)
        try check(box.url("sys.7z"), .foreign)
        #expect(runTool("/usr/bin/bsdtar", ["-cf", "sys.cpio", "--format", "cpio", "tree"], in: box.root).status == 0)
        try check(box.url("sys.cpio"), .foreign)
        let listing = try bench.names(bench.inside(box.url("sys.7z"), "tree/sub", scheme: ArchiveURL.readOnlyScheme))
        #expect(listing == [".hidden", "deep", "random.bin"])

        // GZIP: a single file, also in several members as parallel compressors write it.
        try box.file("one.txt", "first ")
        try box.file("two.txt", "second")
        #expect(runTool("/usr/bin/gzip", ["-k", "one.txt", "two.txt"], in: box.root).status == 0)
        try (Data(contentsOf: box.url("one.txt.gz")) + Data(contentsOf: box.url("two.txt.gz"))).write(
            to: box.url("both.gz"))
        #expect(
            try bench.read(bench.inside(box.url("both.gz"), "one.txt", scheme: ArchiveURL.readOnlyScheme))
                == Data("first second".utf8))
        #expect(runTool("/usr/bin/bzip2", ["-k", "one.txt"], in: box.root).status == 0)
        #expect(
            try bench.read(bench.inside(box.url("one.txt.bz2"), "one.txt", scheme: ArchiveURL.readOnlyScheme))
                == Data("first ".utf8))

        // A file that is no archive says so.
        #expect(throws: ArchiveError.self) { try bench.store.archive(at: box.url("one.txt")) }
        #expect(bench.fileSystems.item(at: bench.inside(box.url("one.txt"), "x")) == nil)
    }

    // MARK: ZIP details

    @Test func zip64IsUsedExactlyWhereTheClassicFieldsEnd() throws {
        // The rule itself, at the real limits.
        let limits = ZipLimits.standard
        #expect(limits.maxField == 0xFFFF_FFFE && limits.maxEntries == 0xFFFE)

        func write(_ sizes: [Int], limits: ZipLimits) throws -> (url: URL, zip64: Bool) {
            let url = box.url("z-\(UUID().uuidString).zip")
            let output = try OutputFile(creating: url)
            let packer = ZipPacker(output, level: 6, limits: limits)
            for (index, size) in sizes.enumerated() {
                var sent = false
                let record = ZipRecord.new(
                    name: "file\(index).txt", isDirectory: false, modified: Date(), permissions: 0o644)
                try packer.add(record, expectedSize: UInt64(size)) {
                    defer { sent = true }
                    return sent || size == 0 ? nil : Data(repeating: UInt8(65 + index % 26), count: size)
                }
            }
            try packer.finish()
            try output.close()
            return (url, packer.writer.usedZip64)
        }

        // Below every limit: a classic archive.
        var small = try write([100, 200, 0], limits: ZipLimits(maxField: 100_000, maxEntries: 3))
        #expect(try !small.zip64 && !ZipDirectory.read(RandomAccessFile(small.url)).isZip64)
        // One member more than the end record can count.
        small = try write([100, 200, 0, 5], limits: ZipLimits(maxField: 100_000, maxEntries: 3))
        #expect(small.zip64)
        var contents = try ZipDirectory.read(RandomAccessFile(small.url))
        #expect(contents.isZip64 && contents.records.count == 4)
        #expect(runTool("/usr/bin/unzip", ["-tq", small.url.path]).status == 0)
        // A member larger than the size fields, and members behind an offset that does not fit.
        let large = try write([5_000, 300, 300], limits: ZipLimits(maxField: 1_000, maxEntries: 100))
        #expect(large.zip64)
        contents = try ZipDirectory.read(RandomAccessFile(large.url))
        #expect(contents.records.map(\.uncompressedSize) == [5_000, 300, 300])
        let check = runTool("/usr/bin/unzip", ["-tq", large.url.path])
        #expect(check.status == 0, "\(check.output)")
        let opened = try bench.store.archive(at: large.url)
        #expect(ArchiveTester.test(opened, cancellation: CancellationFlag()).isEmpty)
        #expect(try bench.read(bench.inside(large.url, "file0.txt")) == Data(repeating: 65, count: 5_000))

        // Changing such an archive keeps it readable.
        bench.environment.limits = ZipLimits(maxField: 1_000, maxEntries: 100)
        try bench.zip.remove(bench.inside(large.url, "file1.txt"))
        try bench.store.flush(large.url)
        #expect(runTool("/usr/bin/unzip", ["-tq", large.url.path]).status == 0)
        #expect(try bench.names(bench.inside(large.url)) == ["file0.txt", "file2.txt"])
    }

    @Test func aHugeNumberOfEntriesIsListedFromTheDirectoryAlone() throws {
        // More members than the classic end record can count: a real ZIP64 archive.
        let count = 70_000
        let url = box.url("many.zip")
        let output = try OutputFile(creating: url)
        let packer = ZipPacker(output, level: 6)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<count {
            var sent = false
            let record = ZipRecord.new(
                name: "folder\(index % 100)/file\(index).txt", isDirectory: false, modified: stamp, permissions: 0o644
            )
            try packer.add(record, expectedSize: 4) {
                defer { sent = true }
                return sent ? nil : Data("\(index % 10)abc".utf8)
            }
        }
        try packer.finish()
        try output.close()
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

    @Test func encryptedZipsAskForThePassword() throws {
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
                == Data(contentsOf: tree.appendingPathComponent("big.log")))
        #expect(bench.passwords.asked == 3)
        let unpacked = try bench.unpack(locked, to: box.url("back"))
        #expect(unpacked.problems.isEmpty && snapshot(box.url("back/tree")) == snapshot(tree))

        // What is encrypted here the old way, the system's unzip opens with the password and not without.
        let own = box.url("own.zip")
        try bench.pack([tree], to: own) {
            $0.password = "open sesame"
            $0.encryption = .legacy
            $0.verifies = true
        }
        #expect(runTool("/usr/bin/unzip", ["-tq", "-P", "open sesame", own.path]).status == 0)
        #expect(runTool("/usr/bin/unzip", ["-tq", "-P", "nope", own.path]).status != 0)
        #expect(try bench.store.archive(at: own).hasEncryptedMembers)

        // Three wrong answers end the attempt with a clear error.
        let fresh = try ArchiveBench()
        fresh.passwords.set(["a", "b", "c"])
        #expect { try fresh.read(fresh.inside(own, "tree/readme.txt")) } throws: { error in
            if case ArchiveError.wrongPassword = error { return true }
            return false
        }
    }

    @Test func aDamagedMemberIsFoundByTheTest() throws {
        let tree = try bench.makeTree()
        let archive = box.url("tree.zip")
        try bench.pack([tree], to: archive) { $0.level = 0 }
        var opened = try bench.store.archive(at: archive)
        #expect(ArchiveTester.test(opened, cancellation: CancellationFlag()).isEmpty)

        // One byte in the middle of the stored random data is flipped.
        var bytes = try Data(contentsOf: archive)
        let needle = try Data(contentsOf: tree.appendingPathComponent("sub/random.bin")).prefix(64)
        let position = try #require(bytes.range(of: needle)).lowerBound + 1_000
        bytes[position] ^= 0xFF
        try bytes.write(to: archive)
        opened = try bench.store.archive(at: archive)
        let problems = ArchiveTester.test(opened, cancellation: CancellationFlag())
        #expect(
            problems.count == 1 && problems.first?.contains("random.bin") == true
                && problems.first?.contains("CRC") == true)
        // Unpacking reports it too and does not leave the damaged file behind.
        let result = try bench.unpack(archive, to: box.url("back"))
        #expect(
            result.problems.count == 1 && !box.exists("back/tree/sub/random.bin") && box.exists("back/tree/readme.txt"))
        #expect(namesOnDisk(box.url("back/tree/sub")) == [".hidden", "deep"])

        // A deflated member that is cut short, and a TAR with a broken header.
        try bench.pack([tree], to: box.url("deflated.zip"))
        var deflated = try Data(contentsOf: box.url("deflated.zip"))
        let log = try #require(deflated.range(of: Data("tree/big.log".utf8))).upperBound
        deflated.replaceSubrange((log + 2_000)..<(log + 2_040), with: Data(repeating: 0x55, count: 40))
        try deflated.write(to: box.url("deflated.zip"))
        let broken = ArchiveTester.test(
            try bench.store.archive(at: box.url("deflated.zip")), cancellation: CancellationFlag())
        #expect(broken.count == 1 && broken.first?.contains("big.log") == true)

        try bench.pack([tree], to: box.url("tree.tar")) { $0.format = .tar }
        var tar = try Data(contentsOf: box.url("tree.tar"))
        tar[600] = 0x7F
        tar[512] = 0x7F
        try tar.write(to: box.url("tree.tar"))
        #expect(throws: ArchiveError.self) { try bench.store.archive(at: box.url("tree.tar")) }
    }

    @Test func namesDatesAndAttributesOfForeignZips() throws {
        // A ZIP as a DOS program writes it: backslashes, DOS attributes, a code-page name.
        let url = box.url("dos.zip")
        let output = try OutputFile(creating: url)
        let writer = ZipWriter(output)
        var record = ZipRecord()
        record.versionMadeBy = 20
        record.nameBytes = Data([0x44, 0x49, 0x52, 0x5C, 0x81, 0x62, 0x65, 0x72, 0x2E, 0x74, 0x78, 0x74])  // DIR\über.txt in code page 437
        record.externalAttributes = 0x21
        (record.dosTime, record.dosDate) = DOSTime.encode(DOSTime.date(time: 0x6000, date: 0x5221))
        try writer.end(try writer.begin(record), record, headerChanged: false)
        // Paths that try to leave the folder they are unpacked into are not shown and not unpacked.
        var evil = ZipRecord.new(name: "../../evil.txt", isDirectory: false, modified: Date(), permissions: 0o644)
        evil.setName("../../evil.txt")
        try writer.end(try writer.begin(evil), evil, headerChanged: false)
        try writer.finish(comment: Data("a comment".utf8))
        try output.close()

        let root = bench.inside(url)
        #expect(try bench.names(root) == ["DIR"])
        let file = try #require(try bench.zip.list(root.appending(name: "DIR"), showHidden: true).first)
        #expect(file.name == "über.txt" && file.permissions == 0o444)
        #expect(
            Calendar.current.dateComponents([.year, .month, .day, .hour], from: file.modified)
                == DateComponents(year: 2_021, month: 1, day: 1, hour: 12))
        try bench.unpack(url, to: box.url("safe/inner"))
        #expect(
            box.exists("safe/inner/DIR/über.txt") && !box.exists("safe/inner/evil.txt") && !box.exists("evil.txt")
                && !box.exists("safe/evil.txt"))
        // The comment survives a change of the archive.
        try bench.zip.createDirectory(at: root.appending(name: "new"))
        try bench.store.flush(url)
        #expect(runTool("/usr/bin/unzip", ["-z", url.path]).output.contains("a comment"))
    }

    @Test func tarHeadersCarryLongNamesAndLargeSizes() throws {
        var header = TarHeader(
            path: "short.txt", size: 5, modified: Date(timeIntervalSince1970: 1_700_000_000), permissions: 0o640)
        var parsed = try #require(TarHeader.parse(header.encoded()))
        #expect(
            parsed.header.path == "short.txt" && parsed.header.size == 5 && parsed.header.permissions == 0o640
                && parsed.header.kind == .file)

        // A long path is split at a slash when that works, and written as a pax record otherwise.
        let split = String(repeating: "d", count: 90) + "/" + String(repeating: "f", count: 60)
        header.path = split
        #expect(header.encoded().count == 512)
        let unsplittable = String(repeating: "x", count: 300)
        header.path = unsplittable
        header.size = 0o100000000000
        let blocks = header.encoded()
        #expect(blocks.count == 3 * 512)
        let reader = TarReader(DataStream(blocks + Data(count: 1_024)))
        let read = try #require(try reader.next())
        #expect(read.path == unsplittable && read.size == 0o100000000000)
        parsed = try #require(TarHeader.parse(TarHeader(path: "dir", kind: .directory).encoded()))
        #expect(parsed.header.kind == .directory && parsed.header.path == "dir/")
        #expect(
            !TarHeader.looksLikeHeader(Data(count: 512)) && !TarHeader.looksLikeHeader(Data(repeating: 65, count: 512)))
    }

    @Test func parallelCompressionGivesOneValidStream() throws {
        // Enough data for several pieces per window, ending exactly on a piece boundary.
        var data = Data()
        var line = 0
        while data.count < 3 << 20 {
            data.append(Data("\(line) the quick brown fox jumps over the lazy dog\n".utf8))
            line += 1
        }
        data = data.prefix(3 << 20)
        for (method, name) in [
            (ParallelCompressor.Method.gzip(level: 6), "p.gz"), (.bzip2(level: 9), "p.bz2"), (.xz, "p.xz"),
            (.gzip(level: 1), "empty.gz")
        ] {
            let url = box.url(name)
            let output = try OutputFile(creating: url)
            let compressor = try ParallelCompressor(method, to: output)
            if name != "empty.gz" {
                try compressor.write(data.prefix(1_000_000))
                try compressor.write(data.dropFirst(1_000_000))
            }
            try compressor.finish()
            try output.close()
            let file = try RandomAccessFile(url)
            let codec: ArchiveFormat.Codec = name.hasSuffix("gz") ? .gzip : name.hasSuffix("bz2") ? .bzip2 : .xz
            let stream = try codec.decompressing(file)
            var back = Data()
            while let block = try stream.read(upToCount: 100_000) { back.append(block) }
            stream.close()
            #expect(back == (name == "empty.gz" ? Data() : data), "\(name)")
        }
        #expect(runTool("/usr/bin/gzip", ["-t", box.url("p.gz").path, box.url("empty.gz").path]).status == 0)
        #expect(runTool("/usr/bin/bzip2", ["-t", box.url("p.bz2").path]).status == 0)
        // The checksum of pieces summed separately is the checksum of the whole.
        let (first, second) = (data.prefix(12_345), data.dropFirst(12_345))
        #expect(
            CRC32.combine(CRC32.of(Data(first)), CRC32.of(Data(second)), secondLength: second.count) == CRC32.of(data))
        #expect(CRC32.of(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func aFileLargerThanOneWindowOfPiecesIsPackedInSeveralRounds() throws {
        // More than the compressors hold before they write: the member stays open across rounds.
        let megabytes = ProcessInfo.processInfo.activeProcessorCount * 2 + 3
        var block = Data()
        for index in 0..<16_384 { block.append(Data(String(format: "%07d %055d\n", index, index &* 7_919).utf8)) }
        #expect(block.count == 1 << 20)
        let handle = try FileHandle(forWritingTo: try box.file("huge.dat", ""))
        for round in 0..<megabytes {
            var piece = block
            piece.replaceSubrange(0..<8, with: Data(String(format: "%08d", round).utf8))
            try handle.write(contentsOf: piece)
        }
        try handle.write(contentsOf: Data("tail".utf8))
        try handle.close()
        let source = box.url("huge.dat")
        let sum = runTool("/usr/bin/cksum", [source.path]).output.split(separator: " ").prefix(2).joined(separator: " ")

        try bench.pack([source], to: box.url("huge.zip"))
        try bench.pack([source], to: box.url("locked.zip")) {
            $0.password = "pw"
            $0.encryption = .legacy
            $0.verifies = true
        }
        try bench.pack([source], to: box.url("huge.tgz")) { $0.format = .compressedTar(.gzip) }
        try bench.pack([source], to: box.url("huge.dat.gz")) { $0.format = .compressedFile(.gzip) }
        #expect(try Data(contentsOf: box.url("huge.zip")).count < megabytes << 18)
        #expect(runTool("/usr/bin/unzip", ["-tq", box.url("huge.zip").path]).status == 0)
        #expect(runTool("/usr/bin/unzip", ["-tq", "-P", "pw", box.url("locked.zip").path]).status == 0)
        #expect(runTool("/usr/bin/gzip", ["-t", box.url("huge.tgz").path, box.url("huge.dat.gz").path]).status == 0)
        for name in ["huge.zip", "huge.tgz", "huge.dat.gz"] {
            let folder = try box.folder("out-" + name)
            #expect(try bench.unpack(box.url(name), to: folder).problems.isEmpty)
            let unpacked = runTool("/usr/bin/cksum", [folder.appendingPathComponent("huge.dat").path]).output.split(
                separator: " "
            ).prefix(2)
            #expect(unpacked.joined(separator: " ") == sum, "\(name)")
        }
        #expect(bench.monitor.reports.last?.bytesDone == Int64(megabytes << 20 + 4))
    }

    @Test func aChildProcessIsStoppedWhenItsStreamIsClosed() throws {
        let tree = try bench.makeTree()
        try bench.pack([tree], to: box.url("tree.tar.bz2")) { $0.format = .compressedTar(.bzip2) }
        let stream = try ProcessStream(Tool.bzip2, ["-dc", "--", box.url("tree.tar.bz2").path])
        #expect(try stream.read(upToCount: 512)?.isEmpty == false)
        stream.close()
        // A tool that fails says why.
        let failing = try ProcessStream(
            Tool.bsdtar, ["-cf", "-", "--format", "pax", "@" + box.url("missing.7z").path])
        #expect(throws: ArchiveError.self) { while try failing.read(upToCount: 4_096) != nil {} }
        // Arguments reach the tool as they are: no shell reads the name.
        let odd = try box.file("odd $(touch pwned) ; name's \"x\".txt", "odd")
        #expect(runTool("/usr/bin/bzip2", ["-k", odd.path]).status == 0)
        let inner = bench.inside(
            URL(fileURLWithPath: odd.path + ".bz2"), odd.lastPathComponent, scheme: ArchiveURL.readOnlyScheme)
        #expect(try bench.read(inner) == Data("odd".utf8))
        #expect(!box.exists("pwned"))
    }
}
