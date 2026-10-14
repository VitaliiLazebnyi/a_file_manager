import AFMContracts
import AFMKernel
import ClipboardPlugin
import FilePropertiesPlugin
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileOperationsPlugin

// The jobs and commands that use the provider API of the last round: cancelling a blocked
// stream, metadata of folders, continuing a partial file, per-location capabilities, commits
// before a move deletes, origin marks.

/// A `MemoryFileSystem` behind a layer that tells a test what a job is doing to it: it signals
/// when a read, write, listing or commit begins, and counts the calls that matter.
final class ProbeFileSystem: FileSystemProvider {
    let base: MemoryFileSystem
    var scheme: String { base.scheme }
    var capabilities: FileSystemCapabilities { base.capabilities }
    /// Called when a read, a write, a listing or a commit is entered (before it may wait).
    var onRead: (() -> Void)?
    var onWrite: (() -> Void)?
    var onList: (() -> Void)?
    var onCommit: (() -> Void)?
    /// Called when a move begins.
    var onMove: (() -> Void)?
    /// Claimed on top of what the base can do, as a server without a session claims `.append`
    /// that its connection then cannot keep.
    var claims: FileSystemCapabilities = []
    private let lock = NSLock()
    private var calls: [String: Int] = [:]

    init(_ base: MemoryFileSystem) { self.base = base }

    private func count(_ name: String) { lock.withLock { calls[name, default: 0] += 1 } }
    func count(of name: String) -> Int { lock.withLock { calls[name] ?? 0 } }

    private final class Reader: FileReader {
        let inner: any FileReader, owner: ProbeFileSystem
        init(_ inner: any FileReader, _ owner: ProbeFileSystem) { (self.inner, self.owner) = (inner, owner) }
        func read(upToCount count: Int) throws -> Data? {
            owner.onRead?()
            return try inner.read(upToCount: count)
        }
        func seek(to offset: UInt64) throws { try inner.seek(to: offset) }
        func close() { inner.close() }
        func interrupt() { inner.interrupt() }
    }

    private final class Writer: FileWriter {
        let inner: any FileWriter, owner: ProbeFileSystem
        init(_ inner: any FileWriter, _ owner: ProbeFileSystem) { (self.inner, self.owner) = (inner, owner) }
        func write(_ data: Data) throws {
            owner.onWrite?()
            try inner.write(data)
        }
        func close(attributes: FileAttributes) throws { try inner.close(attributes: attributes) }
        func interrupt() { inner.interrupt() }
    }

    func capabilities(for url: URL) -> FileSystemCapabilities { base.capabilities(for: url).union(claims) }
    func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        count("list " + directory.path)
        return try base.list(directory, showHidden: showHidden)
    }
    func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        count("list " + directory.path)
        onList?()
        return try base.list(directory, showHidden: showHidden, cancellation: cancellation)
    }
    func item(at url: URL) -> FileItem? { base.item(at: url) }
    func parent(of directory: URL) -> URL? { base.parent(of: directory) }
    func read(_ url: URL) throws -> any FileReader { Reader(try base.read(url), self) }
    func read(_ url: URL, cancellation: CancellationFlag) throws -> any FileReader {
        Reader(try base.read(url, cancellation: cancellation), self)
    }
    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func write(_ url: URL) throws -> any FileWriter {
        count("write")
        return Writer(try base.write(url), self)
    }
    func write(_ url: URL, cancellation: CancellationFlag) throws -> any FileWriter {
        count("write")
        return Writer(try base.write(url, cancellation: cancellation), self)
    }
    func append(to url: URL, at offset: Int64?, cancellation: CancellationFlag) throws -> any FileWriter {
        count("append")
        return Writer(try base.append(to: url, at: offset, cancellation: cancellation), self)
    }
    func remove(_ url: URL) throws { try base.remove(url) }
    func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        onMove?()
        try base.move(source, to: destination, replacing: replacing)
    }
    func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try base.copy(source, to: destination, progress: progress)
    }
    func copyMetadata(from source: URL, to destination: URL) throws {
        try base.copyMetadata(from: source, to: destination)
    }
    func commit(_ url: URL, cancellation: CancellationFlag) throws {
        onCommit?()
        try base.commit(url, cancellation: cancellation)
    }
    func quarantine(of url: URL) -> Data? {
        count("quarantine")
        return base.quarantine(of: url)
    }
    func setQuarantine(_ value: Data, of url: URL) throws { try base.setQuarantine(value, of: url) }
    func displayPath(_ url: URL) -> String { base.displayPath(url) }
    func location(from text: String) -> URL? { base.location(from: text) }
    func volume(of url: URL) -> VolumeInfo? { base.volume(of: url) }
}

