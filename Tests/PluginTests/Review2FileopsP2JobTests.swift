import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileOperationsPlugin

// Second pass of review round 2 for the file-operation engine: what the first pass left open
// (F021, F046, F052, F041, F047), what other areas asked for (A041 read order, A044 pending
// writes, N009 origin marks, L029 exclusive folders) and the provider-level `realLocation`.

/// A file system over memory that notes how it is called, and can be made to misbehave the
/// way a server does.
///
/// Every call is forwarded to `base`. Unchecked: what it records is guarded by `lock`; its switches
/// are set by the test before use.
internal final class P2ProbeFileSystem: FileSystemProvider, @unchecked Sendable {
    /// Unchecked: used by one thread at a time, as the protocol allows.
    private final class FailingWriter: FileWriter, @unchecked Sendable {
        let inner: any FileWriter
        let failure: any Error
        var wrote = false
        init(_ inner: any FileWriter, _ failure: any Error) { (self.inner, self.failure) = (inner, failure) }
        func write(_ data: Data) throws {
            wrote = true
            try inner.write(data)
        }
        func close(attributes: FileAttributes) throws {
            try inner.close(attributes: attributes)
            if wrote {
                wrote = false
                throw failure
            }
        }
    }

    internal let base: MemoryFileSystem
    internal var scheme: String { base.scheme }
    internal var capabilities: FileSystemCapabilities { base.capabilities }
    internal let readsRootedPaths = true

    private let lock = NSLock()
    private var withFlag: [String] = []
    private var withoutFlag: [String] = []
    private var readPaths: [String] = []
    private var listedPaths: [String] = []
    private var shown = 0
    /// What `readOrder(of:)` answers; nil leaves the order.
    internal var order: (([URL]) -> [URL])?
    /// When set, `setQuarantine` fails with it.
    internal var quarantineFailure: (any Error)?
    /// When set, every writer fails with it when it is closed with contents.
    internal var writeFailure: (any Error)?
    /// A removal that was given a flag does not come back until the flag is set.
    internal var stallsRemovals = false
    /// Called when such a removal starts to wait.
    internal var onStalledRemoval: (() -> Void)?

    /// The changing calls that came with a cancellation flag, and those that came without.
    internal var flagged: [String] { lock.withLock { withFlag } }
    internal var unflagged: [String] { lock.withLock { withoutFlag } }
    /// The paths that were opened for reading, in that order.
    internal var reads: [String] { lock.withLock { readPaths } }
    internal var displayed: Int { lock.withLock { shown } }

    internal init(scheme: String = "probe") {
        base = MemoryFileSystem(scheme: scheme)
    }
    internal func listings(of path: String) -> Int { lock.withLock { listedPaths.filter { $0 == path }.count } }

    private func note(_ call: String, flag: CancellationFlag?) throws {
        lock.withLock { flag == nil ? withoutFlag.append(call) : withFlag.append(call) }
        if flag?.isCancelled == true { throw CocoaError(.userCancelled) }
    }

