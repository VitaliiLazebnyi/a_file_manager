import AFMContracts
import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import ClipboardPlugin
@testable import FileOperationsPlugin
@testable import FilePropertiesPlugin
@testable import MacIntegrationPlugin

// Regression tests of the reviewed defects in the file-operation plugins (F1 … F20).

/// A file system over memory that can be told to misbehave the way servers and shares do:
/// list names that lead out of their folder, refuse the Trash in different ways, fail a removal.
///
/// Unchecked: what it records is guarded by `lock`; its switches are set by the test before use.
final class OddFileSystem: FileSystemProvider, @unchecked Sendable {
    let base = MemoryFileSystem(scheme: "odd")
    var scheme: String { base.scheme }
    var capabilities: FileSystemCapabilities { [.write, .trash] }
    private let lock = NSLock()
    private var hostile: [String: [String]] = [:]
    private var failures = 0
    private var removedURLs: [URL] = []
    private var trashed: [URL] = []
    /// What `trash` throws; nil trashes for real.
    var trashError: (any Error)?

    func addHostile(names: [String], in directory: String) { lock.withLock { hostile[directory] = names } }
    func failNextRemovals(_ count: Int) { lock.withLock { failures = count } }
    var removed: [URL] { lock.withLock { removedURLs } }
    var trashedItems: [URL] { lock.withLock { trashed } }

    func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        var items = try base.list(directory, showHidden: showHidden)
        for (index, name) in (lock.withLock { hostile[directory.path] } ?? []).enumerated() {
            items.append(
                FileItem(url: directory.appendingPathComponent("hostile\(index)"), name: name, stat: .init(size: 4))
            )
        }
        return items
    }
    func item(at url: URL) -> FileItem? {
        if url.lastPathComponent.hasPrefix("hostile") {
            return FileItem(url: url, name: url.lastPathComponent, stat: .init(size: 4))
        }
        return base.item(at: url)
    }
    func parent(of directory: URL) -> URL? { base.parent(of: directory) }
    func read(_ url: URL) throws -> any FileReader {
        if url.lastPathComponent.hasPrefix("hostile") {
            return try base.read(base.addFile("/hostile-data", "evil"))
        }
        return try base.read(url)
    }
    func createDirectory(at url: URL) throws { base.createDirectory(at: url) }
    func write(_ url: URL) throws -> any FileWriter { try base.write(url) }
    func remove(_ url: URL) throws {
        let fails: Bool = lock.withLock {
            removedURLs.append(url)
            if failures > 0 {
                failures -= 1
                return true
            }
            return false
        }
        if fails { throw CocoaError(.fileWriteUnknown) }
        try base.remove(url)
    }
    func trash(_ url: URL) throws {
        lock.withLock { trashed.append(url) }
        if let trashError { throw trashError }
        try base.remove(url)
    }
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

/// Answers `retry` the first time a step fails and `skip` afterwards.
final class RetryOnce: FileJobDelegate {
    private let lock = NSLock()
    private(set) var errors: [String] = []
    func job(_: FileJob, progress _: JobProgress) {}
    func job(_: FileJob, conflictAt _: FileItem, source _: FileItem) -> ConflictChoice { .overwrite }
    func job(_: FileJob, failedAt _: URL, error: any Error) -> ErrorChoice {
        lock.withLock {
            errors.append(error.localizedDescription)
            return errors.count == 1 ? .retry : .skip
        }
    }
    func job(_: FileJob, confirmDeleteNonEmpty _: URL) -> FolderDeleteChoice { .delete }
}

private func isCaseInsensitive(_ box: Sandbox) throws -> Bool {
    try box.file("probe-Case", "p")
    return box.exists("probe-case")
}

@Suite struct FileOpsFixJobs {
    // MARK: F1

    @Test func aCopyOfALockedFileLeavesNoTemporaryFileBehind() throws {
        let box = try Sandbox()
        let source = try box.file("A/locked.txt", "l")
        try box.folder("B")
        #expect(chflags(source.path, UInt32(UF_IMMUTABLE)) == 0)
        defer {
            chflags(source.path, 0)
            for name in namesOnDisk(box.url("B")) { chflags(box.url("B/" + name).path, 0) }
        }
        let replies = Replies()
        runJob(.copy, [source], to: TargetSpec(directory: box.url("B")), replies: replies)
        // Whether the copy itself arrived depends on the file system; the temporary name must not stay.
        #expect(!namesOnDisk(box.url("B")).contains { $0.hasPrefix(".afm-") })
    }