private func registry(_ providers: any FileSystemProvider...) -> FileSystemRegistry {
    let fileSystems = FileSystemRegistry()
    fileSystems.register(LocalFileSystem())
    providers.forEach(fileSystems.register)
    return fileSystems
}

/// Runs the job on a thread of its own and gives up waiting after `seconds`.
private func run(_ job: FileJob, within seconds: Double = 60) -> JobResult? {
    let finished = DispatchSemaphore(value: 0)
    var result: JobResult?
    let thread = Thread {
        result = job.run()
        finished.signal()
    }
    thread.start()
    return finished.wait(timeout: .now() + seconds) == .success ? result : nil
}

/// Cancels the job as soon as `gate` is signalled (or after a minute, so that nothing hangs).
private func cancel(_ job: FileJob, when gate: DispatchSemaphore) {
    let thread = Thread {
        _ = gate.wait(timeout: .now() + 60)
        job.cancel()
    }
    thread.start()
}

/// A value several threads change.
private final class Locked<Value> {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func modify(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

/// Counts calls made from several threads.
private final class CallCounter {
    private let lock = NSLock()
    private var calls = 0
    func next() -> Int {
        lock.withLock {
            calls += 1
            return calls
        }
    }
}

private func tempNames(in names: [String]) -> [String] { names.filter { $0.contains(".afm-") } }

private let tagName = "com.apple.metadata:_kMDItemUserTags"

private func setTag(_ url: URL, _ value: String = "tagvalue") {
    let bytes = Array(value.utf8)
    _ = setxattr(url.path, tagName, bytes, bytes.count, 0, XATTR_NOFOLLOW)
}

private func tag(_ url: URL) -> String? {
    let size = getxattr(url.path, tagName, nil, 0, 0, XATTR_NOFOLLOW)
    guard size > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: size)
    guard getxattr(url.path, tagName, &bytes, size, 0, XATTR_NOFOLLOW) == size else { return nil }
    return String(decoding: bytes, as: UTF8.self)
}

private func flags(_ url: URL) -> UInt32 {
    var info = stat()
    return lstat(url.path, &info) == 0 ? info.st_flags : 0
}

private func created(_ url: URL) -> Date? {
    try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
}

// MARK: - Cancelling a stream that waits

@Suite struct FileOpsAdoptCancellation {
    @Test func cancelEndsAReadThatWaitsAndLeavesNoTemporaryFile() throws {
        let box = try Sandbox()
        let base = MemoryFileSystem()
        base.stallsReads = true
        let probe = ProbeFileSystem(base)
        let gate = DispatchSemaphore(value: 0)
        probe.onRead = { gate.signal() }
        let source = base.addFile("/src/big.bin", "some data")
        let out = try box.folder("out")
        let job = FileJob(
            kind: .copy, sources: [source], target: TargetSpec(directory: out), fileSystems: registry(probe))
        let answers = Answers()
        job.delegate = answers
        cancel(job, when: gate)
        let result = withExtendedLifetime(answers) { run(job) }
        #expect(result?.cancelled == true)
        #expect(base.interruptions >= 1)
        #expect(namesOnDisk(out).isEmpty)
    }

    @Test func cancelEndsAWriteThatWaitsAndRemovesWhatArrived() throws {
        let box = try Sandbox()
        let base = MemoryFileSystem()
        base.stallsWrites = true
        let probe = ProbeFileSystem(base)
        let gate = DispatchSemaphore(value: 0)
        probe.onWrite = { gate.signal() }
        let source = try box.file("A/data.bin", "some data")
        base.addDirectory("/out")
        let job = FileJob(
            kind: .copy, sources: [source], target: TargetSpec(directory: base.url("/out")),
            fileSystems: registry(probe))
        let answers = Answers()
        job.delegate = answers
        cancel(job, when: gate)
        let result = withExtendedLifetime(answers) { run(job) }
        #expect(result?.cancelled == true)
        #expect(base.interruptions >= 1)
        #expect(base.allPaths == ["/out"])
    }