    internal func capabilities(for url: URL) -> FileSystemCapabilities { base.capabilities(for: url) }
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        lock.withLock { listedPaths.append(directory.path) }
        return try base.list(directory, showHidden: showHidden)
    }
    internal func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        lock.withLock { listedPaths.append(directory.path) }
        return try base.list(directory, showHidden: showHidden, cancellation: cancellation)
    }
    internal func item(at url: URL) -> FileItem? { base.item(at: url) }
    internal func parent(of directory: URL) -> URL? { base.parent(of: directory) }
    internal func read(_ url: URL) throws -> any FileReader {
        lock.withLock { readPaths.append(url.path) }
        return try base.read(url)
    }
    internal func read(_ url: URL, cancellation: CancellationFlag) throws -> any FileReader {
        lock.withLock { readPaths.append(url.path) }
        return try base.read(url, cancellation: cancellation)
    }

    internal func write(_ url: URL) throws -> any FileWriter {
        let writer = try base.write(url)
        return writeFailure.map { FailingWriter(writer, $0) } ?? writer
    }
    internal func append(to url: URL, at offset: Int64?, cancellation: CancellationFlag) throws -> any FileWriter {
        try base.append(to: url, at: offset, cancellation: cancellation)
    }
    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try base.copy(source, to: destination, progress: progress)
    }
    internal func commit(_ url: URL, cancellation: CancellationFlag) throws {
        try base.commit(url, cancellation: cancellation)
    }
    internal func quarantine(of url: URL) -> Data? { base.quarantine(of: url) }
    internal func displayPath(_ url: URL) -> String {
        lock.withLock { shown += 1 }
        return base.displayPath(url)
    }
    internal func location(from text: String) -> URL? { base.location(from: text) }
    internal func volume(of url: URL) -> VolumeInfo? { base.volume(of: url) }
    internal func readOrder(of urls: [URL]) -> [URL] { order?(urls) ?? urls }

    // The calls that change something, with a flag and without.
    internal func createDirectory(at url: URL) throws {
        try note("createDirectory", flag: nil)
        base.createDirectory(at: url)
    }
    internal func createDirectory(at url: URL, cancellation: CancellationFlag) throws {
        try note("createDirectory", flag: cancellation)
        base.createDirectory(at: url)
    }
    internal func createDirectory(at url: URL, exclusive: Bool, cancellation: CancellationFlag) throws {
        try note("createDirectory", flag: cancellation)
        if exclusive, base.item(at: url) != nil { throw FileSystemError.alreadyExists(base.displayPath(url)) }
        base.createDirectory(at: url)
    }
    internal func remove(_ url: URL) throws {
        try note("remove", flag: nil)
        try base.remove(url)
    }
    internal func remove(_ url: URL, cancellation: CancellationFlag) throws {
        if stallsRemovals {
            onStalledRemoval?()
            let gate = DispatchSemaphore(value: 0)
            let waiting = cancellation.onCancel { gate.signal() }
            gate.wait()
            withExtendedLifetime(waiting) {}
        }
        try note("remove", flag: cancellation)
        try base.remove(url)
    }
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try note("move", flag: nil)
        try base.move(source, to: destination, replacing: replacing)
    }
    internal func move(_ source: URL, to destination: URL, replacing: Bool, cancellation: CancellationFlag) throws {
        try note("move", flag: cancellation)
        try base.move(source, to: destination, replacing: replacing)
    }
    internal func setAttributes(_: FileAttributes, of _: URL) throws { try note("setAttributes", flag: nil) }
    internal func setAttributes(_: FileAttributes, of _: URL, cancellation: CancellationFlag) throws {
        try note("setAttributes", flag: cancellation)
    }
    internal func copyMetadata(from _: URL, to _: URL) throws { try note("copyMetadata", flag: nil) }
    internal func copyMetadata(from _: URL, to _: URL, cancellation: CancellationFlag) throws {
        try note("copyMetadata", flag: cancellation)
    }
    internal func setQuarantine(_ value: Data, of url: URL) throws {
        try note("setQuarantine", flag: nil)
        if let quarantineFailure { throw quarantineFailure }
        try base.setQuarantine(value, of: url)
    }
    internal func setQuarantine(_ value: Data, of url: URL, cancellation: CancellationFlag) throws {
        try note("setQuarantine", flag: cancellation)
        if let quarantineFailure { throw quarantineFailure }
        try base.setQuarantine(value, of: url)
    }
}

/// The local disk, with a moment to step in right before a folder is made: what somebody
/// else does between a job's look at a name and its use of it.
///
/// Unchecked: its switches are set by the test before use, and it is used from one thread at a
/// time.
internal final class P2RacingLocalFileSystem: FileSystemProvider, @unchecked Sendable {
    internal let local = LocalFileSystem()
    internal var scheme: String { local.scheme }
    internal var capabilities: FileSystemCapabilities { local.capabilities }
    internal var readsRootedPaths: Bool { local.readsRootedPaths }
    internal var beforeCreating: ((URL) -> Void)?