    @Test func aFinderLockedFileIsCopiedWithItsLockByTheJobItself() throws {
        let box = try Sandbox()
        let source = try box.file("A/locked.txt", "locked content")
        try box.folder("B")
        #expect(chflags(source.path, UInt32(UF_IMMUTABLE)) == 0)
        let target = box.url("B/locked.txt")
        defer {
            chflags(source.path, 0)
            for name in namesOnDisk(box.url("B")) { chflags(box.url("B/" + name).path, 0) }
        }
        func flags(_ url: URL) -> UInt32 {
            var st = stat()
            return lstat(url.path, &st) == 0 ? st.st_flags : 0
        }
        // The job as the copy command makes it, with the options the dialog starts with.
        let replies = Replies()
        let result = runJob(.copy, [source], to: TargetSpec(directory: box.url("B")), replies: replies)
        #expect(replies.errors.isEmpty && replies.conflicts.isEmpty)
        #expect(result.completed.count == 1 && box.read("B/locked.txt") == "locked content")
        // Locked like the source, which is untouched; and no temporary file is left.
        #expect(flags(target) & UInt32(UF_IMMUTABLE) != 0 && flags(source) & UInt32(UF_IMMUTABLE) != 0)
        #expect(namesOnDisk(box.url("B")) == ["locked.txt"] && namesOnDisk(box.url("A")) == ["locked.txt"])
        // The same file again, over the locked copy: whatever comes of it, nothing temporary stays behind.
        let again = Replies(.overwrite)
        runJob(.copy, [source], to: TargetSpec(directory: box.url("B")), replies: again)
        #expect(
            !namesOnDisk(box.url("B")).contains { $0.hasPrefix(".afm-") }
                && box.read("B/locked.txt") == "locked content"
        )
    }

    // MARK: F4

    @Test func aTargetInsideTheSourceThroughALinkIsRefused() throws {
        let box = try Sandbox()
        try box.file("A/Foo/one.txt", "1")
        try FileManager.default.createSymbolicLink(at: box.url("A/link"), withDestinationURL: box.url("A/Foo"))
        let replies = Replies()
        let result = runJob(
            .copy,
            [box.url("A/Foo")],
            to: TargetSpec(directory: box.url("A/link/sub")),
            replies: replies
        )
        #expect(replies.errors.count == 1 && replies.errors[0].contains("own subfolders"))
        #expect(result.completed.isEmpty && namesOnDisk(box.url("A/Foo")) == ["one.txt"])
    }

    @Test func aCaseOnlyRenameIsNotAConflict() throws {
        let box = try Sandbox()
        try box.file("A/readme.txt", "r")
        try box.file("A/Folder/in.txt", "i")
        let replies = Replies()
        let file = runJob(
            .move,
            [box.url("A/readme.txt")],
            to: TargetSpec(directory: box.url("A"), exactName: "README.txt"),
            replies: replies
        )
        let folder = runJob(
            .move,
            [box.url("A/Folder")],
            to: TargetSpec(directory: box.url("A"), exactName: "FOLDER"),
            replies: replies
        )
        #expect(replies.conflicts.isEmpty && replies.merges.isEmpty && replies.errors.isEmpty)
        #expect(file.completed.count == 1 && folder.completed.count == 1)
        #expect(namesOnDisk(box.url("A")) == ["FOLDER", "README.txt"])
        #expect(box.read("A/README.txt") == "r" && box.read("A/FOLDER/in.txt") == "i")
    }

    @Test func aCopyOntoItsOwnNameInOtherLetterCaseIsACopyOntoItself() throws {
        let box = try Sandbox()
        guard try isCaseInsensitive(box) else {
            return
        }
        try box.file("A/readme.txt", "r")
        let replies = Replies()
        runJob(
            .copy,
            [box.url("A/readme.txt")],
            to: TargetSpec(directory: box.url("A"), exactName: "README.TXT"),
            replies: replies
        )
        #expect(replies.conflicts.isEmpty && replies.errors == ["You cannot copy a file to itself!"])
        #expect(box.read("A/readme.txt") == "r")
    }

    @Test func twoSourcesWhoseTargetNamesDifferInCaseOnlyAreOneConflict() throws {
        let box = try Sandbox()
        guard try isCaseInsensitive(box) else {
            return
        }
        try box.file("A/x.txt", "a")
        try box.file("B/X.txt", "b")
        try box.folder("C")
        let replies = Replies(.skip)
        runJob(
            .copy,
            [box.url("A/x.txt"), box.url("B/X.txt")],
            to: TargetSpec(directory: box.url("C")),
            replies: replies
        )
        #expect(replies.conflicts.count == 1 && replies.errors.isEmpty)
        #expect(namesOnDisk(box.url("C")).count == 1)
    }

    // MARK: F5

    @Test func namesThatLeadOutOfTheirFolderAreNotTransferred() throws {
        let box = try Sandbox()
        try box.folder("Target")
        let fileSystems = FileSystemRegistry()
        let odd = OddFileSystem()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(odd)
        odd.base.addFile("/d/ok.txt", "fine")
        odd.addHostile(names: ["../escape.txt", "a/b.txt", "..", ".", "", "nul\0.txt"], in: "/d")
        let replies = Replies()
        let result = runJob(
            .copy,
            [odd.base.url("/d")],
            to: TargetSpec(directory: box.url("Target")),
            replies: replies,
            fileSystems: fileSystems
        )
        #expect(namesOnDisk(box.url("Target/d")) == ["ok.txt"])
        #expect(namesOnDisk(box.url("Target")) == ["d"] && namesOnDisk(box.root) == ["Target"])
        #expect(replies.errors.count == 6 && replies.errors.allSatisfy { $0.contains("not a valid file name") })
        #expect(result.failureCount == 6)
        // Nothing of it counts as processed, so a move would keep the folder.
        #expect(result.completed.isEmpty)
    }

    @Test func aMoveKeepsAFolderWithARefusedName() throws {
        let box = try Sandbox()
        try box.folder("Target")
        let fileSystems = FileSystemRegistry()
        let odd = OddFileSystem()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(odd)
        odd.base.addFile("/d/ok.txt", "fine")
        odd.addHostile(names: [".."], in: "/d")
        let replies = Replies()
        let result = runJob(
            .move,
            [odd.base.url("/d")],
            to: TargetSpec(directory: box.url("Target")),
            replies: replies,
            fileSystems: fileSystems
        )
        #expect(result.completed.isEmpty && !odd.removed.contains(odd.base.url("/d")))
    }

    @Test func deletingNeverFollowsAHostileName() {
        let fileSystems = FileSystemRegistry()
        let odd = OddFileSystem()
        fileSystems.register(odd)
        odd.base.addFile("/d/ok.txt", "fine")
        odd.addHostile(names: ["..", "x/y"], in: "/d")
        let replies = Replies()
        let result = runJob(.delete(toTrash: false), [odd.base.url("/d")], replies: replies, fileSystems: fileSystems)
        #expect(odd.removed.map(\.lastPathComponent) == ["ok.txt"])
        #expect(replies.errors.count == 2 && result.completed.isEmpty)
    }

    // MARK: F6

    @Test func onlyAPlaceWithoutATrashOffersPermanentDeletion() {
        let fileSystems = FileSystemRegistry()
        let odd = OddFileSystem()
        fileSystems.register(odd)
        odd.base.addFile("/a/one.txt", "1")
        odd.base.addFile("/a/two.txt", "2")
        let source = [odd.base.url("/a/one.txt"), odd.base.url("/a/two.txt")]

        // A refusal that is about this item is an error to decide on; nothing is deleted for good.
        odd.trashError = CocoaError(.fileWriteNoPermission)
        let denied = Replies()
        let first = runJob(.delete(toTrash: true), source, replies: denied, fileSystems: fileSystems)
        #expect(denied.protections.isEmpty && denied.errors.count == 2 && first.completed.isEmpty)
        #expect(odd.base.exists("/a/one.txt") && odd.base.exists("/a/two.txt"))

        // No Trash here: the question is whether to delete for good, and "All" holds for the rest.
        odd.trashError = CocoaError(.featureUnsupported)
        let noTrash = Replies()
        noTrash.protection = .all
        let second = runJob(.delete(toTrash: true), source, replies: noTrash, fileSystems: fileSystems)
        #expect(
            noTrash.protections == ["noTrash delete one.txt"] && second.completed.count == 2
                && !odd.base.exists("/a/one.txt")
        )
    }

    @Test func aFailedTrashCanBeRetried() {
        let fileSystems = FileSystemRegistry()
        let odd = OddFileSystem()
        fileSystems.register(odd)
        odd.base.addFile("/a/one.txt", "1")
        odd.trashError = CocoaError(.fileWriteNoPermission)
        let job = FileJob(
            kind: .delete(toTrash: true),
            sources: [odd.base.url("/a/one.txt")],
            fileSystems: fileSystems
        )
        let delegate = RetryOnce()
        job.delegate = delegate
        _ = job.run()
        // Retry asks the Trash again; it is not the old error replayed.
        #expect(odd.trashedItems.count == 2 && delegate.errors.count == 2)
    }

    // MARK: F7

    @Test func removingTheSourceOfAMoveIsRetriedWithoutCopyingAgain() throws {
        let box = try Sandbox()
        try box.folder("B")
        let fileSystems = FileSystemRegistry()
        let odd = OddFileSystem()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(odd)
        odd.base.addFile("/a/one.txt", "payload")
        odd.failNextRemovals(1)
        let job = FileJob(
            kind: .move,
            sources: [odd.base.url("/a/one.txt")],
            target: TargetSpec(directory: box.url("B")),
            fileSystems: fileSystems
        )
        let delegate = RetryOnce()
        job.delegate = delegate
        let result = job.run()
        #expect(delegate.errors.count == 1 && !delegate.errors[0].contains("already exists"))
        #expect(box.read("B/one.txt") == "payload" && !odd.base.exists("/a/one.txt") && result.completed.count == 1)
        #expect(namesOnDisk(box.url("B")) == ["one.txt"])
    }

    @Test func aSourceThatCannotBeRemovedStaysAndIsNotReportedAsMoved() throws {
        let box = try Sandbox()
        try box.folder("B")
        let fileSystems = FileSystemRegistry()
        let odd = OddFileSystem()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(odd)
        odd.base.addFile("/a/one.txt", "payload")
        odd.failNextRemovals(5)
        let replies = Replies()
        let result = runJob(
            .move,
            [odd.base.url("/a/one.txt")],
            to: TargetSpec(directory: box.url("B")),
            replies: replies,
            fileSystems: fileSystems
        )
        #expect(box.read("B/one.txt") == "payload" && odd.base.exists("/a/one.txt") && result.completed.isEmpty)
    }

    // MARK: F8

    @Test func aFolderThatMovesByOneRenameIsNotWalked() throws {
        let box = try Sandbox()
        for index in 0..<30 { try box.file("A/docs/sub/f\(index).txt", "x") }
        try box.folder("B")
        let replies = Replies()
        let result = runJob(.move, [box.url("A/docs")], to: TargetSpec(directory: box.url("B")), replies: replies)
        let last = try #require(replies.progress.last)
        #expect(result.completed.count == 1 && box.exists("B/docs/sub/f29.txt") && !box.exists("A/docs"))
        // One item for the rename: the 31 items below were never counted.
        #expect(last.itemsTotal == 1 && last.itemsDone == 1)
    }

    @Test func aFolderMergedIntoAnExistingOneIsCountedInFull() throws {
        let box = try Sandbox()
        for index in 0..<5 { try box.file("A/docs/f\(index).txt", "x") }
        try box.file("B/docs/keep.txt", "k")
        let replies = Replies()
        let result = runJob(.move, [box.url("A/docs")], to: TargetSpec(directory: box.url("B")), replies: replies)
        let last = try #require(replies.progress.last)
        #expect(result.completed.count == 1 && last.itemsTotal == 6 && last.itemsDone == 6)
        #expect(namesOnDisk(box.url("B/docs")).count == 6)
    }

    @Test func aSkippedFolderAdvancesTheCounterToTheEnd() throws {
        let box = try Sandbox()
        for index in 0..<4 { try box.file("A/docs/f\(index).txt", "x") }
        try box.file("A/one.txt", "1")
        try box.folder("B")
        let replies = Replies()
        replies.merge = .skip
        try box.folder("B/docs")
        let result = runJob(
            .copy,
            [box.url("A/docs"), box.url("A/one.txt")],
            to: TargetSpec(directory: box.url("B")),
            replies: replies
        ) {
            $0.options.asksBeforeMerging = true
        }
        let last = try #require(replies.progress.last)
        #expect(result.completed.count == 1 && last.itemsDone == last.itemsTotal && last.itemsTotal == 6)
    }

    // MARK: F10

    @Test func manyFilesAreDeletedBySeveralWorkersAndProtectedOnesAreAskedInOrder() throws {
        let box = try Sandbox()
        for index in 0..<200 { try box.file(String(format: "A/tree/f%03d.txt", index), "x") }
        for name in ["ro1", "ro2", "ro3"] {
            let url = try box.file("A/tree/\(name).txt", "r")
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        }
        try box.file("A/tree/sub/deep.txt", "d")
        let replies = Replies()
        replies.protection = .skip
        let result = runJob(.delete(toTrash: false), [box.url("A/tree")], replies: replies) { $0.parallelWidth = 4 }
        // The folder stays because three of its files were kept; everything else is gone.
        #expect(
            replies.protections == ["readOnly delete ro1.txt", "readOnly delete ro2.txt", "readOnly delete ro3.txt"]
        )
        #expect(namesOnDisk(box.url("A/tree")) == ["ro1.txt", "ro2.txt", "ro3.txt"] && result.completed.isEmpty)
        let last = try #require(replies.progress.last)
        #expect(last.itemsDone == last.itemsTotal)
    }

    @Test func aCancelDuringAParallelDeleteStopsAndReturns() throws {
        let box = try Sandbox()
        for index in 0..<300 { try box.file(String(format: "A/tree/f%03d.txt", index), "x") }
        let replies = Replies()
        replies.cancelAtItems = 40
        let result = runJob(.delete(toTrash: false), [box.url("A/tree")], replies: replies) { $0.parallelWidth = 4 }
        #expect(result.cancelled && box.exists("A/tree") && !namesOnDisk(box.url("A/tree")).isEmpty)
        #expect(namesOnDisk(box.url("A/tree")).count < 300)
    }

    @Test func aDeleteTreeWithoutAPoolStillDeletesEverything() throws {
        let box = try Sandbox()
        for index in 0..<50 { try box.file("A/tree/d\(index % 5)/f\(index).txt", "x") }
        let replies = Replies()
        let result = runJob(.delete(toTrash: false), [box.url("A/tree")], replies: replies) {
            $0.options.copiesSmallFilesInParallel = false
        }
        #expect(result.completed.count == 1 && !box.exists("A/tree"))
    }

    // MARK: F13

    @Test func filesOfDifferentSizesAreDifferentWithoutReadingThem() throws {
        let box = try Sandbox()
        try box.file("a.txt", "short")
        try box.file("b.txt", "longer text")
        try box.file("c.txt", "short")
        let (fileSystems, _) = makeFileSystems()
        // A reading that was cancelled at once would answer nil; the sizes answer before any reading.
        #expect(
            try Checksum.sameContents(box.url("a.txt"), box.url("b.txt"), in: fileSystems, isCancelled: { true })
                == false
        )
        #expect(try Checksum.sameContents(box.url("a.txt"), box.url("c.txt"), in: fileSystems) == true)
    }

    @Test func verifyingShowsProgressAndStillCatchesDamage() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", String(repeating: "x", count: 3 << 20))
        try box.folder("B")
        let replies = Replies()
        runJob(.copy, [box.url("A/one.txt")], to: TargetSpec(directory: box.url("B")), replies: replies) {
            $0.options.verifies = true
        }
        #expect(replies.progress.contains { $0.lines.first?.hasPrefix("Verifying: ") == true })
        #expect(box.exists("B/one.txt") && replies.errors.isEmpty)
    }

    // MARK: F14

    @Test func olderMeansOlderByMoreThanTheGranularityOfTheTarget() {
        let (fileSystems, memory) = makeFileSystems()
        let base = Date(timeIntervalSince1970: 1_000_000)
        memory.addFile("/a/near.txt", "new", modified: base.addingTimeInterval(1.5))
        memory.addFile("/a/far.txt", "new", modified: base.addingTimeInterval(5))
        memory.addFile("/b/near.txt", "old", modified: base)
        memory.addFile("/b/far.txt", "old", modified: base)
        let replies = Replies(.overwriteAllOlder)
        runJob(
            .copy,
            [memory.url("/a/near.txt"), memory.url("/a/far.txt")],
            to: TargetSpec(directory: memory.url("/b")),
            replies: replies,
            fileSystems: fileSystems
        )
        // 1.5 s is a rounding of a two-second clock, not a newer file.
        #expect(memory.contents("/b/near.txt") == "old" && memory.contents("/b/far.txt") == "new")
    }

    @Test func olderOrSameKeepsAnOlderTargetOnlyBeyondTheTolerance() {
        let (fileSystems, memory) = makeFileSystems()
        let base = Date(timeIntervalSince1970: 1_000_000)
        memory.addFile("/a/near.txt", "new", modified: base)
        memory.addFile("/a/far.txt", "new", modified: base)
        memory.addFile("/b/near.txt", "old", modified: base.addingTimeInterval(1.5))
        memory.addFile("/b/far.txt", "old", modified: base.addingTimeInterval(9))
        let replies = Replies(.overwriteAllOlderOrSame)
        runJob(
            .copy,
            [memory.url("/a/near.txt"), memory.url("/a/far.txt")],
            to: TargetSpec(directory: memory.url("/b")),
            replies: replies,
            fileSystems: fileSystems
        )
        #expect(memory.contents("/b/near.txt") == "new" && memory.contents("/b/far.txt") == "old")
    }

    // MARK: F20

    @Test func hugeWidthsInNamesAreClamped() throws {
        var context = NameTemplate.Context()
        context.cursorName = "abc.txt"
        let counter = try NameTemplate.names(from: "<1-2>x[C:999999999]", context: context)
        #expect(counter.count == 2 && counter.allSatisfy { $0.count <= 256 })
        let range = try NameTemplate.names(from: "<[N01,999999999]", context: context)
        #expect(range.count == 1 && range[0].count <= 255)
        // A start and a length that would overflow are no longer a crash.
        let big = try NameTemplate.names(from: "<[N2,9223372036854775807]", context: context)
        #expect(big.count == 1)
    }
}