    @Test func cancelEndsAVerifyingReadThatWaits() throws {
        let box = try Sandbox()
        let base = MemoryFileSystem()
        let probe = ProbeFileSystem(base)
        let gate = DispatchSemaphore(value: 0)
        // The copy reads the source (the data, then the end); the read of the verification is the third and waits.
        let reads = CallCounter()
        probe.onRead = {
            switch reads.next() {
            case 2: base.stallsReads = true
            case 3: gate.signal()
            default: break
            }
        }
        let source = base.addFile("/src/big.bin", "some data")
        let out = try box.folder("out")
        let job = FileJob(
            kind: .copy, sources: [source], target: TargetSpec(directory: out), fileSystems: registry(probe))
        job.options.verifies = true
        let answers = Answers()
        job.delegate = answers
        cancel(job, when: gate)
        let result = withExtendedLifetime(answers) { run(job) }
        #expect(result?.cancelled == true)
        #expect(base.interruptions >= 1)
        #expect(namesOnDisk(out).isEmpty)
    }

    @Test func cancelEndsAListingThatWaits() throws {
        let box = try Sandbox()
        let base = MemoryFileSystem()
        base.stallsListings = true
        let probe = ProbeFileSystem(base)
        let gate = DispatchSemaphore(value: 0)
        probe.onList = { gate.signal() }
        base.addFile("/src/tree/a.txt")
        let out = try box.folder("out")
        let job = FileJob(
            kind: .copy, sources: [base.url("/src/tree")], target: TargetSpec(directory: out),
            fileSystems: registry(probe))
        let answers = Answers()
        job.delegate = answers
        cancel(job, when: gate)
        let result = withExtendedLifetime(answers) { run(job) }
        #expect(result?.cancelled == true)
        #expect(result?.completed.isEmpty == true)
    }

    @Test func aStreamThatIsNotCancelledStillCompletes() throws {
        let box = try Sandbox()
        let base = MemoryFileSystem()
        let source = base.addFile("/src/a.txt", "payload")
        let out = try box.folder("out")
        let result = runJob(.copy, [source], to: TargetSpec(directory: out), fileSystems: registry(base))
        #expect(!result.cancelled && result.completed == [source])
        #expect(try String(contentsOf: out.appendingPathComponent("a.txt")) == "payload")
        #expect(base.interruptions == 0)
    }
}

// MARK: - Metadata of folders

@Suite struct FileOpsAdoptMetadata {
    @Test func aCopiedFolderKeepsItsTagHiddenFlagAndCreationDate() throws {
        let box = try Sandbox()
        let tree = try box.folder("A/tree")
        try box.file("A/tree/in.txt", "inside")
        let sub = try box.folder("A/tree/sub")
        try box.file("A/tree/sub/deep.txt", "deep")
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        for folder in [tree, sub] {
            setTag(folder)
            var values = URLResourceValues()
            values.creationDate = date
            var url = folder
            try url.setResourceValues(values)
        }
        #expect(chflags(sub.path, UInt32(UF_HIDDEN)) == 0)
        try box.folder("B")
        let result = runJob(.copy, [tree], to: TargetSpec(directory: box.url("B")))
        #expect(result.completed == [tree])
        for name in ["B/tree", "B/tree/sub"] {
            let copy = box.url(name)
            #expect(tag(copy) == "tagvalue", "\(name)")
            #expect(abs((created(copy) ?? .distantPast).timeIntervalSince(date)) < 1, "\(name)")
        }
        #expect(flags(box.url("B/tree/sub")) & UInt32(UF_HIDDEN) != 0)
        #expect(box.read("B/tree/sub/deep.txt") == "deep" && box.read("B/tree/in.txt") == "inside")
    }

    @Test func foldersMadeLateBecauseOfAFilterAreFinishedLikeTheOthers() throws {
        let box = try Sandbox()
        let tree = try box.folder("A/tree")
        try box.file("A/tree/sub/deep.txt", "deep")
        try box.file("A/tree/skipped/other.bin", "other")
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        for folder in [tree, box.url("A/tree/sub")] {
            setTag(folder)
            var values = URLResourceValues()
            values.creationDate = date
            var url = folder
            try url.setResourceValues(values)
            #expect(chmod(folder.path, 0o750) == 0)
        }
        try box.folder("B")
        let job = FileJob(
            kind: .copy, sources: [tree], target: TargetSpec(directory: box.url("B")), fileSystems: registry())
        // Folders are made when the first file arrives in them.
        job.options.filter = CopyFilter("*.txt | **/")
        let answers = Answers()
        job.delegate = answers
        #expect(withExtendedLifetime(answers) { job.run() }.completed == [tree])
        #expect(box.read("B/tree/sub/deep.txt") == "deep" && !box.exists("B/tree/skipped"))
        for name in ["B/tree", "B/tree/sub"] {
            let copy = box.url(name)
            #expect(tag(copy) == "tagvalue", "\(name)")
            #expect(abs((created(copy) ?? .distantPast).timeIntervalSince(date)) < 1, "\(name)")
            var info = stat()
            #expect(stat(copy.path, &info) == 0 && info.st_mode & 0o777 == 0o750, "\(name)")
        }
    }

