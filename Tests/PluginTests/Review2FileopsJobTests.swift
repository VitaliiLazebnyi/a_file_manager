import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing
import VirtualFoldersPlugin

@testable import FileOperationsPlugin

// Regression tests of review round 2 for the file-operation engine (findings F001 … F073 of
// documentation/review-2/findings/fileops.md).

/// A file system over memory whose reads can be made to fail or to cancel half-way, the way a
/// connection that breaks does.
/// Unchecked: what it records is guarded by `lock`; its switches are set by the test before use.
final class FlakyFileSystem: FileSystemProvider, @unchecked Sendable {
    let base = MemoryFileSystem(scheme: "flaky")
    var scheme: String { base.scheme }
    var capabilities: FileSystemCapabilities { [.write] }
    private let lock = NSLock()
    private var failures = 0
    /// Called once, after the first block of the next read.
    var afterFirstBlock: (() -> Void)?

    struct Broken: LocalizedError {
        var errorDescription: String? { "the connection broke" }
    }

    /// The next `count` readers fail after their first block.
    func failNextReads(_ count: Int) { lock.withLock { failures = count } }

    /// Unchecked: used by one thread at a time, as the protocol allows.
    private final class Reader: FileReader, @unchecked Sendable {
        let inner: any FileReader
        let fails: Bool
        let hook: (() -> Void)?
        var blocks = 0
        init(_ inner: any FileReader, fails: Bool, hook: (() -> Void)?) {
            (self.inner, self.fails, self.hook) = (inner, fails, hook)
        }
        func read(upToCount count: Int) throws -> Data? {
            if blocks == 1 {
                hook?()
                if fails { throw Broken() }
            }
            blocks += 1
            // Small blocks, so that a file has several.
            return try inner.read(upToCount: min(count, 4))
        }
        func seek(to offset: UInt64) throws { try inner.seek(to: offset) }
        func close() { inner.close() }
    }

    func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try base.list(directory, showHidden: showHidden)
    }
    func item(at url: URL) -> FileItem? { base.item(at: url) }
    func parent(of directory: URL) -> URL? { base.parent(of: directory) }
    func read(_ url: URL) throws -> any FileReader {
        let (fails, hook): (Bool, (() -> Void)?) = lock.withLock {
            defer { afterFirstBlock = nil }
            if failures > 0 {
                failures -= 1
                return (true, afterFirstBlock)
            }
            return (false, afterFirstBlock)
        }
        return Reader(try base.read(url), fails: fails, hook: hook)
    }
    func createDirectory(at url: URL) throws { base.createDirectory(at: url) }
    func write(_ url: URL) throws -> any FileWriter { try base.write(url) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try base.move(source, to: destination, replacing: replacing)
    }
    func copy(_: URL, to _: URL, progress _: (Int64) -> Bool) throws {
        throw FileSystemError.crossesVolumes
    }
    func displayPath(_ url: URL) -> String { base.displayPath(url) }
    func location(from text: String) -> URL? { base.location(from: text) }
    func volume(of url: URL) -> VolumeInfo? { base.volume(of: url) }
}

/// Answers a job's questions with fixed choices, from whatever thread they come.
/// Unchecked: what it records is guarded by `lock`; the choices are set by the test before use.
final class Review2Replies: FileJobDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var failureAnswers: [ErrorChoice]
    private(set) var errors: [String] = []
    private(set) var conflicts: [String] = []
    private(set) var volumes: [String] = []
    private(set) var locked = 0
    var conflict: ConflictChoice
    var volume: ProtectionChoice

    /// `failures`: the answers to the errors in turn; the last one holds for the rest.
    init(conflict: ConflictChoice = .overwrite, failures: [ErrorChoice] = [.skip], volume: ProtectionChoice = .skip) {
        (self.conflict, failureAnswers, self.volume) = (conflict, failures, volume)
    }

    func job(_: FileJob, progress _: JobProgress) {}
    func job(_: FileJob, conflictAt target: FileItem, source _: FileItem) -> ConflictChoice {
        lock.withLock { conflicts.append(target.name) }
        return conflict
    }
    func job(_: FileJob, failedAt _: URL, error: any Error) -> ErrorChoice {
        lock.withLock {
            errors.append(error.localizedDescription)
            return failureAnswers.count > 1 ? failureAnswers.removeFirst() : failureAnswers[0]
        }
    }
    func job(_: FileJob, confirmDeleteNonEmpty _: URL) -> FolderDeleteChoice { .delete }
    func job(_: FileJob, confirm question: ProtectionQuestion) -> ProtectionChoice {
        if question.reason == .locked { lock.withLock { locked += 1 } }
        return .proceed
    }
    func job(_: FileJob, crossVolumeAt folder: FileItem, purpose _: ProtectionQuestion.Purpose) -> ProtectionChoice {
        lock.withLock { volumes.append(folder.name) }
        return volume
    }
}

private func inode(_ url: URL) -> UInt64? {
    var info = stat()
    return lstat(url.path, &info) == 0 ? UInt64(info.st_ino) : nil
}

private func mode(_ url: URL) -> UInt16? {
    var info = stat()
    return lstat(url.path, &info) == 0 ? UInt16(info.st_mode & 0o7777) : nil
}

/// Runs `work` on another thread and waits for it; if it does not end in `seconds`, `rescue`
/// is called (to free whatever it hangs on) and false comes back. The time only matters when
/// the code under test hangs, which is the failure the test is there to catch.
private func finishes(within seconds: TimeInterval = 60, rescue: () -> Void, _ work: @escaping @Sendable () -> Void)
    -> Bool
{
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        work()
        done.signal()
    }
    if done.wait(timeout: .now() + seconds) == .success { return true }
    rescue()
    _ = done.wait(timeout: .now() + 10)
    return false
}