/// The operation log: bursts, the handle, the end of a job and the pruning of old copies.
@Suite struct FileOpsFixLog {
    @Test func linesAreWrittenWithoutAFlushAfterAShortWhile() throws {
        let box = try Sandbox()
        var configuration = OperationLog.Configuration()
        configuration.isEnabled = true
        configuration.file = box.url("logs/operations.log")
        let log = OperationLog(configuration)
        for index in 0..<50 { log.write(OperationRecord(.copy, source: "/a/\(index)", target: "/b/\(index)")) }
        var text = ""
        for _ in 0..<300 where text.split(separator: "\n").count < 50 {
            Thread.sleep(forTimeInterval: 0.01)
            text = box.read("logs/operations.log") ?? ""
        }
        #expect(text.split(separator: "\n").count == 50)
        // The end of a job asks for what is collected, and the lines keep their order across bursts.
        log.write(OperationRecord(.copy, source: "/z", target: "/z"))
        log.flushSoon()
        log.flush()
        let lines = (box.read("logs/operations.log") ?? "").split(separator: "\n")
        #expect(lines.count == 51 && lines.last?.hasSuffix("Copy: /z -> /z") == true)
    }

    @Test func aFileThatWasDeletedWhileTheLogWasOpenIsWrittenAgain() throws {
        let box = try Sandbox()
        var configuration = OperationLog.Configuration()
        configuration.isEnabled = true
        configuration.file = box.url("logs/operations.log")
        let log = OperationLog(configuration)
        // The end of a job writes what is collected and keeps the file open.
        log.write(OperationRecord(.copy, source: "one"))
        log.flushSoon()
        for _ in 0..<200 where !(box.read("logs/operations.log") ?? "").contains("one") {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try FileManager.default.removeItem(at: box.url("logs/operations.log"))
        log.write(OperationRecord(.copy, source: "three"))
        log.flushSoon()
        for _ in 0..<200 where !(box.read("logs/operations.log") ?? "").contains("three") {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(box.read("logs/operations.log")?.contains("three") == true)
        log.flush()
    }

    @Test func pruningLeavesOtherPeoplesFilesAlone() throws {
        let box = try Sandbox()
        var configuration = OperationLog.Configuration()
        configuration.isEnabled = true
        configuration.file = box.url("logs/operations.log")
        configuration.rotation = .size(120)
        configuration.keepCount = 1
        try box.file("logs/operations.backup.log", "mine")
        try box.file("logs/operations.notes.log", "mine")
        let log = OperationLog(configuration)
        for index in 0..<10 {
            log.write(OperationRecord(.copy, source: "/a/" + String(repeating: "x", count: 60) + "\(index)"))
            log.flush()
            Thread.sleep(forTimeInterval: 0.02)
        }
        let names = namesOnDisk(box.url("logs"))
        #expect(names.contains("operations.backup.log") && names.contains("operations.notes.log"))
        #expect(
            names.filter { $0.range(of: #"^operations\.\d+\.log$"#, options: .regularExpression) != nil }.count == 1
        )
    }

    @Test func theNamesOfRotatedCopiesAreRecognisedExactly() {
        #expect(OperationLog.isRotatedCopy("operations.2026-10-12.log", of: "operations.log"))
        #expect(OperationLog.isRotatedCopy("operations.2026-10-12-3.log", of: "operations.log"))
        #expect(OperationLog.isRotatedCopy("operations.7.log", of: "operations.log"))
        #expect(!OperationLog.isRotatedCopy("operations.log", of: "operations.log"))
        #expect(!OperationLog.isRotatedCopy("operations.backup.log", of: "operations.log"))
        #expect(!OperationLog.isRotatedCopy("operations.7.txt", of: "operations.log"))
        #expect(OperationLog.isRotatedCopy("ops.4", of: "ops"))
    }
}

/// The commands of the plugins, through a kernel with fake panels.
@MainActor @Suite struct FileOpsFixCommands {
    // MARK: F3

    @Test func aCaseOnlyRenameWorksAndNeverReplacesAnotherFile() throws {
        let box = try Sandbox()
        try box.file("A/readme", "mine")
        try box.folder("B")
        let bench = TestBench(
            plugins: [FileOperationsPlugin()],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B")
        )
        bench.left.moveCursor(toName: "readme")
        bench.commands.perform(.renameOnly, .text("README"))
        #expect(namesOnDisk(box.url("A")) == ["README"] && box.read("A/README") == "mine")
        #expect(!bench.interaction.log.contains { $0.hasPrefix("inform") })
    }

    @Test func renamingOntoAnotherFileWhoseNameDiffersInCaseIsRefused() {
        // A file system that tells the two names apart, as a case-sensitive volume does.
        let memory = MemoryFileSystem()
        memory.addFile("/A/readme", "first")
        memory.addFile("/A/README", "second")
        let bench = TestBench(
            plugins: [FileOperationsPlugin()],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/A")
        )
        bench.left.moveCursor(toName: "readme")
        bench.commands.perform(.renameOnly, .text("README"))
        #expect(memory.contents("/A/readme") == "first" && memory.contents("/A/README") == "second")
        #expect(bench.interaction.log.contains("inform: readme cannot be renamed!"))
    }

    // MARK: F17

    @Test func pasteIsOfferedWhileFilesAreOnTheClipboard() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.folder("B")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let bench = TestBench(
            plugins: [FileOperationsPlugin(), ClipboardPlugin(pasteboard: pasteboard)],
            fileSystems: [LocalFileSystem()],
            left: box.url("B"),
            right: box.url("A")
        )
        pasteboard.clearContents()
        #expect(!bench.commands.isEnabled(.pasteFromClipboard))
        pasteboard.writeObjects([box.url("A/one.txt") as NSURL])
        #expect(bench.commands.isEnabled(.pasteFromClipboard))
    }

    @Test func theToolbarAsksWithoutBuildingTheListOfOperands() throws {
        let box = try Sandbox()
        for index in 0..<2_000 { try box.file("A/f\(index).txt", "x") }
        try box.folder("B")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let mac = MacIntegrationPlugin(
            launchesApplications: false,
            pasteboard: pasteboard,
            applications: { _ in [] }
        )
        let bench = TestBench(
            plugins: [SelectionPlugin(), mac],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B")
        )
        bench.left.model.selectAll()
        #expect(
            bench.commands.isEnabled(MacIntegrationPlugin.quickLook)
                && bench.commands.isEnabled(MacIntegrationPlugin.share)
                && bench.commands.isEnabled(MacIntegrationPlugin.editTags)
        )
        bench.left.model.clearSelection()
        bench.left.model.moveCursor(to: 0)
        #expect(!bench.commands.isEnabled(MacIntegrationPlugin.quickLook))
    }

    // MARK: F18

    @Test func savingDetailsKeepsTheOldFileUntilTheNewOneIsThereAndNeverRemovesAFolder() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.folder("A/details.txt")
        try box.file("A/details.txt/inside", "precious")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let bench = TestBench(
            plugins: [ClipboardPlugin(pasteboard: pasteboard)],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("A")
        )
        bench.left.moveCursor(toName: "one.txt")
        bench.commands.perform(ClipboardCommands.saveDetails, .text("details.txt"))
        #expect(box.read("A/details.txt/inside") == "precious")
        #expect(bench.interaction.log.contains("inform: The details cannot be saved!"))

        // A file is replaced in one step, without a leftover.
        try box.file("A/notes.txt", "old")
        bench.interaction.choiceAnswers = [0]
        bench.commands.perform(ClipboardCommands.saveDetails, .text("notes.txt"))
        #expect(box.read("A/notes.txt")?.hasPrefix("one.txt\t") == true)
        #expect(!namesOnDisk(box.url("A")).contains { $0.hasSuffix(".tmp") })
    }