    @Test func aFinderLockedFolderIsCopiedCompletelyAndLockedLikeTheOriginal() throws {
        let box = try Sandbox()
        let locked = try box.folder("A/locked")
        try box.file("A/locked/one.txt", "1")
        try box.file("A/locked/inner/two.txt", "2")
        try box.folder("B")
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        defer {
            chflags(box.url("A/locked").path, 0)
            chflags(box.url("B/locked").path, 0)
        }
        let result = runJob(.copy, [locked], to: TargetSpec(directory: box.url("B")))
        #expect(result.completed == [locked])
        #expect(box.read("B/locked/one.txt") == "1" && box.read("B/locked/inner/two.txt") == "2")
        #expect(flags(box.url("B/locked")) & UInt32(UF_IMMUTABLE) != 0)
        #expect(!namesOnDisk(box.url("B/locked")).contains { $0.hasPrefix(".afm-") })
    }

    @Test func aFollowedLinkKeepsTheTagsOfItsTarget() throws {
        let box = try Sandbox()
        let real = try box.file("A/real.txt", "target contents")
        setTag(real, "linked")
        let link = box.url("A/link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try box.folder("B")
        let replies = Replies()
        runJob(.copy, [link], to: TargetSpec(directory: box.url("B")), replies: replies) {
            $0.options.links = .followLinks
        }
        let copy = box.url("B/link.txt")
        #expect(box.read("B/link.txt") == "target contents")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: copy.path)) == nil)
        #expect(tag(copy) == "linked")
    }

    @Test func foldersTheJobCreatedAreGivenTheirMetadataLastAndOnlyWhenAttributesAreKept() {
        let base = MemoryFileSystem()
        base.keepsMetadata = true
        base.addFile("/src/tree/a.txt")
        base.addFile("/src/tree/sub/b.txt")
        base.addDirectory("/dst")
        let fileSystems = registry(base)
        runJob(.copy, [base.url("/src/tree")], to: TargetSpec(directory: base.url("/dst")), fileSystems: fileSystems)
        let copies = base.metadataCopies
        #expect(Set(copies.map(\.to)) == ["/dst/tree", "/dst/tree/sub"])
        #expect(Set(copies.map { $0.from.path }) == ["/src/tree", "/src/tree/sub"])

        // Without "keep dates and permissions" nothing is carried.
        let plain = MemoryFileSystem()
        plain.keepsMetadata = true
        plain.addFile("/src/tree/a.txt")
        plain.addDirectory("/dst")
        runJob(
            .copy, [plain.url("/src/tree")], to: TargetSpec(directory: plain.url("/dst")), replies: Replies(),
            fileSystems: registry(plain)
        ) { $0.options.preservesAttributes = false }
        #expect(plain.metadataCopies.isEmpty)

        // A folder that was merged into is not the job's: it keeps what it has.
        let merged = MemoryFileSystem()
        merged.keepsMetadata = true
        merged.addFile("/src/tree/a.txt")
        merged.addFile("/dst/tree/old.txt")
        runJob(
            .copy, [merged.url("/src/tree")], to: TargetSpec(directory: merged.url("/dst")),
            fileSystems: registry(merged))
        #expect(merged.metadataCopies.isEmpty)
    }

    @Test func aFileSystemThatKeepsNoMetadataDoesNotSpoilTheCopy() {
        let base = MemoryFileSystem()
        base.addFile("/src/tree/a.txt", "a")
        base.addDirectory("/dst")
        let result = runJob(
            .copy, [base.url("/src/tree")], to: TargetSpec(directory: base.url("/dst")), fileSystems: registry(base))
        #expect(result.completed.count == 1 && result.failureCount == 0)
        #expect(base.contents("/dst/tree/a.txt") == "a")
    }
}

// MARK: - Resume

@Suite struct FileOpsAdoptResume {
    private func setUp(partial: String, source: String, capabilities: FileSystemCapabilities) -> (
        MemoryFileSystem, ProbeFileSystem
    ) {
        let base = MemoryFileSystem()
        base.capabilities = capabilities
        base.addFile("/s/file.txt", source)
        base.addFile("/t/file.txt", partial)
        return (base, ProbeFileSystem(base))
    }