@Suite struct Review2FileopsBranchView {
    let box: Sandbox
    let fileSystems = FileSystemRegistry()
    let virtual: VirtualFileSystem

    init() throws {
        box = try Sandbox()
        fileSystems.register(LocalFileSystem())
        virtual = VirtualFileSystem(fileSystems: fileSystems)
        fileSystems.register(virtual)
    }

    private func run(
        _ kind: JobKind, _ sources: [URL], to target: TargetSpec, replies: Review2Replies = Review2Replies(),
        configure: (FileJob) -> Void = { _ in }
    ) -> JobResult {
        let job = FileJob(kind: kind, sources: sources, target: target, fileSystems: fileSystems)
        job.delegate = replies
        configure(job)
        return job.run()
    }

    // F001, F018
    @Test func movingAFileOntoItselfThroughABranchViewKeepsTheFile() throws {
        let file = try box.file("d/a.txt", "precious")
        let replies = Review2Replies()
        let result = run(.move, [file], to: TargetSpec(directory: virtual.branch(of: box.url("d"))), replies: replies)
        #expect(box.read("d/a.txt") == "precious")
        #expect(result.completed.isEmpty && replies.errors == ["You cannot copy a file to itself!"])
        #expect(namesOnDisk(box.url("d")) == ["a.txt"])
    }

    @Test func aTargetInABranchViewIsTheRealFolder() throws {
        let job = FileJob(
            kind: .move, sources: [try box.file("d/a.txt")],
            target: TargetSpec(directory: virtual.branch(of: box.url("d"))),
            fileSystems: fileSystems)
        #expect(job.target?.directory.isFileURL == true && job.target?.directory.path == box.url("d").path)
        #expect(job.targetsSourceFolder)
        #expect(RealLocation.resolve(box.url("d"), in: fileSystems) == box.url("d"))
        // A list of files has no folder of its own, and no name can be written into it.
        let list = virtual.register(files: [box.url("d/a.txt")], title: "Found", origin: box.url("d"))
        #expect(RealLocation.resolve(list, in: fileSystems) == list)
        #expect(
            !RealLocation.takesNames(list, in: fileSystems) && RealLocation.takesNames(box.url("d"), in: fileSystems))
    }

    @Test func aRenameToAnotherLetterCaseInABranchViewIsARename() throws {
        let file = try box.file("d/a.txt", "precious")
        let before = try #require(inode(file))
        let replies = Review2Replies()
        let result = run(
            .move, [file], to: TargetSpec(directory: virtual.branch(of: box.url("d")), exactName: "A.TXT"),
            replies: replies)
        #expect(replies.errors.isEmpty && replies.conflicts.isEmpty && result.completed.count == 1)
        #expect(namesOnDisk(box.url("d")) == ["A.TXT"] && box.read("d/A.TXT") == "precious")
        // The same file, renamed: not a copy that took its place.
        #expect(inode(box.url("d/A.TXT")) == before)
    }

    @Test func aPlainRenameInABranchViewIsARenameNotACopy() throws {
        let file = try box.file("d/a.txt", "precious")
        let before = try #require(inode(file))
        #expect(setxattr(file.path, "user.afm.test", "v", 1, 0, 0) == 0)
        let result = run(
            .move, [file], to: TargetSpec(directory: virtual.branch(of: box.url("d")), exactName: "b.txt"))
        #expect(result.completed.count == 1 && namesOnDisk(box.url("d")) == ["b.txt"])
        #expect(inode(box.url("d/b.txt")) == before)
        #expect(getxattr(box.url("d/b.txt").path, "user.afm.test", nil, 0, 0, 0) == 1)
    }

    @Test func aFolderIsNotMovedIntoItselfThroughABranchView() throws {
        try box.file("d/sub/in.txt", "inside")
        let replies = Review2Replies()
        // Into itself under its own name, and into its own subfolder.
        _ = run(
            .move, [box.url("d/sub")], to: TargetSpec(directory: virtual.branch(of: box.url("d"))), replies: replies)
        _ = run(
            .move, [box.url("d/sub")], to: TargetSpec(directory: virtual.branch(of: box.url("d/sub"))),
            replies: replies)
        #expect(box.read("d/sub/in.txt") == "inside" && replies.errors.count == 2)
    }

    @Test func copyingOntoItselfThroughABranchViewIsRefused() throws {
        let file = try box.file("d/a.txt", "precious")
        let replies = Review2Replies()
        _ = run(.copy, [file], to: TargetSpec(directory: virtual.branch(of: box.url("d"))), replies: replies)
        #expect(box.read("d/a.txt") == "precious" && replies.errors == ["You cannot copy a file to itself!"])
        #expect(namesOnDisk(box.url("d")) == ["a.txt"])
    }

    @Test func aHardLinkOfTheSourceIsNotOverwrittenWithItself() throws {
        let file = try box.file("d/a.txt", "precious")
        try box.folder("t")
        try FileManager.default.linkItem(at: file, to: box.url("t/a.txt"))
        let replies = Review2Replies()
        _ = run(.move, [file], to: TargetSpec(directory: box.url("t")), replies: replies) {
            $0.options.overwrite = .overwriteAll
        }
        #expect(box.read("d/a.txt") == "precious" && box.read("t/a.txt") == "precious" && replies.errors.count == 1)
    }

    // F006: a rename of several items to one name.
    @Test func severalItemsRenamedToOneNameAreAllKept() throws {
        let sources = [
            try box.file("d/a.doc", "doc"), try box.file("d/a.pdf", "pdf"), try box.file("d/sub/a.rtf", "rtf")
        ]
        let replies = Review2Replies()
        let result = run(.move, sources, to: TargetSpec(directory: box.url("d")), replies: replies) { job in
            job.newNames = Dictionary(uniqueKeysWithValues: sources.map { ($0.locationKey, "a.txt") })
            job.options.overwrite = .overwriteAll
        }
        #expect(result.completed.count == 3 && replies.conflicts.isEmpty)
        // Each stays in its own folder; the two of one folder both survive.
        #expect(namesOnDisk(box.url("d")) == ["a (2).txt", "a.txt", "sub"] && box.read("d/sub/a.txt") == "rtf")
        #expect(Set([box.read("d/a.txt"), box.read("d/a (2).txt")]) == ["doc", "pdf"])
    }
}

