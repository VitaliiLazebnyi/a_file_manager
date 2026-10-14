import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// One 512-byte TAR header built by hand.
private func tarHeader(name: String, type: UInt8 = 48, size: UInt64 = 0, link: String = "", mode: UInt64 = 0o644)
    -> Data
{
    var block = [UInt8](repeating: 0, count: 512)
    func put(_ bytes: [UInt8], at offset: Int) {
        for (index, byte) in bytes.enumerated() { block[offset + index] = byte }
    }
    func octal(_ value: UInt64, _ length: Int) -> [UInt8] {
        let digits = String(value, radix: 8)
        return Array((String(repeating: "0", count: length - 1 - digits.count) + digits).utf8)
    }
    put(Array(name.utf8.prefix(100)), at: 0)
    put(octal(mode, 8), at: 100)
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

/// A clock for the delayed writes that the test turns by hand.
/// Unchecked: what is due is guarded by `lock`.
private final class HandClock: @unchecked Sendable {
    struct Due {
        let delay: TimeInterval
        let priority: QualityOfService
        let work: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var waiting: [Due] = []

    func schedule(_ delay: TimeInterval, _ priority: QualityOfService, _ work: @escaping @Sendable () -> Void) {
        lock.lock()
        waiting.append(Due(delay: delay, priority: priority, work: work))
        lock.unlock()
    }

    /// What was scheduled since the last call, in the order it was.
    func take() -> [Due] {
        lock.lock()
        defer { lock.unlock() }
        let taken = waiting
        waiting = []
        return taken
    }
}

/// What a test collects from other threads.
/// Unchecked: the state is guarded by `lock`.
private final class Collected<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func add(_ value: Value) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var all: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// Review round 2, second pass: the compact directory, unpacking from a folder's descriptor,
/// the kernel's hooks for quitting, for bringing a file up to date and for the read order,
/// and the paths the first pass left without a test (the clock of the delayed writes, the
/// branches of the quit, members that wait next to an archive on another volume).
@MainActor @Suite struct Review2ArchivesP2 {
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

    /// A ZIP written record by record, for names and rights no packer would write.
    func writeZip(_ name: String, members: [(name: String, permissions: UInt16)]) throws -> URL {
        let url = box.url(name)
        let output = try OutputFile(creating: url)
        let writer = ZipWriter(output)
        for member in members {
            var record = ZipRecord.new(
                name: member.name, isDirectory: false, modified: Date(), permissions: member.permissions)
            record.setName(member.name)
            try writer.end(try writer.begin(record), record, headerChanged: false)
        }
        try writer.finish()
        try output.close()
        return url
    }

    func mode(_ url: URL) -> Int {
        var status = stat()
        return lstat(url.path, &status) == 0 ? Int(status.st_mode & 0o7777) : -1
    }

    func isLink(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0 && status.st_mode & S_IFMT == S_IFLNK
    }

    // MARK: The compact directory (A051, A076)

    @Test func theTreeBehavesLikeAPlainTableWhilePlacesAreUsedAgain() {
        var tree = ArchiveTree()
        var model: [String: Bool] = [:]  // path → is a folder
        var generator = SystemRandomNumberGenerator()
        func check(_: Int) -> Bool {
            let files = model.filter { !$0.value }.keys
            // Every folder above a file exists, made up or real.
            var folders = Set(model.filter(\.value).keys)
            for file in files {
                var parent = ArchiveTree.parent(of: file)
                while !parent.isEmpty {
                    folders.insert(parent)
                    parent = ArchiveTree.parent(of: parent)
                }
            }
            let expected = Set(files).union(folders)
            guard Set(tree.unordered.map(\.path)).isSuperset(of: expected), tree.count == tree.unordered.count else {
                return false
            }
            for folder in folders.union([""]) {
                let inside = Set(expected.filter { ArchiveTree.parent(of: $0) == folder }.map(ArchiveTree.name(of:)))
                guard let children = tree.children(of: folder), Set(children.map(\.name)).isSuperset(of: inside),
                    children.allSatisfy({ ArchiveTree.parent(of: $0.path) == folder })
                else { return false }
            }
            // The order is the order of the positions, and each position leads back to its entry.
            let ordered = tree.ordered
            guard ordered.map(\.order) == ordered.map(\.order).sorted(), ordered.count == tree.count else {
                return false
            }
            return ordered.allSatisfy { tree.entry($0.path)?.order == $0.order }
        }
        for round in 0..<3_000 {
            let path =
                "d\(Int.random(in: 0..<5, using: &generator))/e\(Int.random(in: 0..<4, using: &generator))/f\(Int.random(in: 0..<30, using: &generator))"
            switch Int.random(in: 0..<4, using: &generator) {
            case 0, 1:
                tree.insert(ArchiveEntry(path: path, isDirectory: false, size: Int64(round)))
                model[path] = false

            case 2:
                // Only what the tree's callers remove: a file, or a folder with nothing in it.
                if tree.remove(path) != nil { model[path] = nil }

            default:
                tree.update(path) { $0.size = -1 }
                #expect(tree.entry(path).map { $0.size == -1 } ?? true)
            }
            if round % 50 == 0, !check(round) {
                Issue.record("the tree and the table differ in round \(round)")
                break
            }
        }
        #expect(check(-1))
        // A position that is taken leads to its path, one that is not leads nowhere.
        let some = tree.ordered[tree.count / 2]
        #expect(tree.path(atOrder: some.order) == some.path && tree.path(atOrder: 1 << 40) == nil)
        // The places that were given up are used again: the table does not grow with the changes.
        #expect(tree.unordered.count <= 5 * 4 * 30 + 5 * 4 + 5)
    }

    @Test func aRecordKeepsItsNameAsItWasWritten() throws {
        var record = ZipRecord()
        // Valid text: kept as text, read back byte for byte.
        record.nameBytes = Data("dir/übung – 日本.txt".utf8)
        #expect(
            record.nameBytes == Data("dir/übung – 日本.txt".utf8) && record.nameLength == record.nameBytes.count
                && !record.isDirectory)
        // Not text at all (code page 437), a byte-order mark, a name that ends in a slash.
        let dos = Data([0x44, 0x49, 0x52, 0x5C, 0x81, 0x62, 0x65, 0x72, 0x2E, 0x74, 0x78, 0x74])
        record.nameBytes = dos
        #expect(record.nameBytes == dos && record.nameLength == 12 && record.name == "DIR\\über.txt")
        let marked = Data([0xEF, 0xBB, 0xBF]) + Data("bom.txt".utf8)
        record.nameBytes = marked
        #expect(record.nameBytes == marked && record.nameLength == 10)
        record.nameBytes = Data("folder/".utf8)
        #expect(record.isDirectory && record.nameLength == 7)
        record.nameBytes = Data()
        #expect(record.nameBytes.isEmpty && record.nameLength == 0 && !record.isDirectory)
        // Two names that are the same text to Swift and other bytes are two names.
        var (composed, decomposed) = (ZipRecord(), ZipRecord())
        composed.nameBytes = Data("é.txt".precomposedStringWithCanonicalMapping.utf8)
        decomposed.nameBytes = Data("é.txt".decomposedStringWithCanonicalMapping.utf8)
        #expect(!composed.hasSameHeader(as: decomposed) && composed.hasSameHeader(as: composed))
        // Extra fields and comment come back as they went in.
        record.extra = Data([0x55, 0x54, 5, 0, 1, 1, 2, 3, 4])
        record.comment = Data("a comment".utf8)
        #expect(
            record.extra == Data([0x55, 0x54, 5, 0, 1, 1, 2, 3, 4]) && record.extraLength == 9
                && record.comment == Data("a comment".utf8))

        // Through a file: names in an old character set survive a rewrite of the archive.
        let url = box.url("names.zip")
        let output = try OutputFile(creating: url)
        let writer = ZipWriter(output)
        var old = ZipRecord.new(name: "x", isDirectory: false, modified: Date(), permissions: 0o644)
        old.nameBytes = dos
        old.flags &= ~ZipRecord.flagUTF8
        old.versionMadeBy = 20
        try writer.end(try writer.begin(old), old, headerChanged: false)
        try writer.finish()
        try output.close()
        #expect(try bench.names(bench.inside(url, "DIR")) == ["über.txt"])
        try write("new", to: bench.inside(url, "new.txt"))
        #expect(bench.store.flushAll().isEmpty)
        let records = try ZipDirectory.read(RandomAccessFile(url)).records
        #expect(records.map(\.nameBytes) == [dos, Data("new.txt".utf8)])
    }

    // MARK: Unpacking from the folder's descriptor (L043), absolute paths

    @Test func aLinkPutInPlaceWhileAMemberIsUnpackedDoesNotLeadItAway() throws {
        let outside = try box.folder("outside")
        let target = try box.folder("target")
        let archive = try writeZip(
            "race.zip",
            members: [("dir/sub/planted.txt", 0o644), ("dir/sub/second.txt", 0o644), ("plain.txt", 0o644)])
        let unpacker = Unpacker(fileSystems: bench.fileSystems, monitor: bench.monitor, options: UnpackOptions()) {
            _, _ in .overwrite
        }
        let swapped = Collected<String>()
        let fm = FileManager.default
        // The folder was looked at and opened; now somebody takes it away and puts a link
        // to another place where it stood.
        // The link takes the folder's name in one step (the two names are exchanged): the
        // members are unpacked by several threads, and were the name free for a moment, another
        // member's thread could make a new folder `dir` there, which is neither of the two
        // outcomes this test tells apart (seen once in a run under the address sanitizer).
        try fm.createDirectory(at: outside.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let link = target.appendingPathComponent("dir.link")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        unpacker.whileUnpacking = { entry in
            guard entry.path == "dir/sub/planted.txt", swapped.all.isEmpty else { return }
            swapped.add(entry.path)
            if renamex_np(target.appendingPathComponent("dir").path, link.path, UInt32(RENAME_SWAP)) == 0 {
                try? FileManager.default.moveItem(at: link, to: target.appendingPathComponent("taken"))
            }
        }
        let result = unpacker.run([Unpacker.Source(archive: try bench.store.archive(at: archive))], into: target)
        #expect(swapped.all == ["dir/sub/planted.txt"])
        // Nothing arrived at the place the link points to.
        #expect(try fm.contentsOfDirectory(atPath: outside.appendingPathComponent("sub").path).isEmpty)
        #expect(try fm.contentsOfDirectory(atPath: outside.path) == ["sub"])
        // The member that was under way went into the folder that had been opened; whatever
        // came after the link stood there was refused, not sent through it.
        #expect(box.exists("target/taken/sub/planted.txt") && box.exists("target/plain.txt"))
        let late = box.exists("target/taken/sub/second.txt")
        #expect(late || result.problems.contains { $0.contains("second.txt") }, "\(result.problems)")
        #expect(isLink(target.appendingPathComponent("dir")))
    }

    @Test func noLinkOnTheWayIsGoneThroughWhoeverMadeIt() throws {
        let outside = try box.folder("outside")
        let target = try box.folder("target")
        // A link two folders down, left there before.
        try box.folder("target/a/b")
        try FileManager.default.createSymbolicLink(
            at: target.appendingPathComponent("a/b/c"), withDestinationURL: outside)
        let zip = try writeZip("deep.zip", members: [("a/b/c/d/planted.txt", 0o644), ("a/b/fine.txt", 0o644)])
        var result = try bench.unpack(zip, to: target)
        #expect(
            result.unpacked >= 1 && box.exists("target/a/b/fine.txt") && !result.problems.isEmpty, "\(result.problems)"
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)

        // A link the archive brings itself, and a member that wants to go through it.
        var tar = tarHeader(name: "door", type: 50, link: outside.path)
        tar.append(tarHeader(name: "door/planted.txt", size: 5))
        tar.append(tarBody("hello"))
        tar.append(tarHeader(name: "honest.txt", size: 5))
        tar.append(tarBody("hello"))
        tar.append(Data(count: 1_024))
        try tar.write(to: box.url("door.tar"))
        let second = try box.folder("second")
        result = try bench.unpack(box.url("door.tar"), to: second)
        // Either the link is there and the member was refused, or the member is in a folder
        // of that name below the target and the link was refused; never both, and nothing outside.
        #expect(box.read("second/honest.txt") == "hello" && result.problems.count == 1, "\(result.problems)")
        #expect(isLink(second.appendingPathComponent("door")) != box.exists("second/door/planted.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        // Which of the two does not depend on chance: the files come first, the links after them.
        #expect(box.read("second/door/planted.txt") == "hello" && result.problems.first?.hasPrefix("door:") == true)
    }

    @Test func membersWithAbsolutePathsLandBelowTheFolderThatIsUnpackedInto() throws {
        // Where the members claim to belong: a folder of the test, so a member that got
        // there would be seen (and would harm nothing).
        let claimed = try box.folder("claimed")
        let inner = String(claimed.path.dropFirst())
        let zip = try writeZip(
            "absolute.zip",
            members: [
                (claimed.path + "/evil.txt", 0o644), ("//" + inner + "/second.txt", 0o644), ("/top.txt", 0o644)
            ])
        var tar = tarHeader(name: "/" + String(repeating: "/", count: 3) + "tar-top.txt", size: 5)
        tar.append(tarBody("hello"))
        tar.append(tarHeader(name: "/claimed-by-tar/deep.txt", size: 5))
        tar.append(tarBody("hello"))
        tar.append(Data(count: 1_024))
        try tar.write(to: box.url("absolute.tar"))

        // Listed without the leading slashes…
        let opened = try bench.store.archive(at: zip)
        #expect(opened.entry(inner + "/evil.txt") != nil && opened.entry("top.txt") != nil)
        #expect(opened.entries.allSatisfy { !$0.path.hasPrefix("/") })
        // …and unpacked below the target, every one of them.
        let target = try box.folder("target")
        for archive in [zip, box.url("absolute.tar")] {
            let result = try bench.unpack(archive, to: target)
            #expect(result.problems.isEmpty, "\(result.problems)")
        }
        #expect(box.exists("target/" + inner + "/evil.txt") && box.exists("target/" + inner + "/second.txt"))
        #expect(
            box.exists("target/top.txt") && box.exists("target/tar-top.txt")
                && box.exists("target/claimed-by-tar/deep.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: claimed.path).isEmpty)
        #expect(
            !FileManager.default.fileExists(atPath: "/claimed-by-tar")
                && !FileManager.default.fileExists(atPath: "/top.txt"))
        // Everything that arrived lies below the target, links followed.
        let arrived =
            FileManager.default.enumerator(at: target, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        #expect(
            arrived.count >= 5 && arrived.allSatisfy { PathSafety.isContained($0, in: target, resolvingLinks: true) })
    }

    @Test func unpackedFilesGetNoRightsBeyondWhatNewFilesGet() throws {
        let zip = try writeZip(
            "open.zip", members: [("everyone.txt", 0o666), ("tool", 0o777), ("mine.txt", 0o600)])
        let target = try box.folder("target")
        let result = try bench.unpack(zip, to: target)
        #expect(result.problems.isEmpty && result.unpacked == 3)
        let allowed = Int(UnpackFolder.allowed)
        #expect(
            mode(box.url("target/everyone.txt")) == 0o666 & allowed && mode(box.url("target/tool")) == 0o777 & allowed)
        #expect(mode(box.url("target/mine.txt")) == 0o600)
        // (With the usual mask nobody else may write to them.)
        if allowed & 0o022 == 0 { #expect(mode(box.url("target/everyone.txt")) & 0o022 == 0) }
        // A file that exists is replaced by the new one, also where a link stands in its place.
        try FileManager.default.removeItem(at: box.url("target/mine.txt"))
        try box.file("elsewhere.txt", "untouched")
        try FileManager.default.createSymbolicLink(
            at: box.url("target/mine.txt"), withDestinationURL: box.url("elsewhere.txt"))
        #expect(try bench.unpack(zip, to: target).problems.isEmpty)
        #expect(!isLink(box.url("target/mine.txt")) && box.read("elsewhere.txt") == "untouched")
        // Nothing of the temporary names is left.
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: target.path).sorted() == [
                "everyone.txt", "mine.txt", "tool"
            ])
    }

    // MARK: The kernel's hooks (A041, A044, quitting)

    @Test func membersOfAStreamArchiveAreReadInTheOrderTheyLieInIt() throws {
        try bench.makeTree()
        for index in 0..<12 { try box.file("tree/many/file\(index).txt", "contents of \(index)") }
        try bench.pack([box.url("tree")], to: box.url("stream.tar.gz")) { $0.format = .compressedTar(.gzip) }
        try bench.pack([box.url("tree")], to: box.url("plain.zip"))
        // Too large for a temporary copy: every read goes through the stream.
        bench.environment.materializeLimit = 0
        let stream = try bench.store.archive(at: box.url("stream.tar.gz"))
        #expect(!stream.allowsParallelReads)
        let folder = bench.inside(box.url("stream.tar.gz"), "tree/many", scheme: ArchiveURL.readOnlyScheme)
        let inArchive = try #require(stream.children(of: "tree/many")).sorted { $0.order < $1.order }.map {
            folder.appending(name: $0.name)
        }
        // Whatever order they come in (by name, backwards), they go out in the archive's.
        let other = URL(fileURLWithPath: "/somewhere/else.txt")
        let ordered = bench.readOnly.readOrder(of: [other] + inArchive.reversed())
        #expect(ordered == [other] + inArchive)
        #expect(
            bench.readOnly.readOrder(of: inArchive.sorted { $0.lastPathComponent < $1.lastPathComponent }) == inArchive)
        // Read that way, the archive is gone through once.
        let before = stream.streamStarts
        for url in ordered.dropFirst() { #expect(try bench.read(url).starts(with: Data("contents of ".utf8))) }
        #expect(stream.streamStarts - before == 1)
        // An archive that is read at any place keeps the order it was asked in.
        _ = try bench.store.archive(at: box.url("plain.zip"))
        let zipFolder = bench.inside(box.url("plain.zip"), "tree/many")
        let asked = (0..<12).reversed().map { zipFolder.appending(name: "file\($0).txt") }
        #expect(bench.zip.readOrder(of: asked) == asked)
    }

    @Test func aStreamThatEndsBeforeEveryMemberCameIsAnError() throws {
        // (A090.) The archive is listed, then cut short where it lies: a pass that is to
        // deliver members the stream no longer holds must say so, not return as if done.
        try bench.makeTree()
        for index in 0..<8 { try box.file("tree/many/file\(index).txt", "contents of \(index)") }
        try box.file("little/only.txt", "only")
        try bench.pack([box.url("tree")], to: box.url("full.tar.gz")) { $0.format = .compressedTar(.gzip) }
        try bench.pack([box.url("little")], to: box.url("short.tar.gz")) { $0.format = .compressedTar(.gzip) }
        bench.environment.materializeLimit = 0
        let archive = try bench.store.archive(at: box.url("full.tar.gz"))
        let wanted = archive.entries.filter { !$0.isDirectory }
        #expect(wanted.count > 8 && !archive.allowsParallelReads)
        var delivered = 0
        try archive.readInOnePass(wanted) { _, stream in
            while try stream.read(upToCount: 1 << 16) != nil {}
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
            try archive.readInOnePass(wanted) { _, stream in
                while try stream.read(upToCount: 1 << 16) != nil {}
                delivered += 1
            }
        }
        #expect(delivered < wanted.count)
    }

    @Test func aFileIsBroughtUpToDateBeforeSomebodyElseUsesIt() throws {
        let archive = try makeZip()
        let store = bench.store
        bench.fileSystems.addFlusher { url, cancellation in try store.bringUpToDate(url, cancellation: cancellation) }
        let flag = CancellationFlag()
        try write("waiting", to: bench.inside(archive, "tree/waiting.txt"))
        #expect(store.hasPendingChanges && !listed(archive).contains("tree/waiting.txt"))
        // Another file: nothing happens, and nothing is opened for it.
        try bench.fileSystems.flushPendingWrites(to: box.url("tree/readme.txt"), cancellation: flag)
        try bench.fileSystems.flushPendingWrites(to: box.url("other.zip"), cancellation: flag)
        #expect(store.hasPendingChanges && store.openArchive(at: box.url("other.zip")) == nil)
        // The archive file itself.
        try bench.fileSystems.flushPendingWrites(to: archive, cancellation: flag)
        #expect(!store.hasPendingChanges && listed(archive).contains("tree/waiting.txt"))
        // The folder it lies in (which is about to be moved or deleted).
        try write("again", to: bench.inside(archive, "tree/again.txt"))
        try bench.fileSystems.flushPendingWrites(to: box.root, cancellation: flag)
        #expect(!store.hasPendingChanges && listed(archive).contains("tree/again.txt"))
        // An archive inside it: both are written, the inner one first.
        #expect(runTool("/usr/bin/zip", ["-q0", "outer.zip", "tree.zip"], in: box.root).status == 0)
        let inner = bench.inside(box.url("outer.zip"), "tree.zip")
        try write("deep", to: bench.inside(inner, "tree/deep.txt"))
        try bench.fileSystems.flushPendingWrites(to: box.url("outer.zip"), cancellation: flag)
        #expect(!store.hasPendingChanges)
        #expect(
            runTool("/usr/bin/unzip", ["-qo", box.url("outer.zip").path, "-d", box.url("check").path]).status == 0)
        #expect(listed(box.url("check/tree.zip")).contains("tree/deep.txt"))
        // A write that cannot be made is the caller's to know of: the file is not what is shown.
        try write("late", to: bench.inside(archive, "tree/late.txt"))
        flag.cancel()
        #expect(throws: (any Error).self) { try bench.fileSystems.flushPendingWrites(to: archive, cancellation: flag) }
        #expect(store.hasPendingChanges)
    }

    @Test func changesAreWrittenBeforeTheProgramQuits() throws {
        let archive = try makeZip()
        let plugin = ArchivesPlugin(flushDelay: nil, launchesApplications: false)
        defer { plugin.store.close() }
        // Nothing to do: done at once, on the calling thread.
        // Written by the other thread before it signals, read here after the wait.
        nonisolated(unsafe) var done = false
        plugin.prepareToQuit(cancellation: CancellationFlag()) { done = true }
        #expect(done && plugin.shouldTerminate())

        let writer = try plugin.store.archive(at: archive).write("tree/at-quit.txt")
        try writer.write(Data("kept".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(plugin.hasPendingChanges && !listed(archive).contains("tree/at-quit.txt"))
        let finished = DispatchSemaphore(value: 0)
        plugin.prepareToQuit(cancellation: CancellationFlag()) { finished.signal() }
        finished.wait()
        #expect(!plugin.hasPendingChanges && listed(archive).contains("tree/at-quit.txt"))
        #expect(!plugin.environment.quitting.isCancelled)
    }

    @Test func aQuitTheUserDoesNotWaitForKeepsWhatWasNotWritten() throws {
        let archive = try makeZip()
        let plugin = ArchivesPlugin(flushDelay: nil, launchesApplications: false)
        let reports = Collected<String>()
        plugin.environment.reportFailure = { error, _ in reports.add(error.localizedDescription) }
        let opened = try plugin.store.archive(at: archive)
        let writer = try opened.write("tree/unwritten.txt")
        try writer.write(Data("unwritten".utf8))
        try writer.close(attributes: FileAttributes())

        // Somebody holds the archive file (a Pack that runs), so the write has to wait.
        let (holding, release, released) = (
            DispatchSemaphore(value: 0), DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)
        )
        plugin.environment.immediateWriteLimit = 0
        Thread.detachNewThread {
            // (The changes that wait are written first by this call; these come after.)
            try? opened.whileHoldingFile(cancellation: nil) { _ in
                if let late = try? opened.write("tree/late.txt") {
                    try? late.write(Data("late".utf8))
                    try? late.close(attributes: FileAttributes())
                }
                holding.signal()
                release.wait()
            }
            released.signal()
        }
        holding.wait()
        #expect(plugin.hasPendingChanges)
        // The sheet's Cancel: the hook reports back although nothing could be written…
        let cancellation = CancellationFlag()
        let finished = DispatchSemaphore(value: 0)
        plugin.prepareToQuit(cancellation: cancellation) { finished.signal() }
        cancellation.cancel()
        finished.wait()
        #expect(plugin.hasPendingChanges && plugin.environment.quitting.isCancelled)
        // …and the stop does not start waiting again: the member is kept where it lies,
        // with a list that says what it is, and the user is told where.
        plugin.stop()
        let scratch = plugin.environment.scratch.url
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
        let index = try #require(kept.first { $0.hasPrefix("index-") })
        let list = try String(contentsOf: scratch.appendingPathComponent(index), encoding: .utf8)
        #expect(list.contains("tree/late.txt") && kept.contains { $0.hasSuffix(".zipdata") })
        #expect(reports.all.count == 1 && reports.all.first?.contains(scratch.path) == true, "\(reports.all)")
        release.signal()
        released.wait()
        try? FileManager.default.removeItem(at: scratch)
    }

    @Test func aQuitThatRunsOutOfTimeEndsTheWritesAndSaysWhereTheDataIs() throws {
        // First branch: the writes can be ended. Second: one cannot (it waits for something
        // that never answers), and the program quits all the same, deleting nothing.
        for endable in [true, false] {
            let name = endable ? "endable.zip" : "stuck.zip"
            try? FileManager.default.removeItem(at: box.url("tree"))
            let archive = try makeZip(name)
            let plugin = ArchivesPlugin(flushDelay: nil, launchesApplications: false)
            let reports = Collected<String>()
            plugin.environment.reportFailure = { error, _ in reports.add(error.localizedDescription) }
            // (Long enough for the last attempt to save the members, which waits two seconds
            // for the archive file, to be over before the stop gives up on it.)
            plugin.environment.quitTimeout = endable ? 3 : 0.2
            plugin.environment.immediateWriteLimit = 0
            let opened = try plugin.store.archive(at: archive)
            let (holding, release, released) = (
                DispatchSemaphore(value: 0), DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)
            )
            @Sendable func add(_ path: String) {
                guard let writer = try? opened.write(path) else { return }
                try? writer.write(Data("added".utf8))
                try? writer.close(attributes: FileAttributes())
            }
            if endable {
                // The archive file is held by somebody else: the write waits for it, and that wait can be ended.
                Thread.detachNewThread {
                    try? opened.whileHoldingFile(cancellation: nil) { _ in
                        add("tree/added.txt")
                        holding.signal()
                        release.wait()
                    }
                    released.signal()
                }
                holding.wait()
            } else {
                // The write itself is stuck where nothing ends it.
                add("tree/added.txt")
                plugin.environment.whileWriting = {
                    holding.signal()
                    release.wait()
                    released.signal()
                }
            }
            #expect(plugin.hasPendingChanges)
            plugin.stop()
            #expect(plugin.environment.quitting.isCancelled)
            let scratch = plugin.environment.scratch.url
            var kept = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
            // (On a machine too busy for the stop to see the list written, it is written a moment later.)
            let patience = Date(timeIntervalSinceNow: 60)
            while endable, !kept.contains(where: { $0.hasPrefix("index-") }), Date() < patience {
                usleep(20_000)
                kept = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
            }
            // Told once, with the place; the compressed data is still there.
            #expect(
                reports.all.count == 1 && reports.all.first?.contains(scratch.path) == true,
                "\(endable): \(reports.all)")
            #expect(kept.contains { $0.hasSuffix(".zipdata") }, "\(endable): \(kept)")
            if endable { #expect(kept.contains { $0.hasPrefix("index-") }) }
            // The archive itself is whole, as it was.
            #expect(
                runTool("/usr/bin/unzip", ["-tq", archive.path]).status == 0
                    && !listed(archive).contains("tree/added.txt"))
            release.signal()
            released.wait()
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    // MARK: The clock of the delayed writes (A043, A045)

    @Test func aWriteThatIsDueIsDoneByWhicheverOfItsTwoTimersComesFirst() throws {
        let archive = try makeZip()
        let clock = HandClock()
        bench.environment.schedule = { clock.schedule($0, $1, $2) }
        bench.environment.flushDelay = 3
        bench.environment.escalationDelay = 7
        try write("first", to: bench.inside(archive, "tree/first.txt"))
        // One change, two timers: the patient one at the delay, the urgent one behind it.
        let due = clock.take()
        #expect(due.map(\.delay) == [3, 10] && due.map(\.priority) == [.utility, .userInitiated])
        // More changes before it fires arm nothing new.
        try write("second", to: bench.inside(archive, "tree/second.txt"))
        #expect(clock.take().isEmpty)
        // The patient one never gets to run (every core is busy); the urgent one writes. The
        // changes have not rested for the delay yet, so it first waits out the rest…
        due[1].work()
        #expect(!listed(archive).contains("tree/first.txt"))
        var next = clock.take()
        #expect(next.count == 2 && next[0].delay > 0 && next[0].delay <= 3)
        // …and writes when the delay has passed.
        bench.environment.flushDelay = 0
        next[1].work()
        #expect(
            listed(archive).contains("tree/first.txt") && listed(archive).contains("tree/second.txt")
                && !bench.store.hasPendingChanges)
        // The ones that come late find nothing to do, and arm nothing.
        due[0].work()
        next[0].work()
        #expect(clock.take().isEmpty && !bench.store.hasPendingChanges)
        // After the program began to quit, a timer that still fires writes nothing.
        try write("third", to: bench.inside(archive, "tree/third.txt"))
        next = clock.take()
        bench.environment.isStopping = true
        next.forEach { $0.work() }
        #expect(bench.store.hasPendingChanges && !listed(archive).contains("tree/third.txt"))
        bench.environment.isStopping = false
        #expect(bench.store.flushAll().isEmpty)
    }

    @Test func aWriteThatFailsIsTriedAgainEachTimeAfterTwiceAsLong() throws {
        try bench.makeTree()
        try box.folder("locked")
        #expect(runTool("/usr/bin/zip", ["-qr", "locked/tree.zip", "tree"], in: box.root).status == 0)
        let archive = box.url("locked/tree.zip")
        let clock = HandClock()
        let reports = Collected<String>()
        bench.environment.schedule = { clock.schedule($0, $1, $2) }
        bench.environment.reportFailure = { error, _ in reports.add(error.localizedDescription) }
        (bench.environment.flushDelay, bench.environment.escalationDelay) = (0, 1)
        (bench.environment.retryDelay, bench.environment.maxRetryDelay) = (30, 100)
        bench.environment.immediateWriteLimit = 0
        try write("kept back", to: bench.inside(archive, "tree/kept-back.txt"))
        var due = clock.take()
        #expect(due.map(\.delay) == [0, 1])
        // The folder takes no new file: the write fails, and goes on failing.
        #expect(chmod(box.url("locked").path, 0o555) == 0)
        defer { chmod(box.url("locked").path, 0o755) }
        var pauses: [TimeInterval] = []
        for _ in 0..<4 {
            due[0].work()
            due = clock.take()
            #expect(due.count == 2 && due.map(\.priority) == [.utility, .userInitiated])
            pauses.append(due.first?.delay ?? -1)
            guard due.count == 2 else { break }
        }
        // 30 s, then twice as long each time, and never more than the limit.
        #expect(pauses == [30, 60, 100, 100], "\(pauses)")
        // The user heard of it once, and the change still waits.
        #expect(reports.all.count == 1 && bench.store.hasPendingChanges)
        // A change brings the next attempt at once, not at the end of the pause.
        #expect(chmod(box.url("locked").path, 0o755) == 0)
        try write("more", to: bench.inside(archive, "tree/more.txt"))
        let sooner = clock.take()
        #expect(sooner.map(\.delay) == [0, 1])
        sooner[0].work()
        #expect(
            !bench.store.hasPendingChanges && listed(archive).contains("tree/kept-back.txt")
                && listed(archive).contains("tree/more.txt"))
        // The old timers are overtaken: they do nothing.
        due.forEach { $0.work() }
        // After a write that worked, a failure counts from the beginning again.
        try write("last", to: bench.inside(archive, "tree/last.txt"))
        due = clock.take()
        #expect(chmod(box.url("locked").path, 0o555) == 0)
        due[0].work()
        #expect(clock.take().first?.delay == 30)
        #expect(chmod(box.url("locked").path, 0o755) == 0)
        #expect(bench.store.flushAll().isEmpty)
    }

    // MARK: New members next to an archive on another volume (A046), and the lock (A104)

    @Test func newMembersOfAnArchiveOnAnotherVolumeWaitNextToIt() throws {
        let archive = try makeZip()
        let scratch = bench.environment.scratch.url
        // "Another volume": everything outside the temporary folder's own.
        let opened = try bench.store.archive(at: archive)
        let asked = Collected<String>()
        bench.environment.volume = { path in
            asked.add(path)
            // Asked without the directory's lock: looking into the archive from here would
            // otherwise never return.
            _ = opened.isBusy
            return path == scratch.deletingLastPathComponent().path ? 1 : 2
        }
        // (Not kept beyond its closing: a writer holds on to its temporary file.)
        var writer: (any FileWriter)? = try bench.zip.write(bench.inside(archive, "tree/large.bin"))
        try writer?.write(Data(repeating: 7, count: 100_000))
        let folders = try FileManager.default.contentsOfDirectory(atPath: box.root.path).filter {
            $0.hasPrefix(".afm-spool-")
        }
        #expect(folders.count == 1 && asked.all.count == 2)
        let spool = box.url(folders.first ?? "missing")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: spool.path).filter { $0.hasSuffix(".zipdata") }.count
                == 1)
        #expect(mode(spool) == 0o700 && ScratchFolder.isOwnExternalName(spool.lastPathComponent))
        // Nothing of it in the temporary folder.
        #expect(
            ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []).filter {
                $0.hasSuffix(".zipdata")
            }.isEmpty)
        try writer?.close(attributes: FileAttributes())
        writer = nil
        // The volume is asked once per archive, not once per member.
        try write("small", to: bench.inside(archive, "tree/small.txt"))
        #expect(asked.all.count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: spool.path).count == 2)
        #expect(
            bench.store.flushAll().isEmpty && listed(archive).contains("tree/large.bin")
                && listed(archive).contains("tree/small.txt"))
        #expect(runTool("/usr/bin/unzip", ["-tq", archive.path]).status == 0)
        // Written, the members leave their folder, and the folder goes with the archive.
        #expect(try FileManager.default.contentsOfDirectory(atPath: spool.path).isEmpty)
        // A member that is given up leaves nothing behind either.
        try {
            let abandoned = try bench.zip.write(bench.inside(archive, "tree/abandoned.bin"))
            try abandoned.write(Data(repeating: 1, count: 10))
            abandoned.interrupt()
            #expect(throws: (any Error).self) { try abandoned.close(attributes: FileAttributes()) }
        }()
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: spool.path).isEmpty && !bench.store.hasPendingChanges)
    }

    @Test func aChangeAsksTheDiskBeforeItTakesTheLockOfTheDirectory() throws {
        // An archive that cannot be written says so, as before…
        let archive = try makeZip()
        #expect(chmod(archive.path, 0o444) == 0)
        #expect(throws: (any Error).self) { try bench.zip.createDirectory(at: bench.inside(archive, "tree/new")) }
        #expect(throws: (any Error).self) { try bench.zip.write(bench.inside(archive, "tree/new.txt")) }
        #expect(throws: (any Error).self) { try bench.zip.remove(bench.inside(archive, "tree/empty.txt")) }
        #expect(!bench.store.hasPendingChanges)
        #expect(chmod(archive.path, 0o644) == 0)
        // …and one that is no ZIP says that it cannot be changed, not that the file is locked.
        try bench.pack([box.url("tree")], to: box.url("plain.tar")) { $0.format = .tar }
        let tar = try bench.store.archive(at: box.url("plain.tar"))
        #expect(chmod(box.url("plain.tar").path, 0o444) == 0)
        do {
            try tar.makeDirectory("tree/new")
            Issue.record("a TAR was changed")
        } catch ArchiveError.readOnly {
        } catch {
            Issue.record("\(error)")
        }
        // Each kind of change, with the flag the kernel now passes; a set flag ends it.
        let flag = CancellationFlag()
        try bench.zip.createDirectory(at: bench.inside(archive, "tree/made"), cancellation: flag)
        try write("x", to: bench.inside(archive, "tree/made/x.txt"))
        try bench.zip.move(
            bench.inside(archive, "tree/made/x.txt"), to: bench.inside(archive, "tree/made/y.txt"), replacing: false,
            cancellation: flag)
        try bench.zip.setAttributes(
            FileAttributes(permissions: 0o600), of: bench.inside(archive, "tree/made/y.txt"), cancellation: flag)
        try bench.zip.remove(bench.inside(archive, "tree/empty.txt"), cancellation: flag)
        #expect(bench.store.flushAll().isEmpty)
        #expect(listed(archive).contains("tree/made/y.txt") && !listed(archive).contains("tree/empty.txt"))
        flag.cancel()
        #expect(throws: (any Error).self) {
            try bench.zip.remove(bench.inside(archive, "tree/made/y.txt"), cancellation: flag)
        }
        #expect(throws: (any Error).self) {
            try bench.zip.createDirectory(at: bench.inside(archive, "tree/never"), cancellation: flag)
        }
        #expect(!bench.store.hasPendingChanges)
        // A place that only passes through the archive scheme is the real place.
        let outside = bench.inside(archive).deletingLastPathComponent()
        #expect(bench.zip.realLocation(of: outside)?.isSameLocation(as: box.root) == true)
        #expect(bench.zip.realLocation(of: bench.inside(archive, "tree")) == nil)
        // The top of a location is told at once, and is where going up one by one ends.
        #expect(runTool("/usr/bin/zip", ["-q0", "outer.zip", "tree.zip"], in: box.root).status == 0)
        let nested = ArchiveURL.make(
            scheme: ArchiveURL.writableScheme, archive: bench.inside(box.url("outer.zip"), "tree.zip"),
            innerPath: "tree/sub/deep")
        for url in [bench.inside(archive), bench.inside(archive, "tree/sub/deep/x/y/z"), outside, nested, box.root] {
            var climbed = url
            while let parent = bench.zip.parent(of: climbed) { climbed = parent }
            #expect(bench.zip.root(of: url) == climbed, "\(url)")
        }
        #expect(bench.zip.root(of: bench.inside(archive, "tree/sub")).isSameLocation(as: box.root))
    }
}
