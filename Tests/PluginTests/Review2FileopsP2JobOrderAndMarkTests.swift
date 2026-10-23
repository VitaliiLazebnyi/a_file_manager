import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// Second pass of review round 2 for the file-operation engine, second part: the order files are read in (A041),
/// the commit a paused job waits before (F046), origin marks (N009, F052), work that grows with the tree (F041,
/// F047), the provider-level `realLocation` and the rule for names.
@Suite
internal struct Review2FileopsP2JobOrderAndMarkTests {
    /// What every call of `ViewFileSystem` that the tests do not make throws.
    private struct Unused: Error {}

    /// A file system that only shows a folder of the local disk under a location of its own and
    /// says so through `realLocation(of:)`, and through nothing else: its `parent(of:)` gives
    /// nothing away.
    private final class ViewFileSystem: FileSystemProvider {
        let scheme = "p2view"
        let capabilities: FileSystemCapabilities = [.write]
        /// Unowned: the registry holds this file system.
        unowned let fileSystems: FileSystemRegistry

        init(fileSystems: FileSystemRegistry) { self.fileSystems = fileSystems }

        /// Where this file system shows the local folder `real`.
        func view(of real: URL) -> URL? {
            var components = URLComponents()
            components.scheme = scheme
            components.host = "shown"
            components.path = real.path
            return components.url
        }
        func realLocation(of url: URL) -> URL? { URL(fileURLWithPath: url.path) }
        func list(_: URL, showHidden _: Bool) throws -> [FileItem] { throw Unused() }
        func item(at _: URL) -> FileItem? { nil }
        func parent(of _: URL) -> URL? { nil }
        func read(_: URL) throws -> any FileReader { throw Unused() }
        func createDirectory(at _: URL) throws { throw Unused() }
        func write(_: URL) throws -> any FileWriter { throw Unused() }
        func remove(_: URL) throws { throw Unused() }
        func move(_: URL, to _: URL, replacing _: Bool) throws { throw Unused() }
        func copy(_: URL, to _: URL, progress _: (Int64) -> Bool) throws { throw Unused() }

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

    /// The origin mark of a file on the local disk, as text; nil when it has none.
    private static func quarantine(_ url: URL) -> String? {
        let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: size)
        let read = getxattr(url.path, "com.apple.quarantine", &bytes, size, 0, XATTR_NOFOLLOW)
        return read > 0 ? String(bytes: bytes.prefix(read), encoding: .utf8) : nil
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

    // MARK: A041 — files are read in the order their file system reads them best

    /// The sources' file system says in which order its files are read; an answer that is not the same files is
    /// not followed.
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
        let elsewhere = try #require(URL(string: "probe:///s/elsewhere.txt"))
        probe.order = { Array($0.dropLast()) + [elsewhere] }
        try box.folder("v")
        let unordered = job(.copy, sources, to: box.url("v"), replies: replies)
        // One after another, so that the order they are taken in shows: the order of their names.
        unordered.options.copiesSmallFilesInParallel = false
        result = unordered.run()
        #expect(probe.reads.suffix(3) == ["/s/a.txt", "/s/b.txt", "/s/c.txt"] && namesOnDisk(box.url("v")).count == 3)
        #expect(replies.errors.isEmpty)
    }

    // MARK: F046 — a paused job waits before the commit

    /// The commit is announced before it starts, so that a paused job waits there.
    @Test
    internal func theCommitIsAnnouncedBeforeItStartsSoThatAPausedJobWaitsThere() throws {
        memory.capabilities = [.write, .deferredWrites]
        memory.addDirectory("/t")
        let sources = [try box.file("s/a.txt", "a"), try box.file("s/b.txt", "b")]
        let replies = P2Replies()
        let committing = memory
        // What the delegate sees at each report: how many commits there have been by then.
        // A progress window holds the job inside a report while it is paused.
        replies.tag = { committing.commits.count }
        let result = job(.move, sources, to: memory.url("/t"), replies: replies).run()
        #expect(result.completed.count == 2 && memory.commits == ["/t"] && !box.exists("s/a.txt"))
        let announced = replies.progress.filter { $0.lines == ["Writing: mem:/t"] }
        #expect(!announced.isEmpty && announced.allSatisfy { $0.tag == 0 })
        // And the removals that follow the commit are reported one by one, as before.
        #expect(replies.progress.contains { $0.lines.first?.hasPrefix("Deleting: ") == true && $0.tag == 1 })
    }

    // MARK: N009 — the origin mark of what comes from a server or a marked archive

    /// What is copied, resumed, appended or moved from a marked file system carries the mark on disk.
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
        #expect(Self.quarantine(box.url("t/tool.command")) == mark)
        #expect(Self.quarantine(box.url("t/app/run.sh")) == mark && Self.quarantine(box.url("t/app")) == mark)
        // Resume: the file on disk is the beginning; what is added came from the server too.
        try box.file("t/part.bin", "0123")
        replies.conflict = .resume
        _ = job(.copy, [memory.url("/s/part.bin")], to: box.url("t"), replies: replies).run()
        #expect(box.read("t/part.bin") == "0123456789" && Self.quarantine(box.url("t/part.bin")) == mark)
        // Append: the longer file is written anew and takes the old one's place.
        try box.file("t/log.txt", "the log")
        replies.conflict = .append
        _ = job(.copy, [memory.url("/s/log.txt")], to: box.url("t"), replies: replies).run()
        #expect(box.read("t/log.txt") == "the log and more" && Self.quarantine(box.url("t/log.txt")) == mark)
        // A move is a copy and a removal: the mark is there as well.
        memory.addFile("/s/moved.sh", "x")
        replies.conflict = .overwrite
        _ = job(.move, [memory.url("/s/moved.sh")], to: box.url("t"), replies: replies).run()
        #expect(Self.quarantine(box.url("t/moved.sh")) == mark && !memory.exists("/s/moved.sh"))
        #expect(replies.errors.isEmpty)
        // No mark at the source, none on the copy.
        memory.quarantineValue = nil
        memory.addFile("/s2/plain.txt", "x")
        _ = job(.copy, [memory.url("/s2/plain.txt")], to: box.url("t"), replies: replies).run()
        #expect(box.exists("t/plain.txt") && Self.quarantine(box.url("t/plain.txt")) == nil)
    }

    /// A mark that cannot be set is counted and told at the end, not asked about (F052).
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

    /// The lines of a report are only put together when a report goes out.
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

    /// A folder that is skipped is not walked again for the count.
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

    /// A file system that says where its files really are is believed: a move into the file's own folder is
    /// refused.
    @Test
    internal func aFileSystemThatSaysWhereItsFilesReallyAreIsBelieved() throws {
        let view = ViewFileSystem(fileSystems: fileSystems)
        fileSystems.register(view)
        let file = try box.file("d/a.txt", "precious")
        let shown = try #require(view.view(of: box.url("d")))
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

    /// The job's rule for safe names is the kernel's.
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