@Suite struct Review2FileopsJob {
    let box: Sandbox

    init() throws {
        box = try Sandbox()
    }

    // MARK: F007, F017

    @Test func aPipeInAStreamedCopyIsReportedAndNeverOpened() throws {
        let (fileSystems, memory) = makeFileSystems()
        try box.file("s/real.txt", "data")
        let pipe = box.url("s/pipe")
        #expect(mkfifo(pipe.path, 0o644) == 0)
        try FileManager.default.createSymbolicLink(at: box.url("s/toPipe"), withDestinationURL: pipe)
        memory.addDirectory("/t")
        let replies = Review2Replies()
        let ended = finishes(rescue: {
            // Opening the other end lets a reader that hangs go on.
            let descriptor = open(pipe.path, O_WRONLY | O_NONBLOCK)
            if descriptor >= 0 { close(descriptor) }
        }) {
            let job = FileJob(
                kind: .copy, sources: [box.url("s")], target: TargetSpec(directory: memory.url("/t")),
                fileSystems: fileSystems)
            job.delegate = replies
            _ = job.run()
        }
        #expect(ended, "the copy of a folder with a pipe did not end")
        #expect(
            memory.contents("/t/s/real.txt") == "data" && !memory.exists("/t/s/pipe") && !memory.exists("/t/s/toPipe"))
        #expect(replies.errors.count == 2 && replies.errors.allSatisfy { $0.contains("pipe") })
    }

    @Test func aPipeIsNotReadForAChecksumOrACopyThatFollowsLinks() throws {
        let (fileSystems, _) = makeFileSystems()
        let pipe = box.url("pipe")
        #expect(mkfifo(pipe.path, 0o644) == 0)
        try box.folder("s")
        try FileManager.default.createSymbolicLink(at: box.url("s/link"), withDestinationURL: pipe)
        #expect(throws: FileJobError.self) { _ = try Checksum.sha256(of: pipe, in: fileSystems) }
        #expect(throws: FileJobError.self) { _ = try Checksum.sha256(of: box.url("s/link"), in: fileSystems) }
        try box.folder("t")
        let replies = Review2Replies()
        let ended = finishes(rescue: {
            let descriptor = open(pipe.path, O_WRONLY | O_NONBLOCK)
            if descriptor >= 0 { close(descriptor) }
        }) {
            let job = FileJob(
                kind: .copy, sources: [box.url("s/link")], target: TargetSpec(directory: box.url("t")),
                fileSystems: fileSystems)
            job.options.links = .followLinks
            job.delegate = replies
            _ = job.run()
        }
        #expect(ended && replies.errors.count == 1 && namesOnDisk(box.url("t")).isEmpty)
        // Where links are copied as links, a link to a pipe is just a link.
        runJob(.copy, [box.url("s/link")], to: TargetSpec(directory: box.url("t")), fileSystems: fileSystems)
        #expect(FileIdentity.isSymlink(box.url("t/link")))
    }

    // MARK: F006, F013

    @Test func equallyNamedSourcesFromTwoFoldersBothArriveUnderOverwriteAll() throws {
        let (fileSystems, _) = makeFileSystems()
        let sources = [try box.file("s/a/x.txt", "from-a"), try box.file("s/b/x.txt", "from-b")]
        try box.folder("t")
        let answers = Answers()
        let job = FileJob(
            kind: .move, sources: sources, target: TargetSpec(directory: box.url("t")), fileSystems: fileSystems)
        job.options.overwrite = .overwriteAll
        job.delegate = answers
        let result = job.run()
        #expect(result.completed.count == 2 && answers.conflicts.isEmpty && answers.errors.isEmpty)
        #expect(namesOnDisk(box.url("t")) == ["x (2).txt", "x.txt"])
        #expect(Set([box.read("t/x.txt"), box.read("t/x (2).txt")]) == ["from-a", "from-b"])
        #expect(!box.exists("s/a/x.txt") && !box.exists("s/b/x.txt"))
    }

    @Test func aMaskThatGivesSeveralSourcesOneNameLosesNone() throws {
        let (fileSystems, _) = makeFileSystems()
        let sources = [
            try box.file("s/a.doc", "doc"), try box.file("s/a.pdf", "pdf"), try box.file("s/a.rtf", "rtf")
        ]
        try box.folder("t")
        for mode in [OverwriteMode.overwriteAll, .overwriteOlder, .overwriteOlderOrSame, .copyLarger] {
            let target = box.url("t/\(mode.rawValue)")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let job = FileJob(
                kind: .copy, sources: sources, target: TargetSpec(directory: target, mask: "*.txt"),
                fileSystems: fileSystems)
            job.options.overwrite = mode
            let answers = Answers()
            job.delegate = answers
            _ = job.run()
            #expect(namesOnDisk(target) == ["a (2).txt", "a (3).txt", "a.txt"], "mode \(mode)")
            #expect(
                Set(
                    namesOnDisk(target).map {
                        try? String(contentsOf: target.appendingPathComponent($0), encoding: .utf8)
                    }) == ["doc", "pdf", "rtf"])
        }
    }

    @Test func anAnswerForAllDoesNotOverwriteTheJobsOwnFileButAnAnswerForOneDoes() throws {
        let (fileSystems, _) = makeFileSystems()
        let sources = [try box.file("s/a/x.txt", "from-a"), try box.file("s/b/x.txt", "from-b")]
        try box.folder("t")
        try box.folder("u")
        // In "ask" mode the question comes; "Overwrite all" is a rule, and no rule destroys the job's own file.
        let all = Answers()
        all.conflict = .overwriteAll
        runJob(.copy, sources, to: TargetSpec(directory: box.url("t")), answers: all, fileSystems: fileSystems)
        #expect(all.conflicts == ["x.txt"] && namesOnDisk(box.url("t")) == ["x (2).txt", "x.txt"])
        // "Overwrite" for this one file is what the user said about exactly this file.
        let one = Answers()
        one.conflict = .overwrite
        runJob(.copy, sources, to: TargetSpec(directory: box.url("u")), answers: one, fileSystems: fileSystems)
        #expect(one.conflicts == ["x.txt"] && namesOnDisk(box.url("u")) == ["x.txt"])
    }

    @Test func twoSourceFoldersThatLandInOneTargetFolderKeepEachOthersFiles() throws {
        let (fileSystems, _) = makeFileSystems()
        try box.file("s/one/sub/x.txt", "first")
        try box.file("s/one/sub/only1.txt", "1")
        try box.file("s/two/sub/x.txt", "second")
        try box.file("t/sub/old.txt", "old")
        let job = FileJob(
            kind: .move, sources: [box.url("s/one/sub"), box.url("s/two/sub")],
            target: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems)
        job.options.overwrite = .overwriteAll
        let answers = Answers()
        job.delegate = answers
        _ = job.run()
        #expect(namesOnDisk(box.url("t/sub")) == ["old.txt", "only1.txt", "x (2).txt", "x.txt"])
        #expect(Set([box.read("t/sub/x.txt"), box.read("t/sub/x (2).txt")]) == ["first", "second"])
    }

    @Test func aFileThatWasThereBeforeTheJobIsStillOverwrittenByTheRule() throws {
        let (fileSystems, _) = makeFileSystems()
        try box.file("s/x.txt", "new")
        try box.file("t/x.txt", "old")
        let job = FileJob(
            kind: .copy, sources: [box.url("s/x.txt")], target: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems)
        job.options.overwrite = .overwriteAll
        _ = job.run()
        #expect(namesOnDisk(box.url("t")) == ["x.txt"] && box.read("t/x.txt") == "new")
    }

    // MARK: F022, F033

    @Test func resumeAndAppendNeverWriteThroughALinkAtTheTarget() throws {
        let (fileSystems, memory) = makeFileSystems()
        let victim = try box.file("elsewhere/victim.txt", "the victim's own, longer contents: fifty-three bytes.")
        try box.file("s/f.txt", String(repeating: "source-bytes ", count: 20))
        memory.addFile("/s/f.txt", String(repeating: "source-bytes ", count: 20))
        try box.folder("t")
        try FileManager.default.createSymbolicLink(at: box.url("t/f.txt"), withDestinationURL: victim)
        for (choice, source) in [
            (ConflictChoice.resume, box.url("s/f.txt")), (.append, box.url("s/f.txt")),
            (.resume, memory.url("/s/f.txt")),
            (.append, memory.url("/s/f.txt"))
        ] {
            let replies = Review2Replies(conflict: choice)
            let job = FileJob(
                kind: .copy, sources: [source], target: TargetSpec(directory: box.url("t")), fileSystems: fileSystems)
            job.delegate = replies
            let result = job.run()
            #expect(
                box.read("elsewhere/victim.txt") == "the victim's own, longer contents: fifty-three bytes.",
                "\(choice)")
            #expect(FileIdentity.isSymlink(box.url("t/f.txt")) && result.completed.isEmpty && replies.errors.count == 1)
        }
    }

    @Test func resumeByWritingAnewChecksThatTheTargetIsTheStartOfTheSource() throws {
        // A file system that cannot continue a file: the longer file is written next to the old one.
        let fileSystems = FileSystemRegistry()
        let flaky = FlakyFileSystem()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(flaky)
        try box.file("s/f.txt", "0123456789")
        flaky.base.addFile("/t/f.txt", "0123")
        flaky.base.addFile("/u/f.txt", "9999")
        let good = Review2Replies(conflict: .resume)
        var job = FileJob(
            kind: .copy, sources: [box.url("s/f.txt")], target: TargetSpec(directory: flaky.base.url("/t")),
            fileSystems: fileSystems)
        job.delegate = good
        _ = job.run()
        #expect(flaky.base.contents("/t/f.txt") == "0123456789" && good.errors.isEmpty)
        let bad = Review2Replies(conflict: .resume)
        job = FileJob(
            kind: .copy, sources: [box.url("s/f.txt")], target: TargetSpec(directory: flaky.base.url("/u")),
            fileSystems: fileSystems)
        job.delegate = bad
        _ = job.run()
        #expect(flaky.base.contents("/u/f.txt") == "9999" && bad.errors.count == 1)
    }

    // MARK: F032, F044

    @Test func aRefusedDeleteNeverChangesTheTargetOfALinkOrAFileThatIsNotLocked() throws {
        let (fileSystems, _) = makeFileSystems()
        let key = try box.file("private/key.pem", "secret")
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: key.path)
        let plain = try box.file("locked/plain.txt", "x")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: plain.path)
        try FileManager.default.createSymbolicLink(at: box.url("locked/link"), withDestinationURL: key)
        // A locked folder refuses to let go of its entries with "operation not permitted".
        #expect(chflags(box.url("locked").path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(box.url("locked").path, 0) }
        let replies = Review2Replies()
        let job = FileJob(
            kind: .delete(toTrash: false), sources: [box.url("locked/link"), plain], fileSystems: fileSystems)
        job.options.asksAboutReadOnly = false
        job.delegate = replies
        let result = job.run()
        #expect(result.completed.isEmpty && replies.errors.count == 2)
        // Neither is locked itself: nobody is asked to unlock, and nothing is made writable.
        #expect(replies.locked == 0)
        #expect(mode(key) == 0o400 && mode(plain) == 0o444 && FileIdentity.isSymlink(box.url("locked/link")))
    }

    @Test func aLockedFileIsStillUnlockedAndDeletedWhenTheUserAgrees() throws {
        let (fileSystems, _) = makeFileSystems()
        let file = try box.file("d/locked.txt", "x")
        #expect(chflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(file.path, 0) }
        let replies = Review2Replies()
        let job = FileJob(kind: .delete(toTrash: false), sources: [file], fileSystems: fileSystems)
        job.delegate = replies
        #expect(job.run().completed.count == 1 && replies.locked == 1 && !box.exists("d/locked.txt"))
    }

    // MARK: F023, F072

    @Test func agesAreComparedExactlyWhereTheVolumesKeepThemExactly() throws {
        let (fileSystems, _) = makeFileSystems()
        // The scratch folder is on APFS on every Mac this runs on; on anything coarser the test says nothing.
        guard FileIdentity.timestampGrain(of: box.root) == 0 else { return }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try box.file("s/newer.txt", "new", modified: base.addingTimeInterval(1.5))
        try box.file("t/newer.txt", "old", modified: base)
        try box.file("s/same.txt", "new", modified: base)
        try box.file("t/same.txt", "old", modified: base.addingTimeInterval(1.5))
        var job = FileJob(
            kind: .copy, sources: [box.url("s/newer.txt")], target: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems)
        job.options.overwrite = .overwriteOlder
        _ = job.run()
        // A source that is a second and a half newer is newer.
        #expect(box.read("t/newer.txt") == "new")
        job = FileJob(
            kind: .copy, sources: [box.url("s/same.txt")], target: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems)
        job.options.overwrite = .overwriteOlderOrSame
        _ = job.run()
        // And a target that is a second and a half newer is not "of the same age".
        #expect(box.read("t/same.txt") == "old")
    }

    @Test func theGrainOfAVolumeDecidesTheTolerance() {
        let (_, memory) = makeFileSystems()
        #expect(FileIdentity.timestampGrain(of: memory.url("/a/b.txt")) == 2)
        // A place that does not exist yet answers for the folder above it.
        #expect(
            FileIdentity.timestampGrain(of: box.url("no/such/file.txt")) == FileIdentity.timestampGrain(of: box.root))
    }

    // MARK: F019, F031

    @Test func aLinkBackToAFolderItLiesInIsSeenThroughAnotherLink() throws {
        let (fileSystems, _) = makeFileSystems()
        try box.file("Y/f.txt", "inside")
        try FileManager.default.createSymbolicLink(atPath: box.url("Y/m").path, withDestinationPath: ".")
        try box.folder("s")
        try FileManager.default.createSymbolicLink(at: box.url("s/X"), withDestinationURL: box.url("Y"))
        try box.folder("t")
        let job = FileJob(
            kind: .copy, sources: [box.url("s")], target: TargetSpec(directory: box.url("t")), fileSystems: fileSystems
        )
        job.options.links = .followLinks
        let answers = Answers()
        job.delegate = answers
        let result = job.run()
        #expect(result.completed.count == 1 && answers.errors.isEmpty)
        // One copy of the folder; the link that leads back into it stays a link.
        #expect(box.read("t/s/X/f.txt") == "inside" && FileIdentity.isSymlink(box.url("t/s/X/m")))
        #expect(namesOnDisk(box.url("t/s/X")) == ["f.txt", "m"])
    }

    // MARK: F024, F073 and what a cancel may remove

    @Test func aRetryAfterAKeptPartialFileCompletesTheCopy() throws {
        let fileSystems = FileSystemRegistry()
        let flaky = FlakyFileSystem()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(flaky)
        flaky.base.addFile("/s/big.bin", "0123456789abcdef")
        try box.folder("t")
        flaky.failNextReads(1)
        let replies = Review2Replies(failures: [.retry, .skip])
        let job = FileJob(
            kind: .copy, sources: [flaky.base.url("/s/big.bin")], target: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems)
        job.options.keepsPartialFiles = true
        job.delegate = replies
        let result = job.run()
        #expect(replies.errors == ["the connection broke"])
        #expect(
            result.completed.count == 1 && box.read("t/big.bin") == "0123456789abcdef"
                && namesOnDisk(box.url("t")) == ["big.bin"])
    }

    @Test func aSkipAfterAFailedCopyKeepsThePartialFileWhenAskedTo() throws {
        let fileSystems = FileSystemRegistry()
        let flaky = FlakyFileSystem()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(flaky)
        flaky.base.addFile("/s/big.bin", "0123456789abcdef")
        try box.folder("t")
        flaky.failNextReads(1)
        let job = FileJob(
            kind: .copy, sources: [flaky.base.url("/s/big.bin")], target: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems)
        job.options.keepsPartialFiles = true
        let replies = Review2Replies()
        job.delegate = replies
        _ = job.run()
        #expect(box.read("t/big.bin") == "0123" && replies.errors.count == 1)
    }

    @Test func aCancelledOrFailedOverwriteLeavesTheFileThatWasThere() throws {
        let fileSystems = FileSystemRegistry()
        let flaky = FlakyFileSystem()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(flaky)
        flaky.base.addFile("/s/big.bin", "0123456789abcdef")
        for keepsPartial in [false, true] {
            try box.file("t/big.bin", "the old file")
            let flag = CancellationFlag()
            flaky.afterFirstBlock = { flag.cancel() }
            let job = FileJob(
                kind: .copy, sources: [flaky.base.url("/s/big.bin")], target: TargetSpec(directory: box.url("t")),
                fileSystems: fileSystems, cancellation: flag)
            job.options.keepsPartialFiles = keepsPartial
            job.options.overwrite = .overwriteAll
            let result = job.run()
            #expect(
                result.cancelled && box.read("t/big.bin") == "the old file" && namesOnDisk(box.url("t")) == ["big.bin"])
            // The same when the copy fails and is retried: the old file is there until the new one is whole.
            flaky.failNextReads(1)
            let replies = Review2Replies(failures: [.skip])
            let failing = FileJob(
                kind: .copy, sources: [flaky.base.url("/s/big.bin")], target: TargetSpec(directory: box.url("t")),
                fileSystems: fileSystems)
            failing.options.keepsPartialFiles = keepsPartial
            failing.options.overwrite = .overwriteAll
            failing.delegate = replies
            _ = failing.run()
            #expect(box.read("t/big.bin") == "the old file" && namesOnDisk(box.url("t")) == ["big.bin"])
        }
    }

    // MARK: F046, F045, F049, F053, F051, F021

    @Test func abortAlsoSetsTheJobsOwnFlagSoThatNothingWaitsOnIt() {
        let (fileSystems, memory) = makeFileSystems()
        let flag = CancellationFlag()
        let job = FileJob(
            kind: .copy, sources: [memory.url("/gone.txt")], target: TargetSpec(directory: box.root),
            fileSystems: fileSystems,
            cancellation: flag)
        let replies = Review2Replies(failures: [.abort])
        job.delegate = replies
        #expect(job.run().cancelled && flag.isCancelled)
    }

    @Test func recordsNobodyWantsAreNotMade() throws {
        let (fileSystems, _) = makeFileSystems()
        try box.file("s/a.txt")
        try box.file("s/sub/b.txt")
        try box.folder("t")
        let lock = NSLock()
        // Guarded by `lock`.
        nonisolated(unsafe) var verbs: [OperationRecord.Verb] = []
        let job = FileJob(
            kind: .copy, sources: [box.url("s")], target: TargetSpec(directory: box.url("t")), fileSystems: fileSystems
        )
        job.wantsRecord = { verb, _ in verb == .makeFolder }
        job.onRecord = { record in lock.withLock { verbs.append(record.verb) } }
        _ = job.run()
        #expect(verbs == [.makeFolder, .makeFolder])
        // What the log's own filter says for a record and before the record is made is the same.
        var configuration = OperationLog.Configuration()
        configuration.logsFolders = false
        #expect(!configuration.wants(.makeFolder, .done) && configuration.wants(.copy, .skipped))
        #expect(configuration.wants(OperationRecord(.copy, source: "a")) == configuration.wants(.copy, .done))
    }

    @Test func aSourceWhoseNameLeadsOutOfItsFolderIsRefused() throws {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/A/keep.txt", "keep")
        memory.addDirectory("/B")
        let hostile = try #require(URL(string: memory.url("/A").absoluteString + "/.."))
        #expect(hostile.lastPathComponent == "..")
        for kind in [JobKind.copy, .move, .delete(toTrash: false)] {
            let replies = Review2Replies()
            let job = FileJob(
                kind: kind, sources: [hostile],
                target: kind == .delete(toTrash: false) ? nil : TargetSpec(directory: memory.url("/B")),
                fileSystems: fileSystems)
            job.delegate = replies
            let result = job.run()
            #expect(result.completed.isEmpty && replies.errors.count == 1 && memory.contents("/A/keep.txt") == "keep")
        }
        #expect((try? memory.list(memory.url("/B"), showHidden: true))?.isEmpty == true)
    }

    @Test func rightsFromAnotherFileSystemArriveWithoutSpecialBitsAndUnderTheUmask() throws {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/s/tool", "#!", permissions: 0o6777)
        memory.addFile("/s/plain.txt", "x", permissions: 0o640)
        try box.folder("t")
        runJob(
            .copy, [memory.url("/s/tool"), memory.url("/s/plain.txt")], to: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems)
        let mask = umask(0o022)
        umask(mask)
        #expect(mode(box.url("t/tool")) == 0o777 & ~UInt16(mask))
        #expect(mode(box.url("t/plain.txt")) == 0o640 & ~UInt16(mask))
        // To a file system that is not the local disk, only the three special bits stay behind.
        memory.addFile("/odd/tool", "#!", permissions: 0o4755)
        let other = MemoryFileSystem(scheme: "other")
        fileSystems.register(other)
        other.addDirectory("/t")
        runJob(.copy, [memory.url("/odd/tool")], to: TargetSpec(directory: other.url("/t")), fileSystems: fileSystems)
        #expect(other.item(at: other.url("/t/tool"))?.permissions == 0o755)
    }

    // F050
    @Test func aLockedSourceOfAMoveToAnotherFileSystemIsAskedAboutLikeADelete() throws {
        let (fileSystems, memory) = makeFileSystems()
        let file = try box.file("s/locked.txt", "contents")
        #expect(chflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(file.path, 0) }
        memory.addDirectory("/t")
        let replies = Review2Replies()
        let job = FileJob(
            kind: .move, sources: [file], target: TargetSpec(directory: memory.url("/t")), fileSystems: fileSystems)
        job.delegate = replies
        let result = job.run()
        #expect(replies.locked == 1 && replies.errors.isEmpty && result.completed.count == 1)
        #expect(memory.contents("/t/locked.txt") == "contents" && !box.exists("s/locked.txt"))
    }

    // F054
    @Test func anAppendedFileKeepsWhatTheOldOneCarriedBesidesItsContents() throws {
        let (fileSystems, memory) = makeFileSystems()
        try box.file("s/log.txt", "-more")
        memory.addFile("/t/log.txt", "start")
        memory.keepsMetadata = true
        let replies = Review2Replies(conflict: .append)
        let job = FileJob(
            kind: .copy, sources: [box.url("s/log.txt")], target: TargetSpec(directory: memory.url("/t")),
            fileSystems: fileSystems)
        job.delegate = replies
        _ = job.run()
        #expect(memory.contents("/t/log.txt") == "start-more" && replies.errors.isEmpty)
        // Tags, access rules and the date of creation of the old file were handed to the new one.
        #expect(memory.metadataCopies.contains { $0.from.path == "/t/log.txt" })
    }

    // F048
    @Test func aSourceOnAServerIsAskedAboutOnceNotThreeTimes() throws {
        /// Unchecked: what it records is guarded by `lock`; its switches are set by the test before use.
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
            func createDirectory(at url: URL) throws { base.createDirectory(at: url) }
            func write(_ url: URL) throws -> any FileWriter { try base.write(url) }
            func remove(_ url: URL) throws { try base.remove(url) }
            func move(_ source: URL, to destination: URL, replacing: Bool) throws {
                try base.move(source, to: destination, replacing: replacing)
            }
            func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
                try base.copy(source, to: destination, progress: progress)
            }
        }
        let fileSystems = FileSystemRegistry()
        let server = Counting()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(server)
        server.base.addFile("/s/a.txt", "a")
        server.base.addFile("/s/b.txt", "b")
        try box.folder("t")
        let result = runJob(
            .copy, [server.base.url("/s/a.txt"), server.base.url("/s/b.txt")], to: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems)
        #expect(result.completed.count == 2 && box.read("t/b.txt") == "b")
        #expect(server.lookups("/s/a.txt") == 1 && server.lookups("/s/b.txt") == 1)
    }

    @Test func oldTemporaryFilesAreSweptAndNothingElse() throws {
        let stale = ".afm-\(UUID().uuidString).tmp"
        try box.file("t/\(stale)", "half a copy")
        try box.file("t/.afm-not-a-uuid.tmp", "mine")
        try box.file("t/keep.txt", "keep")
        try box.folder("t/.afm-\(UUID().uuidString).tmp")
        #expect(
            FileJob.isTemporaryName(stale) && !FileJob.isTemporaryName(".afm-not-a-uuid.tmp")
                && !FileJob.isTemporaryName("a.tmp"))
        // Fresh: it may belong to a copy that is running.
        FileJob.sweepStaleTemporaries(in: box.url("t"))
        #expect(box.exists("t/\(stale)"))
        FileJob.sweepStaleTemporaries(in: box.url("t"), now: Date().addingTimeInterval(FileJob.staleTemporaryAge + 60))
        #expect(!box.exists("t/\(stale)"))
        #expect(
            namesOnDisk(box.url("t")).count == 3 && box.read("t/keep.txt") == "keep"
                && box.read("t/.afm-not-a-uuid.tmp") == "mine")
    }

    @Test func aTreeAsDeepAsPathsAllowIsCopiedAndDeleted() throws {
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
        let result = runJob(
            .move, [box.url("s")], to: TargetSpec(directory: box.url("t/x")), answers: answers,
            fileSystems: fileSystems)
        #expect(levels > 300 && result.completed.count == 1 && answers.errors.isEmpty && !box.exists("s"))
        // Copied level by level (a folder with a filter is never moved whole), then deleted.
        let copy = FileJob(
            kind: .copy, sources: [box.url("t/x/s")], target: TargetSpec(directory: box.root), fileSystems: fileSystems
        )
        copy.options.filter = CopyFilter("*")
        copy.delegate = answers
        #expect(copy.run().completed.count == 1 && answers.errors.isEmpty)
        #expect((try? String(contentsOf: URL(fileURLWithPath: deep.path + "/b"), encoding: .utf8)) == "bottom")
        let delete = runJob(
            .delete(toTrash: false), [box.url("s"), box.url("t")], answers: answers, fileSystems: fileSystems)
        #expect(delete.completed.count == 2 && answers.errors.isEmpty && namesOnDisk(box.root).isEmpty)
    }

    @Test func aTreeDeeperThanTheLimitIsReportedNotEntered() {
        let (fileSystems, memory) = makeFileSystems()
        let limit = 12
        var path = "/deep"
        for _ in 0..<limit + 8 { path += "/d" }
        memory.addFile(path + "/bottom.txt", "bottom")
        memory.addFile("/deep/top.txt", "top")
        memory.addDirectory("/t")
        let copying = Review2Replies()
        let job = FileJob(
            kind: .copy, sources: [memory.url("/deep")], target: TargetSpec(directory: memory.url("/t")),
            fileSystems: fileSystems)
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
                && memory.contents(path + "/bottom.txt") == "bottom")
        #expect(!memory.exists("/deep/top.txt"))
    }

    @Test func aListOfSourcesFromManyFoldersIsLookedAtFolderByFolder() throws {
        let (fileSystems, memory) = makeFileSystems()
        // One source on the local disk, one in memory (which is not a fast local disk): no
        // pool, and the copy still works.
        try box.file("s/a.txt", "a")
        memory.addFile("/m/b.txt", "b")
        try box.folder("t")
        let result = runJob(
            .copy, [box.url("s/a.txt"), memory.url("/m/b.txt")], to: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems)
        #expect(result.completed.count == 2 && namesOnDisk(box.url("t")) == ["a.txt", "b.txt"])
    }

    @Test func manySmallFilesStillArriveThroughThePoolWithOrderedProgress() throws {
        let (fileSystems, _) = makeFileSystems()
        for index in 0..<300 { try box.file("s/f\(index).txt", "contents \(index)") }
        try box.folder("t")
        let answers = Answers()
        let job = FileJob(
            kind: .copy, sources: [box.url("s")], target: TargetSpec(directory: box.url("t")), fileSystems: fileSystems
        )
        job.delegate = answers
        let result = job.run()
        #expect(
            result.completed.count == 1 && namesOnDisk(box.url("t/s")).count == 300
                && box.read("t/s/f299.txt") == "contents 299")
        // The reports come one at a time and never go backwards.
        let done = answers.progress.map(\.itemsDone)
        #expect(
            done == done.sorted() && answers.progress.last?.itemsDone == 301 && answers.progress.last?.itemsTotal == 301
        )
    }
}

