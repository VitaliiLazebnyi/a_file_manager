import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Stored deflate blocks of zeros without end: a stream that decompresses for as long as it
/// is read from, which no real archive does.
private final class EndlessDeflate: ByteStream {
    private var block = Data()
    let reads = SharedCounter()

    func read(upToCount count: Int) -> Data? {
        reads.add(1)
        // Not final, stored, 65535 bytes (and the complement of that number).
        if block.isEmpty { block = Data([0x00, 0xFF, 0xFF, 0x00, 0x00]) + Data(count: 0xFFFF) }
        let part = block.prefix(count)
        block = block.dropFirst(part.count)
        return Data(part)
    }

    func close() {}
}

/// Runs `body` on a thread of its own once `condition` holds, or after a long wait: the request
/// to stop comes from outside the thread that is stuck, and not from a queue that may stall.
private func signal(when condition: @escaping () -> Bool, _ body: @escaping () -> Void) {
    let thread = Thread {
        let deadline = Date().addingTimeInterval(60)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        body()
    }
    thread.start()
}

/// Waits for `condition`, up to a minute.
private func wait(for condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(60)
    while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    return condition()
}

private struct Refused: Error {}

private func mark(_ url: URL, with value: String) {
    #expect(value.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0) } == 0)
}

private func markOf(_ url: URL) -> String? {
    let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
    guard size > 0 else { return nil }
    var value = [UInt8](repeating: 0, count: size)
    let got = getxattr(url.path, "com.apple.quarantine", &value, size, 0, XATTR_NOFOLLOW)
    return got > 0 ? String(decoding: value.prefix(got), as: UTF8.self) : nil
}

/// A place that does not run through the archive: the archive scheme hands it to the file
/// system the archive lies on.
private func outside(_ root: URL, _ path: String) throws -> URL {
    var components = try #require(URLComponents(url: root, resolvingAgainstBaseURL: false))
    components.path = path
    return try #require(components.url)
}

/// The kernel's per-location capabilities, commit, cancellation and quarantine, as the
/// archives adopt them.
@Suite struct ArchiveAdoption {
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