    internal func capabilities(for url: URL) -> FileSystemCapabilities { local.capabilities(for: url) }
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try local.list(directory, showHidden: showHidden)
    }
    internal func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        try local.list(directory, showHidden: showHidden, cancellation: cancellation)
    }
    internal func item(at url: URL) -> FileItem? { local.item(at: url) }
    internal func parent(of directory: URL) -> URL? { local.parent(of: directory) }
    internal func read(_ url: URL) throws -> any FileReader { try local.read(url) }
    internal func write(_ url: URL) throws -> any FileWriter { try local.write(url) }
    internal func remove(_ url: URL) throws { try local.remove(url) }
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try local.move(source, to: destination, replacing: replacing)
    }
    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try local.copy(source, to: destination, progress: progress)
    }
    internal func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        try local.setAttributes(attributes, of: url)
    }
    internal func copyMetadata(from source: URL, to destination: URL) throws {
        try local.copyMetadata(from: source, to: destination)
    }
    internal func displayPath(_ url: URL) -> String { local.displayPath(url) }
    internal func location(from text: String) -> URL? { local.location(from: text) }
    internal func volume(of url: URL) -> VolumeInfo? { local.volume(of: url) }
    internal func createDirectory(at url: URL) throws {
        beforeCreating?(url)
        try local.createDirectory(at: url)
    }
    internal func createDirectory(at url: URL, exclusive: Bool) throws {
        beforeCreating?(url)
        try local.createDirectory(at: url, exclusive: exclusive)
    }
    internal func createDirectory(at url: URL, exclusive: Bool, cancellation: CancellationFlag) throws {
        beforeCreating?(url)
        try local.createDirectory(at: url, exclusive: exclusive, cancellation: cancellation)
    }
}

/// A file system that only shows a folder of the local disk under a location of its own and
/// says so through `realLocation(of:)`, and through nothing else: its `parent(of:)` gives
/// nothing away.
internal final class P2ViewFileSystem: FileSystemProvider {
    internal struct Unused: Error {}

    internal let scheme = "p2view"
    internal let capabilities: FileSystemCapabilities = [.write]
    /// Unowned: the registry holds this file system.
    internal unowned let fileSystems: FileSystemRegistry

    internal init(fileSystems: FileSystemRegistry) { self.fileSystems = fileSystems }

    internal func view(of real: URL) -> URL {
        URL(string: "p2view://shown" + real.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)!
    }
    internal func realLocation(of url: URL) -> URL? { URL(fileURLWithPath: url.path) }
    internal func list(_: URL, showHidden _: Bool) throws -> [FileItem] { throw Unused() }
    internal func item(at _: URL) -> FileItem? { nil }
    internal func parent(of _: URL) -> URL? { nil }
    internal func read(_: URL) throws -> any FileReader { throw Unused() }
    internal func createDirectory(at _: URL) throws { throw Unused() }
    internal func write(_: URL) throws -> any FileWriter { throw Unused() }
    internal func remove(_: URL) throws { throw Unused() }
    internal func move(_: URL, to _: URL, replacing _: Bool) throws { throw Unused() }
    internal func copy(_: URL, to _: URL, progress _: (Int64) -> Bool) throws { throw Unused() }
}

/// Answers a job's questions and keeps what it was told, from whatever thread.
internal final class P2Replies: FileJobDelegate {
    private let lock = NSLock()
    private var messages: [String] = []
    private var reports: [(lines: [String], tag: Int)] = []
    internal var conflict: ConflictChoice = .overwrite
    internal var merge: MergeChoice = .merge
    /// Asked at every report; what it answers is kept with the report.
    internal var tag: (() -> Int)?

    internal var errors: [String] { lock.withLock { messages } }
    internal var progress: [(lines: [String], tag: Int)] { lock.withLock { reports } }

