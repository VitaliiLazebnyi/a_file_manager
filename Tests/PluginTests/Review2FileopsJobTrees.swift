import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// Sources on a server, stale temporary files, very deep trees and many small files.
@Suite
internal struct Review2FileopsJobTrees {
    /// A scratch folder of its own for each test.
    internal let box: Sandbox

    /// A fresh scratch folder.
    internal init() throws {
        box = try Sandbox()
    }

    // F048
    /// A source on a server is looked up once per file, not three times.
    @Test
    internal func aSourceOnAServerIsAskedAboutOnceNotThreeTimes() throws {
        // A file system that counts how often each item is looked up.
        // Unchecked: what it records is guarded by `lock`.
        final class Counting: FileSystemProvider, @unchecked Sendable {
            let base = MemoryFileSystem(scheme: "counted")
            var scheme: String { base.scheme }
            var capabilities: FileSystemCapabilities { [.write] }
            private let lock = NSLock()
            private var asked: [String: Int] = [:]

            func lookups(_ path: String) -> Int { lock.withLock { asked[path] ?? 0 } }
            func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
                try base.list(directory, showHidden: showHidden)
            }
            func item(at url: URL) -> FileItem? {
                lock.withLock { asked[url.path, default: 0] += 1 }
                return base.item(at: url)
            }
            func parent(of directory: URL) -> URL? { base.parent(of: directory) }
            func read(_ url: URL) throws -> any FileReader { try base.read(url) }
            func createDirectory(at url: URL) { base.createDirectory(at: url) }
            func write(_ url: URL) throws -> any FileWriter { try base.write(url) }
            func remove(_ url: URL) throws { try base.remove(url) }
            func move(_ source: URL, to destination: URL, replacing: Bool) throws {
                try base.move(source, to: destination, replacing: replacing)
            }
            func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
                try base.copy(source, to: destination, progress: progress)
            }