    /// What the temporary folder of the archives holds.
    var scratchFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: bench.environment.scratch.url.path)) ?? [])
    }

    // MARK: Per location

    @Test func eachArchiveSaysWhatItCanDo() throws {
        let archive = try makeZip()
        let root = bench.inside(archive)
        // Not opened yet: the scheme's word. Opened: the archive's own.
        #expect(bench.zip.capabilities(for: root) == [.write, .deferredWrites])
        _ = try bench.store.archive(at: archive)
        #expect(bench.zip.capabilities(for: root.appending(name: "tree")) == [.write, .deferredWrites])
        #expect(
            bench.readOnly.capabilities(for: bench.inside(archive, "tree", scheme: ArchiveURL.readOnlyScheme)) == [])

        // A ZIP that lists a name twice is read-only like the formats that cannot be changed.
        let twice = box.url("twice.zip")
        let output = try OutputFile(creating: twice)
        let writer = ZipWriter(output, limits: .standard)
        for _ in 0..<2 {
            try writer.copyMember(.new(name: "same.txt", isDirectory: false, modified: Date(), permissions: 0o644))
        }
        try writer.finish()
        try output.close()
        _ = try bench.store.archive(at: twice)
        #expect(bench.zip.capabilities(for: bench.inside(twice)) == [])
        try bench.pack([box.url("tree")], to: box.url("plain.tar")) { $0.format = .tar }
        _ = try bench.store.archive(at: box.url("plain.tar"))
        #expect(bench.zip.capabilities(for: bench.inside(box.url("plain.tar"))) == [])

        // Nothing here continues a file.
        for provider in [bench.zip, bench.readOnly] {
            #expect(!provider.capabilities.contains(.append) && !provider.capabilities(for: root).contains(.append))
        }
        #expect(throws: FileSystemError.self) {
            _ = try bench.zip.append(to: root.appending(name: "tree/readme.txt"), at: nil)
        }
    }

    @Test func aPlaceOutsideTheArchiveAnswersForItsOwnFileSystem() throws {
        let archive = try makeZip()
        let root = bench.inside(archive)
        let local = try outside(root, box.url("elsewhere.txt").path)
        #expect(bench.zip.capabilities(for: local) == bench.fileSystems.capabilities(for: box.url("elsewhere.txt")))

        // On a server that can continue files, the archive scheme can too, for places outside.
        bench.memory.capabilitiesAt = { _ in [.write, .append, .deferredWrites] }
        _ = bench.memory.addFile("/store/log.txt", "start")
        let onServer = bench.memory.url("/store/tree.zip")
        let serverRoot = ArchiveURL.make(scheme: "zip", archive: onServer)
        let place = try outside(serverRoot, "/store/log.txt")
        #expect(bench.zip.capabilities(for: place) == [.write, .append, .deferredWrites])
        let appender = try bench.zip.append(to: place, at: nil)
        try appender.write(Data(" more".utf8))
        try appender.close(attributes: FileAttributes())
        #expect(bench.memory.contents("/store/log.txt") == "start more")
        try bench.zip.commit(place, cancellation: CancellationFlag())
        #expect(bench.memory.commits == ["/store/log.txt"])
    }

    @Test func anArchiveOnAServerThatCannotBeWrittenToCannotBeChanged() throws {
        let tree = try bench.makeTree()
        let onServer = bench.memory.url("/store/tree.zip")
        try bench.pack([tree], to: onServer)
        bench.store.close()
        bench.memory.capabilitiesAt = { _ in [] }
        let root = ArchiveURL.make(scheme: "zip", archive: onServer)
        _ = try bench.names(root)
        #expect(bench.zip.capabilities(for: root) == [])
        #expect(throws: ArchiveError.self) { _ = try bench.zip.write(root.appending(name: "new.txt")) }
        bench.memory.capabilitiesAt = { _ in [.write] }
        #expect(bench.zip.capabilities(for: root) == [.write, .deferredWrites])
        try write("late", to: root.appending(name: "late.txt"))
    }

    // MARK: Commit

    @Test func aCommitPutsWhatClosedWritersBroughtIntoTheArchiveFile() throws {
        // Nothing is written at a rename: what is kept back is up to the delay or to the commit.
        bench.environment.immediateWriteLimit = 0
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        try write(String(repeating: "new file ", count: 100_000), to: tree.appending(name: ".afm-1.tmp"))
        try bench.zip.move(tree.appending(name: ".afm-1.tmp"), to: tree.appending(name: "new.txt"), replacing: false)
        try bench.zip.remove(tree.appending(name: "empty.txt"))
        try bench.zip.setAttributes(FileAttributes(permissions: 0o600), of: tree.appending(name: "readme.txt"))
        try bench.zip.createDirectory(at: tree.appending(name: "made"))
        #expect(!listed(archive).contains("tree/new.txt") && listed(archive).contains("tree/empty.txt"))

        try bench.zip.commit(tree.appending(name: "anything"), cancellation: CancellationFlag())
        #expect(isSound(archive))
        #expect(try !bench.store.archive(at: archive).hasPendingChanges)
        let names = listed(archive)
        #expect(names.contains("tree/new.txt") && names.contains("tree/made/") && !names.contains("tree/empty.txt"))
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/new.txt"]).output.count == 900_000)
        #expect(runTool("/usr/bin/zipinfo", [archive.path, "tree/readme.txt"]).output.contains("-rw-------"))
        #expect(namesOnDisk(box.root).filter { $0.hasSuffix(".tmp") }.isEmpty)
        // Again with nothing to write: nothing happens.
        let before = FileSignature.of(archive.path)
        try bench.zip.commit(tree, cancellation: CancellationFlag())
        #expect(FileSignature.of(archive.path) == before)
    }

    @Test func anArchiveOnADriveIsWrittenAndLetGoOfBeforeTheDriveIsEjected() throws {
        bench.environment.immediateWriteLimit = 0
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        try bench.zip.createDirectory(at: tree.appending(name: "made"))
        // Something else on the drive, or another drive, is no reason to let go.
        bench.store.release(on: box.url("elsewhere"))
        #expect(bench.store.openArchive(at: archive) != nil)
        // An archive with changes still to write stays: going now would lose them.
        bench.store.release(on: box.root)
        #expect(bench.store.openArchive(at: archive) != nil && !listed(archive).contains("tree/made/"))
        // As the eject does it: written first, then let go of.
        try bench.store.bringUpToDate(box.root, cancellation: CancellationFlag())
        bench.store.release(on: box.root)
        #expect(
            bench.store.openArchive(at: archive) == nil && listed(archive).contains("tree/made/") && isSound(archive))
    }

    @Test func aFailedCommitKeepsEverythingForTheNextTry() throws {
        bench.environment.immediateWriteLimit = 0
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        try write("precious", to: tree.appending(name: "new.txt"))
        try bench.zip.remove(tree.appending(name: "empty.txt"))
        // The folder cannot be written to: no new file can be put next to the archive.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: box.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: box.root.path) }
        let before = FileSignature.of(archive.path)
        for _ in 0..<2 {
            #expect(throws: (any Error).self) { try bench.zip.commit(tree, cancellation: CancellationFlag()) }
            #expect(FileSignature.of(archive.path) == before && isSound(archive))
            #expect(try bench.store.archive(at: archive).hasPendingChanges)
            #expect(try bench.read(tree.appending(name: "new.txt")) == Data("precious".utf8))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: box.root.path)
        try bench.zip.commit(tree, cancellation: CancellationFlag())
        #expect(
            isSound(archive) && listed(archive).contains("tree/new.txt") && !listed(archive).contains("tree/empty.txt"))
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/new.txt"]).output == "precious")
    }

    @Test func aCommitReachesTheArchivesThatHoldTheArchive() throws {
        let tree = try bench.makeTree()
        try bench.pack([tree], to: box.url("inner.zip"))
        try bench.pack([box.url("inner.zip")], to: box.url("outer.zip"))
        bench.environment.immediateWriteLimit = 0
        let inner = ArchiveURL.make(scheme: "zip", archive: bench.inside(box.url("outer.zip"), "inner.zip"))
        #expect(bench.zip.capabilities(for: inner) == [.write, .deferredWrites])
        try write("deep", to: inner.appending(name: "tree").appending(name: "added.txt"))
        try bench.zip.commit(inner, cancellation: CancellationFlag())
        // Without anything else asking: the outer archive on the disk holds the changed inner one.
        #expect(runTool("/usr/bin/unzip", ["-q", "outer.zip", "-d", "x"], in: box.root).status == 0)
        #expect(listed(box.url("x/inner.zip")).contains("tree/added.txt") && isSound(box.url("outer.zip")))
    }

    @Test func anArchiveOnAServerIsCommittedThereToo() throws {
        let tree = try bench.makeTree()
        bench.memory.capabilitiesAt = { _ in [.write, .deferredWrites] }
        let onServer = bench.memory.url("/store/tree.zip")
        try bench.pack([tree], to: onServer)
        let root = ArchiveURL.make(scheme: "zip", archive: onServer)
        try write("late", to: root.appending(name: "late.txt"))
        #expect(bench.memory.commits.isEmpty)
        try bench.zip.commit(root, cancellation: CancellationFlag())
        // Uploaded, and then the server was told to make it durable.
        #expect(bench.memory.commits == ["/store/tree.zip"])
        #expect(try !bench.store.archive(at: onServer).hasPendingChanges)
        let reader = try bench.memory.read(onServer)
        var bytes = Data()
        while let block = try reader.read(upToCount: 1 << 20) { bytes.append(block) }
        try bytes.write(to: box.url("fetched.zip"))
        #expect(listed(box.url("fetched.zip")).contains("late.txt"))
        // A server that cannot make it durable fails the commit.
        bench.memory.commitFailure = Refused()
        #expect(throws: (any Error).self) { try bench.zip.commit(root, cancellation: CancellationFlag()) }
    }

    @Test func manySmallFilesDoNotWriteTheArchiveForEachOfThem() throws {
        bench.environment.immediateWriteLimit = 16 << 10
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        var files: Set<UInt64> = []
        for index in 0..<200 {
            let temporary = tree.appending(name: ".afm-\(index).tmp")
            try write("small file \(index)", to: temporary)
            try bench.zip.move(temporary, to: tree.appending(name: "small\(index).txt"), replacing: false)
            files.insert(FileSignature.of(archive.path)?.inode ?? 0)
        }
        // A new archive file stands for a write. The cost of writes at a rename is held to what
        // the files bring in (and a little), where it was 200 writes.
        #expect(files.count < 25, "\(files.count) writes")
        try bench.zip.commit(tree, cancellation: CancellationFlag())
        #expect(isSound(archive))
        let names = Set(listed(archive))
        #expect((0..<200).allSatisfy { names.contains("tree/small\($0).txt") })
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/small199.txt"]).output == "small file 199")
    }

    @Test func packAndDeleteSourcesWaitsForTheArchiveWhereItLies() throws {
        // The new archive lies inside another one, which keeps it back.
        let outer = try makeZip("outer.zip")
        bench.environment.immediateWriteLimit = 0
        try box.file("src/a.txt", "alpha")
        try box.file("src/b.txt", "beta")
        let result = try bench.pack(
            [box.url("src/a.txt"), box.url("src/b.txt")], to: bench.inside(outer, "tree/packed.tar")
        ) {
            $0.format = .tar
            $0.movesSources = true
        }
        #expect(result.completed.count == 2 && !box.exists("src/a.txt") && !box.exists("src/b.txt"))
        #expect(listed(outer).contains("tree/packed.tar") && isSound(outer))

        // On a server whose commit fails the sources stay and the pack fails.
        bench.memory.capabilitiesAt = { _ in [.write, .deferredWrites] }
        bench.memory.commitFailure = Refused()
        try box.file("src/c.txt", "gamma")
        var options = PackOptions()
        options.format = .tar
        options.movesSources = true
        let packer = Packer(
            fileSystems: bench.fileSystems, store: bench.store, monitor: bench.monitor, options: options)
        let failed = packer.run([try bench.item(box.url("src/c.txt"))], archive: bench.memory.url("/store/c.tar"))
        #expect(failed.failure != nil && failed.completed.isEmpty && box.exists("src/c.txt"))
        #expect(bench.memory.commits == ["/store/c.tar"])
    }

    @Test func thePackedOperandsAreDeselectedByTheNamesThePanelMarksThemWith() {
        // A branch or list view names its items by path.
        let notes = FileItem(url: URL(fileURLWithPath: "/A/notes.txt"), name: "sub/notes.txt", isDirectory: false)
        let todo = FileItem(url: URL(fileURLWithPath: "/A/todo.txt"), name: "other/todo.txt", isDirectory: false)
        let left = FileItem(url: URL(fileURLWithPath: "/A/left.txt"), name: "left.txt", isDirectory: false)
        #expect(
            ArchiveCommands.names(of: [notes, todo, left], packedAs: [notes.url, todo.url]) == [
                "sub/notes.txt", "other/todo.txt"
            ])
    }

    // MARK: Cancellation

    @Test func decompressionAndSkippingEndWhenTheRequestComes() throws {
        let source = EndlessDeflate()
        let control = StreamInterrupt()
        let stream = InflateStream(source, wrapping: .raw, control: control)
        #expect(try stream.read(upToCount: 1_000)?.count == 1_000)
        signal(when: { source.reads.value > 50 }) { control.set() }
        // Skipping through what never ends: it ends because the request comes from another thread.
        #expect(throws: ArchiveError.self) { try stream.skip(.max) }
        #expect(throws: ArchiveError.self) { _ = try stream.read(upToCount: 10) }
    }

    @Test func aReaderIsEndedFromAnotherThreadAndStaysEnded() throws {
        let source = EndlessDeflate()
        let reader = try ArchiveMemberReader { slot in
            let control = StreamInterrupt()
            slot.use(control)
            return InflateStream(source, wrapping: .raw, control: control)
        }
        #expect(try reader.read(upToCount: 100)?.count == 100)
        signal(when: { source.reads.value > 50 }) { reader.interrupt() }
        #expect(throws: ArchiveError.self) { try reader.seek(to: .max / 2) }
        #expect(throws: ArchiveError.self) { _ = try reader.read(upToCount: 10) }
        #expect(throws: ArchiveError.self) { try reader.seek(to: 0) }
        reader.close()
    }

    @Test func aChildProcessIsStoppedByTheRequest() throws {
        // Two hundred megabytes of zeros decompress to more than the pipe holds: bzip2 waits
        // for whoever reads, which here is nobody, until it is stopped.
        let zeros = box.url("zeros.bz2")
        #expect(
            runTool("/bin/sh", ["-c", "head -c 200000000 /dev/zero | /usr/bin/bzip2 -1 > '\(zeros.path)'"]).status == 0)
        let control = StreamInterrupt()
        let stream = try ProcessStream(Tool.bzip2, ["-dc", "--", zeros.path], control: control)
        defer { stream.close() }
        func running() -> Bool { runTool("/usr/bin/pgrep", ["-f", "bzip2 -dc -- \(zeros.path)"]).status == 0 }
        #expect(wait(for: running))
        control.set()
        #expect(wait(for: { !running() }))
        #expect(throws: ArchiveError.self) { _ = try stream.read(upToCount: 10) }
    }

    @Test func aMemberReadFromAStreamEndsWhenInterruptedAndLeavesTheNextReadsAlone() throws {
        bench.environment.materializeLimit = 0
        let tree = try bench.makeTree()
        let archive = box.url("tree.tar.gz")
        try bench.pack([tree], to: archive) { $0.format = .compressedTar(.gzip) }
        let root = bench.inside(archive, "tree", scheme: ArchiveURL.readOnlyScheme)
        let opened = try bench.store.archive(at: archive)
        #expect(!opened.allowsParallelReads)
        let big = try Data(contentsOf: tree.appendingPathComponent("big.log"))
        let readme = try Data(contentsOf: tree.appendingPathComponent("readme.txt"))
        let flag = CancellationFlag()

        // Interrupted in the middle of a member: ended, and so is everything after.
        let first = try bench.readOnly.read(root.appending(name: "big.log"), cancellation: flag)
        #expect(try first.read(upToCount: 1_000)?.count == 1_000)
        first.interrupt()
        #expect(throws: ArchiveError.self) { _ = try first.read(upToCount: 10) }
        #expect(throws: ArchiveError.self) { try first.seek(to: 0) }
        first.close()

        // It was not kept for the next read, which starts the stream again and gets everything.
        let starts = opened.streamStarts
        #expect(try bench.read(root.appending(name: "big.log")) == big)
        #expect(opened.streamStarts == starts + 1)

        // A reader that finished is kept for the one after it; interrupting the finished one
        // later does not end the other's read.
        let done = try bench.readOnly.read(root.appending(name: "big.log"), cancellation: flag)
        while try done.read(upToCount: 1 << 20) != nil {}
        done.close()
        let starts2 = opened.streamStarts
        let next = try bench.readOnly.read(root.appending(name: "readme.txt"), cancellation: flag)
        #expect(opened.streamStarts == starts2)
        done.interrupt()
        var bytes = Data()
        while let block = try next.read(upToCount: 1 << 16) { bytes.append(block) }
        next.close()
        #expect(bytes == readme)

        // A flag that is set stops the opening of a member.
        flag.cancel()
        #expect(throws: (any Error).self) {
            _ = try bench.readOnly.read(root.appending(name: "readme.txt"), cancellation: flag)
        }
    }

    @Test(arguments: [
        ArchiveFormat.compressedTar(.gzip), .compressedTar(.xz), .compressedTar(.bzip2), .compressedFile(.bzip2)
    ])
    func openingAStreamArchiveCanBeAbandoned(format: ArchiveFormat) throws {
        // Materialising, or counting the size of a file that does not say it, are the long parts.
        bench.environment.materializeLimit = format == .compressedFile(.bzip2) ? 0 : 1 << 30
        let tree = try bench.makeTree()
        let archive = box.url("tree." + format.defaultExtension)
        if case .compressedFile = format {
            try bench.pack([tree.appendingPathComponent("big.log")], to: archive) { $0.format = format }
        } else {
            try bench.pack([tree], to: archive) { $0.format = format }
        }
        let flag = CancellationFlag()
        flag.cancel()
        #expect(throws: ArchiveError.self) { _ = try bench.store.archive(at: archive, cancellation: flag) }
        // Nothing half-open is kept: not the archive, not a failure to open it, not a temporary file.
        #expect(bench.store.openArchive(at: archive) == nil && scratchFiles.isEmpty)
        let root = bench.inside(archive, scheme: ArchiveURL.readOnlyScheme)
        #expect(throws: ArchiveError.self) { _ = try bench.readOnly.list(root, showHidden: true, cancellation: flag) }
        #expect(throws: ArchiveError.self) {
            try bench.readOnly.list(root, showHidden: true, cancellation: flag) { _ in true }
        }
        #expect(bench.readOnly.item(at: root, cancellation: flag) == nil)
        #expect(throws: ArchiveError.self) { _ = try bench.readOnly.read(root, cancellation: flag) }
        #expect(try !bench.names(root).isEmpty)
        #expect(bench.store.openArchive(at: archive) != nil)
    }

    @Test func fetchingAnArchiveFromAServerCanBeAbandoned() throws {
        let tree = try bench.makeTree()
        let onServer = bench.memory.url("/store/tree.zip")
        try bench.pack([tree], to: onServer)
        bench.store.close()
        bench.memory.stallsReads = true
        let flag = CancellationFlag()
        // The server never answers; the request comes from a thread of its own.
        signal(when: { true }) { flag.cancel() }
        let root = ArchiveURL.make(scheme: "zip", archive: onServer)
        #expect(throws: ArchiveError.self) { _ = try bench.zip.list(root, showHidden: true, cancellation: flag) }
        #expect(bench.store.openArchive(at: onServer) == nil && scratchFiles.isEmpty)
        bench.memory.stallsReads = false
        bench.memory.releaseStalls()
        #expect(try bench.names(root) == ["tree"])
    }

    @Test func callsOutsideTheArchiveGoToTheFileSystemWithTheFlag() throws {
        let tree = try bench.makeTree()
        let onServer = bench.memory.url("/store/tree.zip")
        try bench.pack([tree], to: onServer)
        let root = ArchiveURL.make(scheme: "zip", archive: onServer)
        _ = bench.memory.addFile("/store/log.txt", String(repeating: "x", count: 1_000))
        let place = try outside(root, "/store/log.txt")
        #expect(bench.zip.item(at: place, cancellation: CancellationFlag())?.size == 1_000)
        #expect(
            try bench.zip.list(try outside(root, "/store"), showHidden: true, cancellation: CancellationFlag()).map(
                \.name
            ).sorted()
                == ["log.txt", "tree.zip"])
        let cancelled = CancellationFlag()
        cancelled.cancel()
        #expect(bench.zip.item(at: place, cancellation: cancelled) == nil)

        // The reader and writer are the other file system's own, and are ended by its interrupt.
        bench.memory.stallsReads = true
        let reader = try bench.zip.read(place, cancellation: CancellationFlag())
        let tie = CancellationFlag()
        let held = tie.interrupting(reader)
        signal(when: { true }) { tie.cancel() }
        #expect(throws: MemoryFileSystem.Interrupted.self) { _ = try reader.read(upToCount: 10) }
        withExtendedLifetime(held) {}
        bench.memory.stallsReads = false
    }

    @Test func aMemberWriterEndsWhenInterrupted() throws {
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        let flag = CancellationFlag()
        let writer = try bench.zip.write(tree.appending(name: "never.txt"), cancellation: flag)
        try writer.write(Data("some".utf8))
        writer.interrupt()
        #expect(throws: ArchiveError.self) { try writer.write(Data("more".utf8)) }
        #expect(throws: ArchiveError.self) { try writer.close(attributes: FileAttributes()) }
        // Nothing joined the archive, and it is not held open for a writer that is gone.
        #expect(try bench.names(tree).contains("never.txt") == false)
        #expect(try !bench.store.archive(at: archive).isBusy)
    }

    // MARK: Quarantine

    @Test func membersCarryTheMarkOfTheirArchiveSoThatACopyCanPassItOn() throws {
        let archive = try makeZip()
        let value = "0083;65f0a1b2;Safari;F643CD5F-6071-46AB-83AB-390BA944DEC5"
        mark(archive, with: value)
        let member = bench.inside(archive, "tree/readme.txt")
        #expect(bench.zip.quarantine(of: member) == Data(value.utf8))
        #expect(
            bench.readOnly.quarantine(of: bench.inside(archive, "tree", scheme: ArchiveURL.readOnlyScheme))
                == Data(value.utf8))
        // Read once for the open archive.
        removexattr(archive.path, "com.apple.quarantine", 0)
        #expect(bench.zip.quarantine(of: member) == Data(value.utf8))
        // What Unpack puts on the files is the same value: files are not marked twice differently.
        let result = try bench.unpack(archive, to: box.url("out"))
        #expect(result.problems.isEmpty && markOf(box.url("out/tree/readme.txt")) == value)

        // An archive inside an archive has the outermost file's mark; one without has none.
        try bench.pack([box.url("tree")], to: box.url("inner.tar")) { $0.format = .tar }
        try bench.pack([box.url("inner.tar")], to: box.url("outer.zip"))
        mark(box.url("outer.zip"), with: value)
        let inner = bench.inside(box.url("outer.zip"), "inner.tar", scheme: ArchiveURL.readOnlyScheme)
        #expect(bench.readOnly.quarantine(of: inner.appending(name: "tree")) == Data(value.utf8))
        #expect(bench.zip.quarantine(of: bench.inside(try makeZip("clean.zip"), "tree")) == nil)
    }

    @Test func theMarkOfAnArchiveOnAnotherFileSystemIsThatFileSystemsWord() throws {
        let tree = try bench.makeTree()
        let onServer = bench.memory.url("/store/tree.zip")
        try bench.pack([tree], to: onServer)
        bench.memory.quarantineValue = Data("0081;downloaded".utf8)
        let root = ArchiveURL.make(scheme: "zip", archive: onServer)
        #expect(bench.zip.quarantine(of: root.appending(name: "tree")) == Data("0081;downloaded".utf8))
        // For places outside the archive the file system is asked, and marked.
        let place = try outside(root, "/store/other.txt")
        #expect(bench.zip.quarantine(of: place) == Data("0081;downloaded".utf8))
        _ = bench.memory.addFile("/store/other.txt", "x")
        try bench.zip.setQuarantine(Data("0081;mark".utf8), of: place)
        #expect(bench.memory.quarantineMarks == ["/store/other.txt": Data("0081;mark".utf8)])
        // Inside the archive nothing can carry one.
        try bench.zip.setQuarantine(Data("0081;mark".utf8), of: root.appending(name: "tree"))
        #expect(bench.memory.quarantineMarks.count == 1)
    }
}