    private func resume(_ base: MemoryFileSystem, _ probe: ProbeFileSystem, verify: Bool = false) -> Replies {
        let replies = Replies(.resume)
        runJob(
            .copy, [base.url("/s/file.txt")], to: TargetSpec(directory: base.url("/t")), replies: replies,
            fileSystems: registry(probe)
        ) {
            $0.options.verifies = verify
        }
        return replies
    }

    @Test func aResumeContinuesThePartialFileWhereTheFileSystemCanAppend() {
        let (base, probe) = setUp(
            partial: "hello wo", source: "hello world, resumed", capabilities: [.write, .append])
        let replies = resume(base, probe)
        #expect(replies.errors.isEmpty)
        #expect(base.contents("/t/file.txt") == "hello world, resumed")
        #expect(probe.count(of: "append") == 1)
        #expect(probe.count(of: "write") == 0)
        #expect(base.allPaths.filter { $0.contains(".afm-") }.isEmpty)
    }

    @Test func withoutAppendTheFileIsWrittenAnewAndSwappedIn() {
        let (base, probe) = setUp(partial: "hello wo", source: "hello world, resumed", capabilities: [.write])
        let replies = resume(base, probe)
        #expect(replies.errors.isEmpty)
        #expect(base.contents("/t/file.txt") == "hello world, resumed")
        #expect(probe.count(of: "append") == 0)
        #expect(probe.count(of: "write") == 1)
    }

    @Test func aFileSystemThatClaimsAppendButRefusesItFallsBackToWritingAnew() {
        let (base, probe) = setUp(partial: "hello wo", source: "hello world, resumed", capabilities: [.write])
        probe.claims = .append
        let replies = resume(base, probe)
        #expect(replies.errors.isEmpty)
        #expect(base.contents("/t/file.txt") == "hello world, resumed")
        #expect(probe.count(of: "append") == 1 && probe.count(of: "write") == 1)
        #expect(base.allPaths.filter { $0.contains(".afm-") }.isEmpty)
    }

    @Test func aPartialFileThatIsNotTheStartOfTheSourceIsNotContinued() {
        let (base, probe) = setUp(
            partial: "hellX wo", source: "hello world, resumed", capabilities: [.write, .append])
        let replies = resume(base, probe)
        #expect(replies.errors.count == 1 && replies.errors[0].contains("cannot be resumed"))
        #expect(base.contents("/t/file.txt") == "hellX wo")
        #expect(probe.count(of: "append") == 0)
    }

    @Test func verifyComparesAllOfThePartialFileNotJustItsLastBlock() {
        // A difference at the very start of a partial file of 1.5 MB is beyond the last block.
        let partial = "X" + String(repeating: "a", count: 1_500_000)
        let source = String(repeating: "a", count: 1_501_000) + "tail"
        let (base, probe) = setUp(partial: partial, source: source, capabilities: [.write, .append])
        let replies = resume(base, probe, verify: true)
        #expect(replies.errors.count == 1 && replies.errors[0].contains("cannot be resumed"))
        #expect(base.contents("/t/file.txt") == partial)

        let (good, goodProbe) = setUp(
            partial: String(repeating: "a", count: 1_500_000), source: source, capabilities: [.write, .append])
        let ok = resume(good, goodProbe, verify: true)
        #expect(ok.errors.isEmpty && good.contents("/t/file.txt") == source)
        #expect(goodProbe.count(of: "append") == 1)
    }

    @Test func aResumeOnTheLocalDiskContinuesTheFileItself() throws {
        let box = try Sandbox()
        try box.file("S/f.txt", "0123456789abcdef")
        let partial = try box.file("T/f.txt", "01234567")
        let before = try FileManager.default.attributesOfItem(atPath: partial.path)[.systemFileNumber] as? Int
        let replies = Replies(.resume)
        runJob(.copy, [box.url("S/f.txt")], to: TargetSpec(directory: box.url("T")), replies: replies)
        #expect(replies.errors.isEmpty)
        #expect(box.read("T/f.txt") == "0123456789abcdef")
        #expect(try FileManager.default.attributesOfItem(atPath: partial.path)[.systemFileNumber] as? Int == before)
        #expect(!namesOnDisk(box.url("T")).contains { $0.hasPrefix(".afm-") })
    }
}

// MARK: - Commit before a move deletes

@Suite struct FileOpsAdoptCommit {
    private func destination(_ capabilities: FileSystemCapabilities) -> (MemoryFileSystem, ProbeFileSystem) {
        let base = MemoryFileSystem(scheme: "dst")
        base.capabilities = capabilities
        base.addDirectory("/out")
        return (base, ProbeFileSystem(base))
    }