    // MARK: F19

    @Test func theTestRecordsOfTheMacPluginStayBounded() throws {
        let box = try Sandbox()
        try box.file("A/notes.txt", "n")
        try box.folder("B")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let mac = MacIntegrationPlugin(
            launchesApplications: false,
            pasteboard: pasteboard,
            applications: { _ in [] }
        )
        let bench = TestBench(
            plugins: [SelectionPlugin(), mac],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B")
        )
        bench.left.moveCursor(toName: "notes.txt")
        for _ in 0..<1_000 { bench.commands.perform(MacIntegrationPlugin.openWithDefault) }
        #expect(mac.opened.count <= 256 && mac.log.count <= 512 && mac.log.last?.hasPrefix("open ") == true)
    }

    // MARK: F2

    @Test func changingOnlyTheDateOfAFolderLeavesThePermissionsBelowAlone() throws {
        let box = try Sandbox()
        let inner = try box.file("A/docs/in.txt", "inside")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inner.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: box.url("A/docs").path)
        try box.folder("B")
        let bench = TestBench(
            plugins: [FilePropertiesPlugin(launchesApplications: false)],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B")
        )
        bench.left.moveCursor(toName: "docs")
        // The permissions field keeps what the dialog proposed.
        bench.interaction.formAnswers = [
            .values([
                "recurse": .flag(true), "changeDate": .flag(true), "date": .text("2001-02-03"),
                "time": .text("04:05:06")
            ])
        ]
        bench.commands.perform(.setAttributes)
        #expect(bench.interaction.forms[0].first { $0.key == "permissions" }?.initialValue == .text("755"))
        #expect(LocalInfo.details(inner)?.mode == 0o600)
        let year = Calendar.current.component(
            .year,
            from: (try? FileManager.default.attributesOfItem(atPath: inner.path)[.modificationDate] as? Date) ?? Date()
        )
        #expect(year == 2_001)
    }

    @Test func pressingOKOnALockedFileDoesNotUnlockIt() throws {
        let box = try Sandbox()
        let file = try box.file("A/one.txt", "1")
        try box.folder("B")
        #expect(chflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(file.path, 0) }
        let bench = TestBench(
            plugins: [FilePropertiesPlugin(launchesApplications: false)],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B")
        )
        bench.left.moveCursor(toName: "one.txt")
        bench.interaction.formAnswers = [.accept]
        bench.commands.perform(.setAttributes)
        #expect(LocalInfo.details(file)?.flags ?? 0 & UInt32(UF_IMMUTABLE) != 0)
    }

    @Test func permissionsTypedOrLoadedAreStillApplied() throws {
        let box = try Sandbox()
        let file = try box.file("A/one.txt", "1")
        try box.file("B/other.txt", "2")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: box.url("B/other.txt").path)
        let bench = TestBench(
            plugins: [FilePropertiesPlugin(launchesApplications: false)],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B")
        )
        bench.left.moveCursor(toName: "one.txt")
        bench.right.moveCursor(toName: "other.txt")
        // "Load from Target File" applies what it loaded, even though it is another file's mode.
        bench.interaction.formAnswers = [.values([:], button: 1), .accept]
        bench.commands.perform(.setAttributes)
        #expect(LocalInfo.details(file)?.mode == 0o640)
    }

    // MARK: F16

    @Test func aCommentFileThatCannotBeReadIsNeverOverwritten() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "1")
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        let store = CommentStore(fileSystems: fileSystems)

        // Absent: the comment is simply created.
        try store.setComment("hello", for: "one.txt", in: box.url("A"), hidden: false)
        #expect(box.exists("A/descript.ion"))

        // Not decodable (a UTF-8 mark followed by bytes that are no UTF-8).
        let broken = Data([0xEF, 0xBB, 0xBF, 0xFF, 0xFE, 0xC0])
        try broken.write(to: box.url("A/descript.ion"))
        #expect(throws: (any Error).self) {
            try store.setComment("x", for: "one.txt", in: box.url("A"), hidden: false)
        }
        #expect(try Data(contentsOf: box.url("A/descript.ion")) == broken)

        // Unreadable.
        try box.file("B/descript.ion", "two.txt keep me\r\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: box.url("B/descript.ion").path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: box.url("B/descript.ion").path
            )
        }
        #expect(throws: (any Error).self) {
            try store.setComment("x", for: "other.txt", in: box.url("B"), hidden: false)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: box.url("B/descript.ion").path)
        #expect(box.read("B/descript.ion") == "two.txt keep me\r\n")
    }

    @Test func anOversizedCommentFileIsNotOverwritten() throws {
        let memory = MemoryFileSystem()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(memory)
        memory.addFile("/A/descript.ion", String(repeating: "x", count: 17 * 1_024 * 1_024))
        let store = CommentStore(fileSystems: fileSystems)
        #expect(throws: (any Error).self) {
            try store.setComment("x", for: "one.txt", in: memory.url("/A"), hidden: false)
        }
        #expect(memory.contents("/A/descript.ion")?.count == 17 * 1_024 * 1_024)
    }

    // MARK: F12

    @Test func theAllocatedSizeIsOnlyAskedForWhenItIsWanted() throws {
        let box = try Sandbox()
        let file = try box.file("A/small.txt", "x")
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        let item = try #require(fileSystems.item(at: file))
        let lean = SpaceCalculator(fileSystems: fileSystems, measuresAllocated: false).measure([item])[0]
        let full = SpaceCalculator(fileSystems: fileSystems).measure([item])[0]
        #expect(lean.bytes == 1 && lean.allocated == 1)
        #expect(full.allocated >= 1 && full.allocated % 512 == 0)
    }
}