    internal func job(_: FileJob, progress: JobProgress) {
        let tag = tag?() ?? 0
        lock.withLock { reports.append((progress.lines, tag)) }
    }
    internal func job(_: FileJob, conflictAt _: FileItem, source _: FileItem) -> ConflictChoice { conflict }
    internal func job(_: FileJob, failedAt _: URL, error: any Error) -> ErrorChoice {
        lock.withLock { messages.append(error.localizedDescription) }
        return .skip
    }
    internal func job(_: FileJob, confirmDeleteNonEmpty _: URL) -> FolderDeleteChoice { .delete }
    internal func job(_: FileJob, mergeInto _: FileItem, source _: FileItem) -> MergeChoice { merge }
}

/// Runs `work` on another thread and waits for it; if it does not end in `seconds`, `rescue`
/// is called (to free whatever it hangs on) and false comes back.
///
/// The time only matters when the code under test hangs, which is the failure the test is there to
/// catch.
internal func p2Finishes(
    within seconds: TimeInterval = 60,
    rescue: () -> Void = {},
    _ work: @escaping @Sendable () -> Void
)
    -> Bool
{
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        work()
        done.signal()
    }
    if done.wait(timeout: .now() + seconds) == .success {
        return true
    }
    rescue()
    _ = done.wait(timeout: .now() + 10)
    return false
}

/// Sets `flag` a moment from now, from a thread of its own (not from a shared queue, whose
/// threads other tests may all be holding).
///
/// The moment only has to be after the work under test has begun to wait; if it is not, the work
/// finds the flag set and ends just the same.
internal func p2CancelSoon(_ flag: CancellationFlag, after seconds: TimeInterval = 0.2) {
    Thread.detachNewThread {
        Thread.sleep(forTimeInterval: seconds)
        flag.cancel()
    }
}

/// The origin mark of a file on the local disk, as text; nil when it has none.
internal func p2Quarantine(_ url: URL) -> String? {
    let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
    guard size > 0 else {
        return nil
    }
    var bytes = [UInt8](repeating: 0, count: size)
    let read = getxattr(url.path, "com.apple.quarantine", &bytes, size, 0, XATTR_NOFOLLOW)
    return read > 0 ? String(decoding: bytes.prefix(read), as: UTF8.self) : nil
}

@Suite
internal struct Review2FileopsP2Job {
    internal let box: Sandbox
    internal let fileSystems = FileSystemRegistry()
    internal let memory = MemoryFileSystem()
    internal let probe = P2ProbeFileSystem()

    internal init() throws {
        box = try Sandbox()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(memory)
        fileSystems.register(probe)
    }

    private func job(
        _ kind: JobKind,
        _ sources: [URL],
        to directory: URL? = nil,
        replies: P2Replies,
        cancellation: CancellationFlag = CancellationFlag()
    ) -> FileJob {
        let job = FileJob(
            kind: kind,
            sources: sources,
            target: directory.map { TargetSpec(directory: $0) },
            fileSystems: fileSystems,
            cancellation: cancellation
        )
        job.delegate = replies
        return job
    }

    // MARK: F021 — every changing call of a job can be ended

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
        result = job(.delete(toTrash: false), [probe.base.url("/t/dir")], replies: replies).run()
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