    @Test func sourcesAreDeletedOnlyAfterTheOneCommitOfTheTargetFolder() throws {
        let box = try Sandbox()
        let files = try (1...3).map { try box.file("A/f\($0).txt", "content \($0)") }
        let (base, probe) = destination([.write, .deferredWrites])
        var existedAtCommit: [Bool] = []
        probe.onCommit = { existedAtCommit = files.map { FileManager.default.fileExists(atPath: $0.path) } }
        let result = runJob(.move, files, to: TargetSpec(directory: base.url("/out")), fileSystems: registry(probe))
        #expect(base.commits == ["/out"])
        #expect(existedAtCommit == [true, true, true])
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(Set(result.completed) == Set(files) && !result.cancelled)
        #expect(base.contents("/out/f2.txt") == "content 2")
    }

    @Test func aMovedFolderIsRemovedAfterTheCommitToo() throws {
        let box = try Sandbox()
        let tree = try box.folder("A/tree")
        try box.file("A/tree/a.txt", "a")
        try box.file("A/tree/sub/b.txt", "b")
        let (base, probe) = destination([.write, .deferredWrites])
        var treeAtCommit = false
        probe.onCommit = { treeAtCommit = FileManager.default.fileExists(atPath: box.url("A/tree/sub/b.txt").path) }
        let result = runJob(.move, [tree], to: TargetSpec(directory: base.url("/out")), fileSystems: registry(probe))
        #expect(result.completed == [tree])
        #expect(treeAtCommit && base.commits == ["/out"])
        #expect(!box.exists("A/tree"))
        #expect(base.contents("/out/tree/sub/b.txt") == "b")
    }

    @Test func aFailedCommitKeepsEverySourceAndEndsTheJobAsFailed() throws {
        let box = try Sandbox()
        let files = try (1...3).map { try box.file("A/f\($0).txt", "content \($0)") }
        let (base, probe) = destination([.write, .deferredWrites])
        base.commitFailure = CocoaError(.fileWriteOutOfSpace)
        let retry = RetryOnce()
        let job = FileJob(
            kind: .move, sources: files, target: TargetSpec(directory: base.url("/out")), fileSystems: registry(probe)
        )
        job.delegate = retry
        let result = withExtendedLifetime(retry) { job.run() }
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(result.completed.isEmpty && result.cancelled && result.failureCount >= 1)
        // Retry asked the same question again; it never deleted anything, and the commit ran once.
        #expect(retry.errors.count == 2)
        #expect(base.commits == ["/out"])
    }

    @Test func aTargetWithoutDeferredWritesIsNotCommittedAndSourcesGoAtOnce() throws {
        let box = try Sandbox()
        let files = try (1...3).map { try box.file("A/f\($0).txt", "c\($0)") }
        let (base, probe) = destination([.write])
        let result = runJob(.move, files, to: TargetSpec(directory: base.url("/out")), fileSystems: registry(probe))
        #expect(base.commits.isEmpty)
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(result.completed.count == 3)
    }

    @Test func aHugeMoveIsCommittedInBatches() throws {
        let box = try Sandbox()
        let files = try (1...7).map { try box.file("A/f\($0).txt", "c\($0)") }
        let (base, probe) = destination([.write, .deferredWrites])
        runJob(
            .move, files, to: TargetSpec(directory: base.url("/out")), replies: Replies(), fileSystems: registry(probe)
        ) {
            $0.deferredBatchSize = 2
            // One file at a time, so that the count of waiting removals is the same on every run.
            $0.parallelWidth = 1
        }
        #expect(base.commits.count >= 3)
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect((1...7).allSatisfy { base.contents("/out/f\($0).txt") == "c\($0)" })
    }