/// Deleting and moving across a mount point, with a real disk image. Where the system does
/// not let a test make or attach one (a sandbox), the suite has nothing to say.
@Suite(.serialized) struct Review2FileopsMounts {
    let box: Sandbox
    let mount: URL
    let attached: Bool

    init() throws {
        box = try Sandbox()
        mount = box.url("tree/mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try "outside".write(to: box.url("tree/beside.txt"), atomically: true, encoding: .utf8)
        let image = box.url("disk.dmg")
        func hdiutil(_ arguments: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        attached =
            hdiutil(["create", "-size", "4m", "-fs", "HFS+", "-volname", "afmtest", image.path])
            && hdiutil(["attach", image.path, "-mountpoint", mount.path, "-nobrowse", "-noautoopen"])
        if attached {
            try "on the volume".write(
                to: mount.appendingPathComponent("precious.txt"), atomically: true, encoding: .utf8)
        }
    }

    private func detach() {
        guard attached else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mount.path, "-force"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // F012, F020
    @Test func deletingAFolderDoesNotGoIntoAVolumeMountedInsideIt() {
        defer { detach() }
        guard attached else { return }
        let fileSystems = makeFileSystems().0
        #expect(FileIdentity.isMountPoint(mount) && !FileIdentity.isMountPoint(box.url("tree")))
        // Nobody answers the question (the default says no): the volume is left alone and that is noted.
        let quiet = Answers()
        var job = FileJob(kind: .delete(toTrash: false), sources: [box.url("tree")], fileSystems: fileSystems)
        job.delegate = quiet
        var result = job.run()
        #expect(FileManager.default.fileExists(atPath: mount.appendingPathComponent("precious.txt").path))
        #expect(
            result.completed.isEmpty && result.failureCount == 1
                && result.failures.first?.contains("another volume") == true)
        #expect(!box.exists("tree/beside.txt"))
        // Asked, and answered with Skip.
        let replies = Review2Replies(volume: .skip)
        job = FileJob(kind: .delete(toTrash: false), sources: [box.url("tree")], fileSystems: fileSystems)
        job.delegate = replies
        result = job.run()
        #expect(
            replies.volumes == ["mnt"]
                && FileManager.default.fileExists(atPath: mount.appendingPathComponent("precious.txt").path))
    }

    @Test func movingAFolderDoesNotEmptyAVolumeMountedInsideIt() throws {
        defer { detach() }
        guard attached else { return }
        let fileSystems = makeFileSystems().0
        // The target folder exists, so the move goes item by item.
        try box.folder("t/tree")
        let replies = Review2Replies(volume: .skip)
        let job = FileJob(
            kind: .move, sources: [box.url("tree")], target: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems)
        job.delegate = replies
        let result = job.run()
        #expect(replies.volumes == ["mnt"] && result.completed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: mount.appendingPathComponent("precious.txt").path))
        #expect(box.read("t/tree/beside.txt") == "outside" && !box.exists("t/tree/mnt/precious.txt"))
    }

    @Test func withAnExplicitYesTheVolumeIsEntered() {
        defer { detach() }
        guard attached else { return }
        let fileSystems = makeFileSystems().0
        let replies = Review2Replies(volume: .proceed)
        let job = FileJob(kind: .delete(toTrash: false), sources: [box.url("tree")], fileSystems: fileSystems)
        job.delegate = replies
        _ = job.run()
        #expect(
            replies.volumes == ["mnt"]
                && !FileManager.default.fileExists(atPath: mount.appendingPathComponent("precious.txt").path))
    }
}