    @Test
    internal func aRemovalThatWaitsForAServerEndsWhenTheJobIsCancelled() {
        for index in 0..<5 { probe.base.addFile("/gone/f\(index).txt") }
        probe.stallsRemovals = true
        let flag = CancellationFlag()
        // From a thread of its own: the removal is waiting on this one.
        probe.onStalledRemoval = { Thread.detachNewThread { flag.cancel() } }
        let replies = P2Replies()
        let job = job(.delete(toTrash: false), [probe.base.url("/gone")], replies: replies, cancellation: flag)
        // Written by the other thread before the wait ends, read here after it.
        nonisolated(unsafe) var result = JobResult()
        let ended = p2Finishes(rescue: { flag.cancel() }) { result = job.run() }
        #expect(ended && result.cancelled && replies.errors.isEmpty)
        // Nothing was removed: the one removal that had begun was ended, not carried out.
        #expect(probe.base.allPaths.filter { $0.hasPrefix("/gone/") }.count == 5)
    }

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
        // Guarded by `lock`.
        nonisolated(unsafe) var result = JobResult()
        // The patience is short so that the test is; the test does not depend on how short.
        #expect(p2Finishes { result = job.run() })
        #expect(result.cancelled)
    }

    // MARK: L029 — a folder that is about to be filled is made exclusively

    @Test
    internal func aLinkPutInPlaceOfANewTargetFolderIsNotCopiedThrough() throws {
        let registry = FileSystemRegistry()
        let racing = P2RacingLocalFileSystem()
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

    @Test
    internal func aFileIsBroughtUpToDateBeforeItIsCopiedMovedOrDeleted() {
        let lock = NSLock()
        // Guarded by `lock`.
        nonisolated(unsafe) var flushed: [String] = []
        let memory = self.memory
        fileSystems.addFlusher { url, _ in
            lock.withLock { flushed.append(url.path) }
            // What a plugin with changes still in memory does: it writes them now.
            if url.path == "/s/late.zip" { _ = memory.addFile("/s/late.zip", "written just in time") }
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
        _ = job(.delete(toTrash: false), [memory.url("/t/dir")], replies: replies).run()
        // Files only: a folder holds no changes of its own.
        #expect(Set(lock.withLock { flushed }) == ["/t/late.zip", "/t/dir/inner.txt"])
        #expect(replies.errors.isEmpty)
    }

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
        result = job(.delete(toTrash: false), [memory.url("/s/open.zip")], replies: replies).run()
        #expect(result.completed.isEmpty && memory.exists("/s/open.zip") && replies.errors.count == 2)
    }

    // MARK: A041 — files are read in the order their file system reads them best

    @Test
    internal func theSourcesFileSystemSaysInWhichOrderItsFilesAreRead() throws {
        for name in ["a.txt", "b.txt", "c.txt"] {
            probe.base.addFile("/s/\(name)", name)
            probe.base.addFile("/s/dir/\(name)", name)
        }
        try box.folder("t")
        try box.folder("u")
        // As an archive that is one stream: the files lie in it in the reverse order of their names.
        probe.order = { $0.sorted { $0.lastPathComponent > $1.lastPathComponent } }
        let replies = P2Replies()
        let sources = ["a.txt", "b.txt", "c.txt"].map { probe.base.url("/s/\($0)") }
        var result = job(.copy, sources, to: box.url("t"), replies: replies).run()
        #expect(probe.reads == ["/s/c.txt", "/s/b.txt", "/s/a.txt"])
        #expect(Set(result.completed) == Set(sources) && namesOnDisk(box.url("t")) == ["a.txt", "b.txt", "c.txt"])
        result = job(.copy, [probe.base.url("/s/dir")], to: box.url("u"), replies: replies).run()
        #expect(probe.reads.suffix(3) == ["/s/dir/c.txt", "/s/dir/b.txt", "/s/dir/a.txt"])
        #expect(result.completed.count == 1 && box.read("u/dir/b.txt") == "b.txt")
        // An answer that is not the same files in another order is not followed, and nothing is lost.
        probe.order = { Array($0.dropLast()) + [URL(string: "probe:///s/elsewhere.txt")!] }
        try box.folder("v")
        let unordered = job(.copy, sources, to: box.url("v"), replies: replies)
        // One after another, so that the order they are taken in shows: the order of their names.
        unordered.options.copiesSmallFilesInParallel = false
        result = unordered.run()
        #expect(probe.reads.suffix(3) == ["/s/a.txt", "/s/b.txt", "/s/c.txt"] && namesOnDisk(box.url("v")).count == 3)
        #expect(replies.errors.isEmpty)
    }

    // MARK: F046 — a paused job waits before the commit

    @Test
    internal func theCommitIsAnnouncedBeforeItStartsSoThatAPausedJobWaitsThere() throws {
        memory.capabilities = [.write, .deferredWrites]
        memory.addDirectory("/t")
        let sources = [try box.file("s/a.txt", "a"), try box.file("s/b.txt", "b")]
        let replies = P2Replies()
        let memory = self.memory
        // What the delegate sees at each report: how many commits there have been by then.
        // A progress window holds the job inside a report while it is paused.
        replies.tag = { memory.commits.count }
        let result = job(.move, sources, to: memory.url("/t"), replies: replies).run()
        #expect(result.completed.count == 2 && memory.commits == ["/t"] && !box.exists("s/a.txt"))
        let announced = replies.progress.filter { $0.lines == ["Writing: mem:/t"] }
        #expect(!announced.isEmpty && announced.allSatisfy { $0.tag == 0 })
        // And the removals that follow the commit are reported one by one, as before.
        #expect(replies.progress.contains { $0.lines.first?.hasPrefix("Deleting: ") == true && $0.tag == 1 })
    }

    // MARK: N009 — the origin mark of what comes from a server or a marked archive

    @Test
    internal func whatIsCopiedFromAMarkedFileSystemCarriesTheMarkOnDisk() throws {
        let mark = "0083;5f000000;Test;"
        memory.quarantineValue = Data(mark.utf8)
        memory.capabilities = [.write]
        memory.addFile("/s/tool.command", "#!/bin/sh\necho hello\n")
        memory.addFile("/s/app/run.sh", "#!/bin/sh\n")
        memory.addFile("/s/part.bin", "0123456789")
        memory.addFile("/s/log.txt", " and more")
        try box.folder("t")
        let replies = P2Replies()
        _ = job(.copy, [memory.url("/s/tool.command"), memory.url("/s/app")], to: box.url("t"), replies: replies).run()
        #expect(p2Quarantine(box.url("t/tool.command")) == mark)
        #expect(p2Quarantine(box.url("t/app/run.sh")) == mark && p2Quarantine(box.url("t/app")) == mark)
        // Resume: the file on disk is the beginning; what is added came from the server too.
        try box.file("t/part.bin", "0123")
        replies.conflict = .resume
        _ = job(.copy, [memory.url("/s/part.bin")], to: box.url("t"), replies: replies).run()
        #expect(box.read("t/part.bin") == "0123456789" && p2Quarantine(box.url("t/part.bin")) == mark)
        // Append: the longer file is written anew and takes the old one's place.
        try box.file("t/log.txt", "the log")
        replies.conflict = .append
        _ = job(.copy, [memory.url("/s/log.txt")], to: box.url("t"), replies: replies).run()
        #expect(box.read("t/log.txt") == "the log and more" && p2Quarantine(box.url("t/log.txt")) == mark)
        // A move is a copy and a removal: the mark is there as well.
        memory.addFile("/s/moved.sh", "x")
        replies.conflict = .overwrite
        _ = job(.move, [memory.url("/s/moved.sh")], to: box.url("t"), replies: replies).run()
        #expect(p2Quarantine(box.url("t/moved.sh")) == mark && !memory.exists("/s/moved.sh"))
        #expect(replies.errors.isEmpty)
        // No mark at the source, none on the copy.
        memory.quarantineValue = nil
        memory.addFile("/s2/plain.txt", "x")
        _ = job(.copy, [memory.url("/s2/plain.txt")], to: box.url("t"), replies: replies).run()
        #expect(box.exists("t/plain.txt") && p2Quarantine(box.url("t/plain.txt")) == nil)
    }

    // F052
    @Test
    internal func aMarkThatCannotBeSetIsCountedAndNotAskedAbout() {
        struct Refused: LocalizedError {
            var errorDescription: String? { "marks are not kept here" }
        }
        memory.quarantineValue = Data("0083;5f000000;Test;".utf8)
        memory.addFile("/s/tool.command", "#!/bin/sh\n")
        probe.base.addDirectory("/t")
        probe.quarantineFailure = Refused()
        let replies = P2Replies()
        // Guarded by `lock`.
        nonisolated(unsafe) var records: [OperationRecord] = []
        let lock = NSLock()
        let job = job(.copy, [memory.url("/s/tool.command")], to: probe.base.url("/t"), replies: replies)
        job.onRecord = { record in lock.withLock { records.append(record) } }
        let result = job.run()
        // The copy is there and counts as done; the failure is told at the end, not asked about.
        #expect(
            result.completed.count == 1 && probe.base.contents("/t/tool.command") == "#!/bin/sh\n"
                && replies.errors.isEmpty
        )
        #expect(result.failureCount == 1 && result.failures.first?.contains("could not be marked") == true)
        #expect(
            records.contains { record in
                if case .failed(let message) = record.status {
                    return message.contains("marks are not kept here")
                }
                return false
            }
        )
    }

    // MARK: F041, F047 — work that grows with the tree is done once, or not at all

    @Test
    internal func theLinesOfAReportAreOnlyPutTogetherWhenAReportGoesOut() {
        for index in 0..<300 { probe.base.addFile("/s/f\(index).txt") }
        probe.base.addDirectory("/t")
        let replies = P2Replies()
        let job = job(.copy, [probe.base.url("/s")], to: probe.base.url("/t"), replies: replies)
        // Nothing is due between the first report and the last.
        job.progressInterval = 3_600
        let result = job.run()
        #expect(result.completed.count == 1 && probe.base.exists("/t/s/f299.txt"))
        // Two paths per report that went out; two per file would be six hundred.
        #expect(
            replies.progress.count <= 3 && probe.displayed <= 12,
            "\(replies.progress.count) reports, \(probe.displayed) paths"
        )
    }

    @Test
    internal func aFolderThatIsSkippedIsNotWalkedAgainForTheCount() {
        for index in 0..<4 { probe.base.addFile("/s/dir/sub/f\(index).txt") }
        probe.base.addFile("/t/dir/there.txt")
        let replies = P2Replies()
        replies.merge = .skip
        let job = job(.copy, [probe.base.url("/s/dir")], to: probe.base.url("/t"), replies: replies)
        job.options.asksBeforeMerging = true
        let result = job.run()
        #expect(result.completed.isEmpty && !probe.base.exists("/t/dir/sub"))
        // Listed once each, by the first count; the skip took the figures from there.
        #expect(probe.listings(of: "/s/dir") == 1 && probe.listings(of: "/s/dir/sub") == 1)
    }

    // MARK: F001/F018 through the provider's own answer

    @Test
    internal func aFileSystemThatSaysWhereItsFilesReallyAreIsBelieved() throws {
        let view = P2ViewFileSystem(fileSystems: fileSystems)
        fileSystems.register(view)
        let file = try box.file("d/a.txt", "precious")
        let shown = view.view(of: box.url("d"))
        // Nothing but `realLocation(of:)` gives the real folder away.
        #expect(view.parent(of: shown) == nil)
        #expect(RealLocation.resolve(shown, in: fileSystems).path == box.url("d").path)
        let replies = P2Replies()
        let job = job(.move, [file], to: shown, replies: replies)
        #expect(job.target?.directory.isFileURL == true && job.targetsSourceFolder)
        let result = job.run()
        #expect(box.read("d/a.txt") == "precious" && namesOnDisk(box.url("d")) == ["a.txt"])
        #expect(result.completed.isEmpty && replies.errors == ["You cannot copy a file to itself!"])
    }

    // MARK: Names

    @Test
    internal func theRuleForNamesIsTheKernels() {
        for name in ["", ".", "..", "a/b", "a\u{0}b"] {
            #expect(!FileJob.isSafeName(name) && !PathSafety.isSafeName(name))
        }
        for name in ["a", "...", "a b", ".hidden", "é"] {
            #expect(FileJob.isSafeName(name) && PathSafety.isSafeName(name))
        }
    }
}