    @Test func aCommitInTheMiddleOfAMoveMeetsNoFileUnderItsTemporaryName() throws {
        let box = try Sandbox()
        let files = try (1...16).map { try box.file("A/f\($0).txt", "c\($0)") }
        let (base, probe) = destination([.write, .deferredWrites])
        let seen = Locked<[String]>([])
        // A file waits a moment between being written and getting its name.
        probe.onMove = { Thread.sleep(forTimeInterval: 0.01) }
        probe.onCommit = { seen.modify { $0 += base.allPaths.filter { $0.contains(".afm-") } } }
        runJob(
            .move, files, to: TargetSpec(directory: base.url("/out")), replies: Replies(), fileSystems: registry(probe)
        ) {
            $0.deferredBatchSize = 2
            $0.parallelWidth = 4
        }
        #expect(base.commits.count >= 2)
        #expect(seen.value.isEmpty)
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect((1...16).allSatisfy { base.contents("/out/f\($0).txt") == "c\($0)" })
    }

    @Test func aSourceThatCouldNotBeRemovedIsNotReportedAsMoved() throws {
        let box = try Sandbox()
        let tree = try box.folder("A/tree")
        try box.file("A/tree/a.txt", "a")
        let (base, probe) = destination([.write, .deferredWrites])
        // The file cannot be deleted: its folder stays, and so does the item in the panel.
        #expect(chflags(box.url("A/tree/a.txt").path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(box.url("A/tree/a.txt").path, 0) }
        let result = runJob(
            .move, [tree], to: TargetSpec(directory: base.url("/out")), replies: Replies(),
            fileSystems: registry(probe))
        #expect(result.completed.isEmpty)
        #expect(box.exists("A/tree/a.txt"))
    }
}

// MARK: - Origin marks

@Suite struct FileOpsAdoptQuarantine {
    private let mark = Data("0083;5f5e1000;Browser;".utf8)

    private func tree(in base: MemoryFileSystem) {
        base.addFile("/src/tree/a.txt", "a")
        base.addFile("/src/tree/b.txt", "b")
        base.addFile("/src/tree/sub/c.txt", "c")
    }

    @Test func filesAndFoldersFromAMarkedSourceAreMarkedBeforeTheyGetTheirNames() {
        let source = MemoryFileSystem(scheme: "mem")
        source.quarantineValue = mark
        tree(in: source)
        let probe = ProbeFileSystem(source)
        let target = MemoryFileSystem(scheme: "arc")
        target.addDirectory("/out")
        let result = runJob(
            .copy, [source.url("/src/tree")], to: TargetSpec(directory: target.url("/out")),
            fileSystems: registry(probe, target))
        #expect(result.completed.count == 1)
        let marks = target.quarantineMarks
        // Three files under their temporary names, two folders under their own.
        #expect(marks.count == 5 && marks.values.allSatisfy { $0 == mark })
        #expect(marks.keys.filter { $0.contains(".afm-") }.count == 3)
        #expect(marks["/out/tree"] == mark && marks["/out/tree/sub"] == mark)
        // Asked once per source folder, not once per file.
        #expect(probe.count(of: "quarantine") == 2)
        #expect(target.contents("/out/tree/sub/c.txt") == "c")
    }

    @Test func nothingIsMarkedWhenTheSourceHasNoMarkOrTheCopyStaysInOneFileSystem() {
        let source = MemoryFileSystem(scheme: "mem")
        tree(in: source)
        let target = MemoryFileSystem(scheme: "arc")
        target.addDirectory("/out")
        runJob(
            .copy, [source.url("/src/tree")], to: TargetSpec(directory: target.url("/out")),
            fileSystems: registry(source, target))
        #expect(target.quarantineMarks.isEmpty)

        let marked = MemoryFileSystem(scheme: "mem")
        marked.quarantineValue = mark
        tree(in: marked)
        marked.addDirectory("/out")
        runJob(
            .copy, [marked.url("/src/tree")], to: TargetSpec(directory: marked.url("/out")),
            fileSystems: registry(marked))
        #expect(marked.quarantineMarks.isEmpty)
    }

