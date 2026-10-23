import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// Second pass of review round 2 for the file-operation engine, first part: every changing call of a job can be
/// ended (F021), a folder that is about to be filled is made exclusively (L029), and pending writes are flushed
/// before a file is used (A044).
@Suite
internal struct Review2FileopsP2JobTests {
    /// The local disk, with a moment to step in right before a folder is made: what somebody
    /// else does between a job's look at a name and its use of it.
    ///
    /// Unchecked: its switches are set by the test before use, and it is used from one thread at a
    /// time.
    private final class RacingFileSystem: FileSystemProvider, @unchecked Sendable {
        let local = LocalFileSystem()
        var scheme: String { local.scheme }
        var capabilities: FileSystemCapabilities { local.capabilities }
        var readsRootedPaths: Bool { local.readsRootedPaths }
        var beforeCreating: ((URL) -> Void)?

        func capabilities(for url: URL) -> FileSystemCapabilities { local.capabilities(for: url) }
        func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
            try local.list(directory, showHidden: showHidden)
        }
        func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
            try local.list(directory, showHidden: showHidden, cancellation: cancellation)
        }
        func item(at url: URL) -> FileItem? { local.item(at: url) }
        func parent(of directory: URL) -> URL? { local.parent(of: directory) }
        func read(_ url: URL) throws -> any FileReader { try local.read(url) }
        func write(_ url: URL) throws -> any FileWriter { try local.write(url) }
        func remove(_ url: URL) throws { try local.remove(url) }
        func move(_ source: URL, to destination: URL, replacing: Bool) throws {
            try local.move(source, to: destination, replacing: replacing)
        }
        func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
            try local.copy(source, to: destination, progress: progress)
        }
        func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
            try local.setAttributes(attributes, of: url)
        }
        func copyMetadata(from source: URL, to destination: URL) throws {
            try local.copyMetadata(from: source, to: destination)
        }
        func displayPath(_ url: URL) -> String { local.displayPath(url) }
        func location(from text: String) -> URL? { local.location(from: text) }
        func volume(of url: URL) -> VolumeInfo? { local.volume(of: url) }
        func createDirectory(at url: URL) throws {
            beforeCreating?(url)
            try local.createDirectory(at: url)
        }
        func createDirectory(at url: URL, exclusive: Bool) throws {
            beforeCreating?(url)
            try local.createDirectory(at: url, exclusive: exclusive)
        }
        func createDirectory(at url: URL, exclusive: Bool, cancellation: CancellationFlag) throws {
            beforeCreating?(url)
            try local.createDirectory(at: url, exclusive: exclusive, cancellation: cancellation)
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The sandbox, the file systems and the jobs the tests share.
    private let bench: P2JobBench

    /// The temporary folder on the local disk.
    private var box: Sandbox { bench.box }
    /// Knows the local disk, `memory` and `probe`.
    private var fileSystems: FileSystemRegistry { bench.fileSystems }
    /// A memory file system with the scheme `mem`.
    private var memory: MemoryFileSystem { bench.memory }
    /// A memory file system that notes how it is called.
    private var probe: P2ProbeFileSystem { bench.probe }

    /// A fresh sandbox and file systems.
    internal init() throws {
        bench = try P2JobBench()
    }

    /// A job of `kind` over `sources` into `directory`, answered by `replies`.
    private func job(
        _ kind: JobKind,
        _ sources: [URL],
        to directory: URL?,
        replies: P2Replies,
        cancellation: CancellationFlag = CancellationFlag()
    ) -> FileJob {
        bench.job(kind, sources, to: directory, replies: replies, cancellation: cancellation)
    }

    // MARK: F021 — every changing call of a job can be ended

    /// Every call of a copy, a move and a deletion that changes something reaches the file system with the job's
    /// flag.
    @Test
    internal func everyChangingCallOfAJobCarriesTheJobsFlag() {
        memory.quarantineValue = Data("0083;5f000000;Test;".utf8)
        memory.addFile("/s/dir/sub/f.txt", "contents")
        memory.addFile("/s/dir/g.txt", "more")
        probe.base.addDirectory("/t")
        probe.base.addFile("/t/old.txt", "old")
        let replies = P2Replies()
        // A move between two file systems: folders are made, files written and renamed into
        // place, marked, given their attributes; then a rename inside the target.
        var result = job(.move, [memory.url("/s/dir")], to: probe.base.url("/t"), replies: replies).run()
        #expect(result.completed.count == 1 && replies.errors.isEmpty)
        #expect(probe.base.contents("/t/dir/sub/f.txt") == "contents" && !memory.exists("/s/dir"))
        result = job(.move, [probe.base.url("/t/old.txt")], to: probe.base.url("/t/dir"), replies: replies).run()
        #expect(result.completed.count == 1 && probe.base.contents("/t/dir/old.txt") == "old")
        result = job(.delete(toTrash: false), [probe.base.url("/t/dir")], to: nil, replies: replies).run()
        #expect(result.completed.count == 1 && !probe.base.exists("/t/dir"))
        // Nothing reached the file system without a flag…
        #expect(probe.unflagged.isEmpty, "\(probe.unflagged)")
        // …and all the kinds of call were made.
        #expect(
            Set(probe.flagged)
                .isSuperset(of: [
                    "createDirectory", "move", "setQuarantine", "setAttributes", "copyMetadata", "remove"
                ])
        )
    }

    /// A removal that waits for a server ends when the job is cancelled, and nothing is removed.
    @Test
    internal func aRemovalThatWaitsForAServerEndsWhenTheJobIsCancelled() {
        for index in 0..<5 { probe.base.addFile("/gone/f\(index).txt") }
        probe.stallsRemovals = true
        let flag = CancellationFlag()
        // From a thread of its own: the removal is waiting on this one.
        probe.onStalledRemoval = { Thread.detachNewThread { flag.cancel() } }
        let replies = P2Replies()
        let job = job(
            .delete(toTrash: false),
            [probe.base.url("/gone")],
            to: nil,
            replies: replies,
            cancellation: flag
        )
        // Written by the other thread before the wait ends, read here after it.
        nonisolated(unsafe) var result = JobResult()
        let ended = P2Wait.finishes(rescue: { flag.cancel() }, work: { result = job.run() })
        #expect(ended && result.cancelled && replies.errors.isEmpty)
        // Nothing was removed: the one removal that had begun was ended, not carried out.
        #expect(probe.base.allPaths.filter { $0.hasPrefix("/gone/") }.count == 5)
    }

    /// Tidying up after a cancel still takes the half-written file away, with a flag of its own.
    @Test
    internal func tidyingUpAfterACancelStillTakesTheTemporaryFileAway() {
        let flaky = FlakyFileSystem()
        fileSystems.register(flaky)
        flaky.base.addFile("/s/big.bin", "0123456789abcdef")
        probe.base.addDirectory("/t")
        let flag = CancellationFlag()
        flaky.afterFirstBlock = { flag.cancel() }
        let replies = P2Replies()
        let result = job(
            .copy,
            [flaky.base.url("/s/big.bin")],
            to: probe.base.url("/t"),
            replies: replies,
            cancellation: flag
        )
        .run()
        #expect(result.cancelled)
        // The job's flag is set by the time the half-written file is removed; the removal is
        // made with a flag of its own, or the file system would have refused it.
        #expect(probe.base.allPaths == ["/t"], "\(probe.base.allPaths)")
        #expect(probe.unflagged.isEmpty)
    }

    /// A server that does not answer the tidying up after a cancel is given up on, and the job ends.
    @Test
    internal func aServerThatDoesNotAnswerTheTidyingUpIsGivenUpOn() {
        let flaky = FlakyFileSystem()
        fileSystems.register(flaky)
        flaky.base.addFile("/s/big.bin", "0123456789abcdef")
        probe.base.addDirectory("/t")
        let flag = CancellationFlag()
        flaky.afterFirstBlock = {
            // From now on the target does not answer removals.
            probe.stallsRemovals = true
            flag.cancel()
        }
        // (Kept here: the job holds whoever answers its questions weakly.)
        let replies = P2Replies()
        let job = job(
            .copy,
            [flaky.base.url("/s/big.bin")],
            to: probe.base.url("/t"),
            replies: replies,
            cancellation: flag
        )
        job.cleanupPatience = 0.2
        // Written by the other thread before the wait ends, read here after it.
        nonisolated(unsafe) var result = JobResult()
        // The patience is short so that the test is; the test does not depend on how short.
        let ended = P2Wait.finishes(rescue: nil) { result = job.run() }
        #expect(ended)
        #expect(result.cancelled)
    }

    // MARK: L029 — a folder that is about to be filled is made exclusively

    /// A link put in place of a new target folder, between the job's look and its making the folder, is not
    /// copied through.
    @Test
    internal func aLinkPutInPlaceOfANewTargetFolderIsNotCopiedThrough() throws {
        let registry = FileSystemRegistry()
        let racing = RacingFileSystem()
        registry.register(racing)
        try box.file("s/dir/a.txt", "a")
        try box.folder("t")
        try box.folder("elsewhere")
        let planted = box.url("t/dir")
        // Between the job's look ("nothing there") and its making the folder, a link appears.
        racing.beforeCreating = { url in
            guard url.lastPathComponent == "dir", !FileManager.default.fileExists(atPath: planted.path) else {
                return
            }
            try? FileManager.default.createSymbolicLink(at: planted, withDestinationURL: box.url("elsewhere"))
        }
        let replies = P2Replies()
        let job = FileJob(
            kind: .copy,
            sources: [box.url("s/dir")],
            target: TargetSpec(directory: box.url("t")),
            fileSystems: registry
        )
        job.delegate = replies
        let result = job.run()
        #expect(namesOnDisk(box.url("elsewhere")).isEmpty)
        #expect(result.completed.isEmpty && replies.errors.count == 1 && box.read("s/dir/a.txt") == "a")
    }

    // MARK: A044 — pending writes are flushed before a file is used

    /// A file is brought up to date by its file system's flusher before it is copied, moved or deleted.
    @Test
    internal func aFileIsBroughtUpToDateBeforeItIsCopiedMovedOrDeleted() {
        let lock = NSLock()
        // Guarded by `lock`.
        nonisolated(unsafe) var flushed: [String] = []
        let flushedFiles = memory
        fileSystems.addFlusher { url, _ in
            lock.withLock { flushed.append(url.path) }
            // What a plugin with changes still in memory does: it writes them now.
            if url.path == "/s/late.zip" { _ = flushedFiles.addFile("/s/late.zip", "written just in time") }
        }
        memory.addFile("/s/late.zip", "stale")
        memory.addFile("/s/dir/inner.txt", "inner")
        memory.addDirectory("/t")
        memory.addDirectory("/u")
        let replies = P2Replies()
        _ = job(.copy, [memory.url("/s/late.zip"), memory.url("/s/dir")], to: memory.url("/t"), replies: replies).run()
        #expect(memory.contents("/t/late.zip") == "written just in time")
        #expect(Set(lock.withLock { flushed }) == ["/s/late.zip", "/s/dir/inner.txt"])
        lock.withLock { flushed = [] }
        _ = job(.move, [memory.url("/t/late.zip")], to: memory.url("/u"), replies: replies).run()
        _ = job(.delete(toTrash: false), [memory.url("/t/dir")], to: nil, replies: replies).run()
        // Files only: a folder holds no changes of its own.
        #expect(Set(lock.withLock { flushed }) == ["/t/late.zip", "/t/dir/inner.txt"])
        #expect(replies.errors.isEmpty)
    }

    /// A file that cannot be brought up to date is neither moved nor deleted, and the error is told.
    @Test
    internal func aFileThatCannotBeBroughtUpToDateIsLeftAlone() {
        struct NotWritten: LocalizedError {
            var errorDescription: String? { "The archive could not be written." }
        }
        fileSystems.addFlusher { url, _ in
            if url.lastPathComponent == "open.zip" { throw NotWritten() }
        }
        memory.addFile("/s/open.zip", "what is on disk")
        memory.addFile("/s/other.txt", "other")
        memory.addDirectory("/t")
        let replies = P2Replies()
        var result = job(
            .move,
            [memory.url("/s/open.zip"), memory.url("/s/other.txt")],
            to: memory.url("/t"),
            replies: replies
        )
        .run()
        #expect(
            result.completed == [memory.url("/s/other.txt")] && replies.errors == ["The archive could not be written."]
        )
        #expect(memory.contents("/s/open.zip") == "what is on disk" && !memory.exists("/t/open.zip"))
        result = job(.delete(toTrash: false), [memory.url("/s/open.zip")], to: nil, replies: replies).run()
        #expect(result.completed.isEmpty && memory.exists("/s/open.zip") && replies.errors.count == 2)
    }
}