            deinit {
                // Nothing to release.
            }
        }
        let fileSystems = FileSystemRegistry()
        let server = Counting()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(server)
        server.base.addFile("/s/a.txt", "a")
        server.base.addFile("/s/b.txt", "b")
        try box.folder("t")
        let result = Answers()
            .run(
                .copy,
                [server.base.url("/s/a.txt"), server.base.url("/s/b.txt")],
                to: TargetSpec(directory: box.url("t")),
                fileSystems: fileSystems
            )
        #expect(result.completed.count == 2 && box.read("t/b.txt") == "b")
        #expect(server.lookups("/s/a.txt") == 1 && server.lookups("/s/b.txt") == 1)
    }

    /// Only temporary files of the job's own pattern that are old enough are swept away.
    @Test
    internal func oldTemporaryFilesAreSweptAndNothingElse() throws {
        let stale = ".afm-\(UUID().uuidString).tmp"
        try box.file("t/\(stale)", "half a copy")
        try box.file("t/.afm-not-a-uuid.tmp", "mine")
        try box.file("t/keep.txt", "keep")
        try box.folder("t/.afm-\(UUID().uuidString).tmp")
        #expect(
            FileJob.isTemporaryName(stale) && !FileJob.isTemporaryName(".afm-not-a-uuid.tmp")
                && !FileJob.isTemporaryName("a.tmp")
        )
        // Fresh: it may belong to a copy that is running.
        FileJob.sweepStaleTemporaries(in: box.url("t"))
        #expect(box.exists("t/\(stale)"))
        FileJob.sweepStaleTemporaries(in: box.url("t"), now: Date().addingTimeInterval(FileJob.staleTemporaryAge + 60))
        #expect(!box.exists("t/\(stale)"))
        #expect(
            namesOnDisk(box.url("t")).count == 3 && box.read("t/keep.txt") == "keep"
                && box.read("t/.afm-not-a-uuid.tmp") == "mine"
        )
    }

    /// A tree as deep as the length of a path allows is moved, copied level by level and deleted.
    @Test
    internal func aTreeAsDeepAsPathsAllowIsCopiedAndDeleted() throws {
        let (fileSystems, _) = makeFileSystems()
        // As deep as the system's limit on the length of a path lets a tree be.
        var deep = try box.folder("s")
        var levels = 0
        while deep.path.utf8.count < 900 {
            deep = deep.appendingPathComponent("d")
            levels += 1
        }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try "bottom".write(to: deep.appendingPathComponent("b"), atomically: false, encoding: .utf8)
        try box.folder("t/x")
        let answers = Answers()
        let result = answers.run(
            .move,
            [box.url("s")],
            to: TargetSpec(directory: box.url("t/x")),
            fileSystems: fileSystems
        )
        #expect(levels > 300 && result.completed.count == 1 && answers.errors.isEmpty && !box.exists("s"))
        // Copied level by level (a folder with a filter is never moved whole), then deleted.
        let copy = FileJob(
            kind: .copy,
            sources: [box.url("t/x/s")],
            target: TargetSpec(directory: box.root),
            fileSystems: fileSystems
        )
        copy.options.filter = CopyFilter("*")
        copy.delegate = answers
        #expect(copy.run().completed.count == 1 && answers.errors.isEmpty)
        #expect((try? String(contentsOf: URL(fileURLWithPath: deep.path + "/b"), encoding: .utf8)) == "bottom")
        let delete = answers.run(
            .delete(toTrash: false),
            [box.url("s"), box.url("t")],
            to: nil,
            fileSystems: fileSystems
        )
        #expect(delete.completed.count == 2 && answers.errors.isEmpty && namesOnDisk(box.root).isEmpty)
    }

    /// What lies deeper than the depth limit is reported and left, and everything above it is copied or deleted.
    @Test
    internal func aTreeDeeperThanTheLimitIsReportedNotEntered() {
        let (fileSystems, memory) = makeFileSystems()
        let limit = 12
        var path = "/deep"
        for _ in 0..<limit + 8 { path += "/d" }
        memory.addFile(path + "/bottom.txt", "bottom")
        memory.addFile("/deep/top.txt", "top")
        memory.addDirectory("/t")
        let copying = Review2Replies()
        let job = FileJob(
            kind: .copy,
            sources: [memory.url("/deep")],
            target: TargetSpec(directory: memory.url("/t")),
            fileSystems: fileSystems
        )
        job.depthLimit = limit
        job.delegate = copying
        let result = job.run()
        // What lies deeper than the limit is reported, not entered; everything above is copied.
        #expect(copying.errors.count == 1 && copying.errors[0].contains("nested too deep") && result.completed.isEmpty)
        #expect(memory.contents("/t/deep/top.txt") == "top")
        let deleting = Review2Replies()
        let delete = FileJob(kind: .delete(toTrash: false), sources: [memory.url("/deep")], fileSystems: fileSystems)
        delete.depthLimit = limit
        delete.delegate = deleting
        #expect(
            delete.run().completed.isEmpty && deleting.errors.count == 1
                && memory.contents(path + "/bottom.txt") == "bottom"
        )
        #expect(!memory.exists("/deep/top.txt"))
    }

    /// Sources from the local disk and from memory in one list are all copied.
    @Test
    internal func aListOfSourcesFromManyFoldersIsLookedAtFolderByFolder() throws {
        let (fileSystems, memory) = makeFileSystems()
        // One source on the local disk, one in memory (which is not a fast local disk): no
        // pool, and the copy still works.
        try box.file("s/a.txt", "a")
        memory.addFile("/m/b.txt", "b")
        try box.folder("t")
        let result = Answers()
            .run(
                .copy,
                [box.url("s/a.txt"), memory.url("/m/b.txt")],
                to: TargetSpec(directory: box.url("t")),
                fileSystems: fileSystems
            )
        #expect(result.completed.count == 2 && namesOnDisk(box.url("t")) == ["a.txt", "b.txt"])
    }

    /// Many small files copied through the pool all arrive, and the progress reports never go backwards.
    @Test
    internal func manySmallFilesStillArriveThroughThePoolWithOrderedProgress() throws {
        let (fileSystems, _) = makeFileSystems()
        for index in 0..<300 { try box.file("s/f\(index).txt", "contents \(index)") }
        try box.folder("t")
        let answers = Answers()
        let job = FileJob(
            kind: .copy,
            sources: [box.url("s")],
            target: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems
        )
        job.delegate = answers
        let result = job.run()
        #expect(
            result.completed.count == 1 && namesOnDisk(box.url("t/s")).count == 300
                && box.read("t/s/f299.txt") == "contents 299"
        )
        // The reports come one at a time and never go backwards.
        let done = answers.progress.map(\.itemsDone)
        #expect(
            done == done.sorted() && answers.progress.last?.itemsDone == 301 && answers.progress.last?.itemsTotal == 301
        )
    }
}