    @Test func aResumedFileIsMarkedToo() {
        for continues in [true, false] {
            let source = MemoryFileSystem(scheme: "mem")
            source.quarantineValue = mark
            source.addFile("/s/file.txt", "hello world")
            let target = MemoryFileSystem(scheme: "arc")
            target.capabilities = continues ? [.write, .append] : [.write]
            target.addFile("/t/file.txt", "hello")
            let replies = Replies(.resume)
            runJob(
                .copy, [source.url("/s/file.txt")], to: TargetSpec(directory: target.url("/t")), replies: replies,
                fileSystems: registry(source, target))
            #expect(target.contents("/t/file.txt") == "hello world")
            // Continued in place the file has its name already; written anew it is marked under the temporary name.
            let marks = target.quarantineMarks
            #expect(marks.count == 1 && marks.values.first == mark)
            #expect(marks.keys.first?.contains(".afm-") == !continues)
            if continues { #expect(marks["/t/file.txt"] == mark) }
        }
    }
}

// MARK: - The measure cache

@Suite struct FileOpsAdoptMeasure {
    @Test func aBigFolderRenamedInsideAMergeIsNotCountedAgainEvenWhenTheCacheIsFull() {
        let base = MemoryFileSystem()
        for index in 1...5 { base.addFile("/src/A/small\(index)/one.txt") }
        for index in 0..<70 { base.addFile("/src/A/big/f\(index).txt") }
        base.addFile("/dst/A/existing.txt")
        let probe = ProbeFileSystem(base)
        let result = runJob(
            .move, [base.url("/src/A")], to: TargetSpec(directory: base.url("/dst")), replies: Replies(),
            fileSystems: registry(probe)
        ) {
            $0.rememberedLimit = 2
        }
        #expect(result.completed.count == 1)
        #expect(base.exists("/dst/A/big/f69.txt") && base.exists("/dst/A/existing.txt"))
        #expect(probe.count(of: "list /src/A/big") == 1)
    }
}

// MARK: - Selection and capabilities in the commands

@MainActor @Suite struct FileOpsAdoptSelection {
    @Test func processedItemsAreFoundByLocationWhoseNamesArePaths() {
        let inFolder = FileItem(url: URL(fileURLWithPath: "/x/sub/a.txt"), name: "sub/a.txt", isDirectory: false)
        let alsoNamedA = FileItem(url: URL(fileURLWithPath: "/x/a.txt"), name: "a.txt", isDirectory: false)
        let other = FileItem(url: URL(fileURLWithPath: "/x/other/b.txt"), name: "other/b.txt", isDirectory: false)
        let names = FileOperations.names(
            of: [URL(fileURLWithPath: "/x/sub/a.txt"), URL(fileURLWithPath: "/x/other/b.txt")],
            among: [inFolder, alsoNamedA, other])
        #expect(names == ["sub/a.txt", "other/b.txt"])
        #expect(FileOperations.names(of: [], among: [inFolder]).isEmpty)
    }
}

@MainActor @Suite struct FileOpsAdoptCapabilities {
    let memory = MemoryFileSystem()
    let bench: TestBench

    init() {
        memory.addFile("/A/one.txt")
        memory.addFile("/B/two.txt")
        memory.addFile("/R/ro.txt")
        // The file system as a whole can only write; one place has a Trash, another nothing at all.
        memory.capabilities = [.write]
        memory.capabilitiesAt = { url in
            url.path.hasPrefix("/R") ? [] : url.path.hasPrefix("/A") ? [.write, .trash] : [.write]
        }
        bench = TestBench(
            plugins: [FileOperationsPlugin(), ClipboardPlugin(), FilePropertiesPlugin()],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"), right: memory.url("/B"))
    }

    @Test func commandsFollowTheCapabilitiesOfTheFolderShown() {
        bench.left.show(memory.url("/R"))
        bench.left.moveCursor(toName: "ro.txt")
        for id in [CommandID.makeDirectory, .delete, .renameMove, .setAttributes] {
            #expect(!bench.commands.isEnabled(id), "\(id) in a folder nobody may change")
        }
        bench.left.show(memory.url("/A"))
        bench.left.moveCursor(toName: "one.txt")
        for id in [CommandID.makeDirectory, .delete, .renameMove, .setAttributes] {
            #expect(bench.commands.isEnabled(id), "\(id)")
        }
    }

    @Test func theTrashIsOfferedWhereTheItemsAreNotWhereTheFileSystemSaysInGeneral() {
        bench.left.moveCursor(toName: "one.txt")
        bench.ui.choiceAnswers = [1]
        bench.commands.perform(.delete)
        #expect(bench.ui.log.last?.contains("to the Trash") == true)

        bench.left.show(memory.url("/B"))
        bench.left.moveCursor(toName: "two.txt")
        bench.ui.choiceAnswers = [1]
        bench.commands.perform(.delete)
        #expect(bench.ui.log.last?.hasPrefix("choose: Permanently delete") == true)
    }
}
