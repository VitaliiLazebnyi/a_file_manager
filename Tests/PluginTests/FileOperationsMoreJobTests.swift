import AFMContracts
import AFMKernel
import FileOperationsPlugin
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

/// Answers a job's questions from scripts and records what was asked.
///
/// Safe to call from the job's worker threads.
internal final class Replies: FileJobDelegate {
    private let lock = NSLock()
    private var conflictScript: [ConflictChoice]
    private var asked: [String] = []
    private var reports: [JobProgress] = []
    private var failureTexts: [String] = []
    private var protectionAsked: [String] = []
    private var mergeAsked: [String] = []
    internal var failure = ErrorChoice.skip
    internal var protection = ProtectionChoice.proceed
    internal var merge = MergeChoice.merge
    internal var cancelAtItems: Int?
    internal var cancelAtBytes: Int64?

    internal var conflicts: [String] { lock.withLock { asked } }
    internal var progress: [JobProgress] { lock.withLock { reports } }
    internal var errors: [String] { lock.withLock { failureTexts } }
    internal var protections: [String] { lock.withLock { protectionAsked } }
    internal var merges: [String] { lock.withLock { mergeAsked } }

    /// The conflict answers in order; the last one is repeated.
    internal init(_ conflicts: ConflictChoice...) {
        conflictScript = conflicts.isEmpty ? [.overwrite] : conflicts
    }

    internal func job(_ job: FileJob, progress: JobProgress) {
        lock.withLock { reports.append(progress) }
        if let cancelAtItems, progress.itemsDone >= cancelAtItems { job.cancel() }
        if let cancelAtBytes, progress.bytesDone >= cancelAtBytes { job.cancel() }
    }

    internal func job(_: FileJob, conflictAt target: FileItem, source _: FileItem) -> ConflictChoice {
        lock.withLock {
            asked.append(target.name)
            return conflictScript.count > 1 ? conflictScript.removeFirst() : conflictScript[0]
        }
    }

    internal func job(_: FileJob, failedAt _: URL, error: any Error) -> ErrorChoice {
        lock.withLock { failureTexts.append(error.localizedDescription) }
        return failure
    }

    internal func job(_: FileJob, confirmDeleteNonEmpty _: URL) -> FolderDeleteChoice { .delete }

    internal func job(_: FileJob, confirm question: ProtectionQuestion) -> ProtectionChoice {
        lock.withLock { protectionAsked.append("\(question.reason) \(question.purpose) \(question.item.name)") }
        return protection
    }

    internal func job(_: FileJob, mergeInto existing: FileItem, source _: FileItem) -> MergeChoice {
        lock.withLock { mergeAsked.append(existing.name) }
        return merge
    }
}

/// A file system that passes everything on to a `MemoryFileSystem` and can misbehave on the
/// way: damage what is written, take its time, and count how many copies run at once.
///
/// Unchecked: what it records is guarded by `lock`; its switches are set by the test before use.
internal final class WrappedFileSystem: FileSystemProvider, @unchecked Sendable {
    /// Unchecked: used by one thread at a time, as the protocol allows.
    private final class Writer: FileWriter, @unchecked Sendable {
        let inner: any FileWriter
        let owner: WrappedFileSystem
        var first = true

        init(_ inner: any FileWriter, _ owner: WrappedFileSystem) {
            self.inner = inner
            self.owner = owner
        }

        func write(_ data: Data) throws {
            if owner.delay > 0 { Thread.sleep(forTimeInterval: owner.delay) }
            var data = data
            if owner.corruptsWrites, first, !data.isEmpty { data[data.startIndex] = data[data.startIndex] ^ 0xFF }
            first = false
            try inner.write(data)
        }

        func close(attributes: FileAttributes) throws {
            owner.ended()
            try inner.close(attributes: attributes)
        }
    }

    internal let base: MemoryFileSystem
    internal let scheme: String
    internal var capabilities: FileSystemCapabilities { base.capabilities }
    /// Every stream written here loses its first byte's value.
    internal var corruptsWrites = false
    /// How long a copy inside this file system and each written block take.
    internal var delay: TimeInterval = 0
    private let lock = NSLock()
    private var running = 0
    private var mostAtOnce = 0

    /// The largest number of files that were being written at the same time.
    internal var mostWritesAtOnce: Int { lock.withLock { mostAtOnce } }

    internal init(_ base: MemoryFileSystem) {
        self.base = base
        scheme = base.scheme
    }

    private func began() {
        lock.withLock {
            running += 1
            mostAtOnce = max(mostAtOnce, running)
        }
    }
    private func ended() { lock.withLock { running -= 1 } }

    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try base.list(directory, showHidden: showHidden)
    }
    internal func item(at url: URL) -> FileItem? { base.item(at: url) }
    internal func parent(of directory: URL) -> URL? { base.parent(of: directory) }
    internal func read(_ url: URL) throws -> any FileReader { try base.read(url) }
    internal func createDirectory(at url: URL) throws { base.createDirectory(at: url) }
    internal func write(_ url: URL) throws -> any FileWriter {
        let writer = Writer(try base.write(url), self)
        began()
        return writer
    }
    internal func remove(_ url: URL) throws { try base.remove(url) }
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try base.move(source, to: destination, replacing: replacing)
    }
    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        began()
        defer { ended() }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        try base.copy(source, to: destination, progress: progress)
    }
    internal func displayPath(_ url: URL) -> String { base.displayPath(url) }
    internal func location(from text: String) -> URL? { base.location(from: text) }
    internal func volume(of url: URL) -> VolumeInfo? { base.volume(of: url) }
}

/// The local disk plus a wrapped in-memory file system.
internal func makeWrappedFileSystems() -> (FileSystemRegistry, WrappedFileSystem) {
    let fileSystems = FileSystemRegistry()
    let wrapped = WrappedFileSystem(MemoryFileSystem())
    fileSystems.register(LocalFileSystem())
    fileSystems.register(wrapped)
    return (fileSystems, wrapped)
}

/// Runs a job whose questions `replies` answers; `configure` sets its options first.
@discardableResult
internal func runJob(
    _ kind: JobKind,
    _ sources: [URL],
    to target: TargetSpec? = nil,
    replies: Replies,
    fileSystems: FileSystemRegistry = makeFileSystems().0,
    configure: ((FileJob) -> Void)? = nil
) -> JobResult {
    let job = FileJob(kind: kind, sources: sources, target: target, fileSystems: fileSystems)
    let delegate: any FileJobDelegate = replies
    job.delegate = delegate
    configure?(job)
    // The job holds its delegate weakly.
    return withExtendedLifetime(delegate) { job.run() }
}

/// Every answer of the Overwrite dialog and every preset of the Copy dialog.
@Suite
internal struct OverwriteChoices {
    internal let box: Sandbox
    internal let old = Date(timeIntervalSince1970: 1_600_000_000), new = Date(timeIntervalSince1970: 1_700_000_000)

    internal var sources: [URL] { [box.url("A/one.txt"), box.url("A/two.txt")] }
    internal var target: TargetSpec { TargetSpec(directory: box.url("B")) }

    internal init() throws {
        box = try Sandbox()
        try box.file("A/one.txt", "source one", modified: new)
        try box.file("A/two.txt", "s2", modified: old)
        try box.file("B/one.txt", "target", modified: old)
        try box.file("B/two.txt", "target two", modified: new)
    }

    @Test
    internal func overwriteAndSkipAreForOneFileEach() {
        let replies = Replies(.overwrite, .skip)
        let result = runJob(.copy, sources, to: target, replies: replies)
        #expect(replies.conflicts == ["one.txt", "two.txt"])
        #expect(box.read("B/one.txt") == "source one" && box.read("B/two.txt") == "target two")
        #expect(result.completed.map(\.lastPathComponent) == ["one.txt"])
    }

    @Test
    internal func overwriteAllAndSkipAllAskOnce() {
        let all = Replies(.overwriteAll)
        runJob(.copy, sources, to: target, replies: all)
        #expect(all.conflicts == ["one.txt"] && box.read("B/two.txt") == "s2")
        let none = Replies(.skipAll)
        try? "again".write(to: box.url("A/one.txt"), atomically: true, encoding: .utf8)
        runJob(.copy, sources, to: target, replies: none)
        #expect(none.conflicts == ["one.txt"] && box.read("B/one.txt") == "source one")
    }

    @Test
    internal func renameAsksAgainWhenTheNewNameIsTakenToo() {
        let replies = Replies(.rename("two.txt"), .rename("fresh.txt"), .skip)
        runJob(.copy, [box.url("A/one.txt")], to: target, replies: replies)
        #expect(replies.conflicts == ["one.txt", "two.txt"])
        #expect(
            box.read("B/fresh.txt") == "source one" && box.read("B/one.txt") == "target"
                && box.read("B/two.txt") == "target two"
        )
    }

    @Test
    internal func renameExistingMovesTheTargetAsideFirst() {
        let result = runJob(.copy, [box.url("A/one.txt")], to: target, replies: Replies(.renameExisting("one.old")))
        #expect(box.read("B/one.old") == "target" && box.read("B/one.txt") == "source one")
        #expect(result.lastTarget?.lastPathComponent == "one.txt")
    }

    @Test
    internal func autoRenameCopiedHoldsForTheRestOfTheJob() {
        let replies = Replies(.autoRenameCopied)
        let result = runJob(.copy, sources, to: target, replies: replies)
        #expect(replies.conflicts == ["one.txt"])
        #expect(box.read("B/one (2).txt") == "source one" && box.read("B/two (2).txt") == "s2")
        #expect(box.read("B/one.txt") == "target" && result.lastTarget?.lastPathComponent == "two (2).txt")
    }

    @Test
    internal func autoRenameExistingKeepsTheOldFilesUnderNumberedNames() {
        runJob(.copy, sources, to: target, replies: Replies(.autoRenameExisting))
        #expect(box.read("B/one (2).txt") == "target" && box.read("B/one.txt") == "source one")
        #expect(box.read("B/two (2).txt") == "target two" && box.read("B/two.txt") == "s2")
    }

    @Test
    internal func theRulesByAgeAndSize() throws {
        // one.txt: the source is newer and larger; two.txt: older and smaller.
        runJob(.copy, sources, to: target, replies: Replies(.copyAllLarger))
        #expect(box.read("B/one.txt") == "source one" && box.read("B/two.txt") == "target two")
        try box.file("B/one.txt", "target", modified: old)
        runJob(.copy, sources, to: target, replies: Replies(.copyAllSmaller))
        #expect(box.read("B/one.txt") == "target" && box.read("B/two.txt") == "s2")

        try box.file("B/two.txt", "same age", modified: old)
        runJob(.copy, sources, to: target, replies: Replies(.overwriteAllOlder))
        #expect(box.read("B/one.txt") == "source one" && box.read("B/two.txt") == "same age")
        runJob(.copy, [box.url("A/two.txt")], to: target, replies: Replies(.overwriteAllOlderOrSame))
        #expect(box.read("B/two.txt") == "s2")
    }

    @Test
    internal func renameOlderSkipNewer() {
        runJob(.copy, sources, to: target, replies: Replies(.renameOlderSkipNewer))
        #expect(box.read("B/one (2).txt") == "target" && box.read("B/one.txt") == "source one")
        #expect(box.read("B/two.txt") == "target two" && !box.exists("B/two (2).txt"))
    }

    @Test
    internal func cancelLeavesEverythingAsItWas() {
        let result = runJob(.copy, sources, to: target, replies: Replies(.cancel))
        #expect(
            result.cancelled && box.read("B/one.txt") == "target"
                && namesOnDisk(box.url("B")) == ["one.txt", "two.txt"]
        )
    }

    @Test
    internal func aPresetAnswersWithoutAsking() {
        let presets: [(OverwriteMode, String, String)] = [
            (.skipAll, "target", "target two"), (.overwriteOlder, "source one", "target two"),
            (.overwriteAll, "source one", "s2")
        ]
        for (mode, one, two) in presets {
            _ = try? box.file("B/one.txt", "target", modified: old)
            _ = try? box.file("B/two.txt", "target two", modified: new)
            let replies = Replies()
            runJob(.copy, sources, to: target, replies: replies) { $0.options.overwrite = mode }
            #expect(
                replies.conflicts.isEmpty && box.read("B/one.txt") == one && box.read("B/two.txt") == two,
                "\(mode)"
            )
        }
        let replies = Replies()
        runJob(.copy, sources, to: target, replies: replies) { $0.options.overwrite = .autoRenameCopied }
        #expect(replies.conflicts.isEmpty && box.read("B/one (2).txt") == "source one")
    }

    @Test
    internal func appendAddsTheSourceToTheEndOfTheTarget() {
        let result = runJob(.copy, [box.url("A/one.txt")], to: target, replies: Replies(.append))
        #expect(box.read("B/one.txt") == "targetsource one" && box.read("A/one.txt") == "source one")
        #expect(result.completed.count == 1 && namesOnDisk(box.url("B")) == ["one.txt", "two.txt"])
    }

    @Test
    internal func resumeContinuesAPartialFile() throws {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/out/big.bin", "0123456789", modified: new, permissions: 0o600)
        try box.file("B/big.bin", "0123", modified: old)
        let result = runJob(
            .copy,
            [memory.url("/out/big.bin")],
            to: target,
            replies: Replies(.resume),
            fileSystems: fileSystems
        ) {
            $0.options.verifies = true
        }
        #expect(result.completed.count == 1 && box.read("B/big.bin") == "0123456789")
        let attributes = try FileManager.default.attributesOfItem(atPath: box.url("B/big.bin").path)
        #expect(attributes[.modificationDate] as? Date == new && attributes[.posixPermissions] as? Int == 0o600)
        #expect(namesOnDisk(box.url("B")) == ["big.bin", "one.txt", "two.txt"])

        // A target that is not shorter than the source is no partial copy of it.
        let replies = Replies(.resume)
        runJob(.copy, [memory.url("/out/big.bin")], to: target, replies: replies, fileSystems: fileSystems)
        #expect(replies.errors.count == 1 && replies.errors[0].contains("cannot be resumed"))
    }

    @Test
    internal func aMoveOntoAnExistingNameAsksToo() {
        let replies = Replies(.overwrite, .skip)
        let result = runJob(.move, sources, to: target, replies: replies)
        #expect(!box.exists("A/one.txt") && box.read("B/one.txt") == "source one")
        #expect(box.exists("A/two.txt") && box.read("B/two.txt") == "target two" && result.completed.count == 1)
    }
}

/// Read-only, hidden and locked items, and merging into an existing folder.
@Suite
internal struct ProtectedItems {
    @Test
    internal func aReadOnlyTargetAsksASecondTime() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "new")
        try box.file("B/one.txt", "old")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: box.url("B/one.txt").path)
        let keep = Replies(.overwrite)
        keep.protection = .skip
        let skipped = runJob(.copy, [box.url("A/one.txt")], to: TargetSpec(directory: box.url("B")), replies: keep)
        #expect(
            keep.protections == ["readOnly overwrite one.txt"] && box.read("B/one.txt") == "old"
                && skipped.completed.isEmpty
        )

        let replace = Replies(.overwrite)
        runJob(.copy, [box.url("A/one.txt")], to: TargetSpec(directory: box.url("B")), replies: replace)
        #expect(replace.protections.count == 1 && box.read("B/one.txt") == "new")

        // "Overwrite/Delete read only/hidden" in the dialog takes the question away.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: box.url("B/one.txt").path)
        let quiet = Replies(.overwrite)
        runJob(.copy, [box.url("A/one.txt")], to: TargetSpec(directory: box.url("B")), replies: quiet) {
            $0.options.ignoresProtection = true
        }
        #expect(quiet.protections.isEmpty)
    }

    @Test
    internal func deletingReadOnlyAndHiddenFilesAsks() {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/a/ro.txt", "r", permissions: 0o444)
        memory.addFile("/a/.hidden", "h")
        memory.addFile("/a/plain.txt", "p")
        let sources = [memory.url("/a/ro.txt"), memory.url("/a/.hidden"), memory.url("/a/plain.txt")]
        let keep = Replies()
        keep.protection = .skip
        let kept = runJob(.delete(toTrash: false), sources, replies: keep, fileSystems: fileSystems) {
            $0.options.asksAboutHidden = true
        }
        #expect(Set(keep.protections) == ["readOnly delete ro.txt", "hidden delete .hidden"])
        #expect(memory.allPaths == ["/a", "/a/.hidden", "/a/ro.txt"] && kept.completed.count == 1)

        // "All" answers the question for the rest of the job; hidden files are not asked about by default.
        memory.addFile("/a/ro2.txt", "r", permissions: 0o400)
        let all = Replies()
        all.protection = .all
        runJob(.delete(toTrash: false), sources + [memory.url("/a/ro2.txt")], replies: all, fileSystems: fileSystems)
        #expect(all.protections == ["readOnly delete ro.txt"] && memory.allPaths == ["/a"])
    }

    @Test
    internal func aLockedFileIsAskedAboutWhenTheSystemRefuses() throws {
        let box = try Sandbox()
        let locked = try box.file("A/locked.txt", "l")
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(locked.path, 0) }
        let keep = Replies()
        keep.protection = .skip
        let kept = runJob(.delete(toTrash: false), [locked], replies: keep)
        #expect(
            keep.protections == ["locked delete locked.txt"] && box.exists("A/locked.txt") && kept.completed.isEmpty
                && keep.errors.isEmpty
        )
        let delete = Replies()
        let deleted = runJob(.delete(toTrash: false), [locked], replies: delete)
        #expect(delete.protections.count == 1 && !box.exists("A/locked.txt") && deleted.completed.count == 1)
    }

    @Test
    internal func mergingIntoAnExistingFolderCanBeAskedAbout() {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/a/docs/one.txt", "1")
        memory.addFile("/b/docs/keep.txt", "k")
        let skip = Replies()
        skip.merge = .skip
        let target = TargetSpec(directory: memory.url("/b"))
        let skipped = runJob(.copy, [memory.url("/a/docs")], to: target, replies: skip, fileSystems: fileSystems) {
            $0.options.asksBeforeMerging = true
        }
        #expect(skip.merges == ["docs"] && !memory.exists("/b/docs/one.txt") && skipped.completed.isEmpty)
        let merge = Replies()
        runJob(.copy, [memory.url("/a/docs")], to: target, replies: merge, fileSystems: fileSystems) {
            $0.options.asksBeforeMerging = true
        }
        #expect(memory.exists("/b/docs/one.txt") && memory.exists("/b/docs/keep.txt"))
        // Without the option folders merge silently, as before.
        let silent = Replies(.overwrite)
        runJob(.copy, [memory.url("/a/docs")], to: target, replies: silent, fileSystems: fileSystems)
        #expect(silent.merges.isEmpty && silent.conflicts == ["one.txt"])
    }
}

/// The options of the Copy dialog: filter, attributes, links, verify, errors, the log's records.
@Suite
internal struct TransferOptionsInJobs {
    @Test
    internal func theFilterChoosesWhatIsCopied() {
        let (fileSystems, memory) = makeFileSystems()
        for path in [
            "/a/one.txt", "/a/two.bak", "/a/docs/in.txt", "/a/docs/pic.jpg", "/a/docs/build/out.txt",
            "/a/empty/none.jpg"
        ] {
            memory.addFile(path, "x")
        }
        memory.addDirectory("/b")
        let sources = ["one.txt", "two.bak", "docs", "empty"].map { memory.url("/a/" + $0) }
        let result = runJob(
            .copy,
            sources,
            to: TargetSpec(directory: memory.url("/b")),
            replies: Replies(),
            fileSystems: fileSystems
        ) {
            $0.options.filter = CopyFilter("*.txt | build/")
        }
        #expect(
            memory.allPaths.filter { $0.hasPrefix("/b/") } == ["/b/docs", "/b/docs/in.txt", "/b/empty", "/b/one.txt"]
        )
        // A file the filter left out stays selected; a folder that was entered does not.
        #expect(Set(result.completed.map(\.lastPathComponent)) == ["one.txt", "docs", "empty"])

        memory.removeTree("/b")
        memory.addDirectory("/b")
        runJob(
            .copy,
            sources,
            to: TargetSpec(directory: memory.url("/b")),
            replies: Replies(),
            fileSystems: fileSystems
        ) {
            $0.options.filter = CopyFilter("*.txt | build/ **/")
        }
        #expect(memory.allPaths.filter { $0.hasPrefix("/b/") } == ["/b/docs", "/b/docs/in.txt", "/b/one.txt"])
    }

    @Test
    internal func aFilteredMoveKeepsWhatWasLeftOut() {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/a/docs/in.txt", "t")
        memory.addFile("/a/docs/pic.jpg", "j")
        memory.addDirectory("/b")
        runJob(
            .move,
            [memory.url("/a/docs")],
            to: TargetSpec(directory: memory.url("/b")),
            replies: Replies(),
            fileSystems: fileSystems
        ) {
            $0.options.filter = CopyFilter("*.txt")
        }
        #expect(memory.allPaths == ["/a", "/a/docs", "/a/docs/pic.jpg", "/b", "/b/docs", "/b/docs/in.txt"])
    }

    @Test
    internal func renameMasksInTheTarget() throws {
        let (fileSystems, memory) = makeFileSystems()
        let box = try Sandbox()
        try box.file("A/report.txt", "r")
        try box.file("A/notes.md", "n")
        let sources = [box.url("A/report.txt"), box.url("A/notes.md")]
        let spec = TargetSpec.parse(
            "mem:/backup/*.bak",
            sourceDirectory: box.url("A"),
            operandCount: 2,
            fileSystems: fileSystems
        )
        memory.createDirectory(at: spec.directory)
        runJob(.copy, sources, to: spec, replies: Replies(), fileSystems: fileSystems)
        #expect(memory.allPaths == ["/backup", "/backup/notes.bak", "/backup/report.bak"])
        // Relative to the source folder, with a prefix mask.
        let relative = TargetSpec.parse(
            "../old_**.*",
            sourceDirectory: box.url("A"),
            operandCount: 2,
            fileSystems: fileSystems
        )
        runJob(.copy, sources, to: relative, replies: Replies(), fileSystems: fileSystems)
        #expect(box.read("old_notes.md") == "n" && box.read("old_report.txt") == "r")
        // Two sources that land on one name: the second meets the first as a conflict.
        let replies = Replies(.autoRenameCopied)
        runJob(
            .copy,
            sources,
            to: TargetSpec(directory: memory.url("/backup"), mask: "same.txt"),
            replies: replies,
            fileSystems: fileSystems
        )
        #expect(
            replies.conflicts == ["same.txt"] && memory.contents("/backup/same.txt") == "n"
                && memory.contents("/backup/same (2).txt") == "r"
        )
    }

    @Test
    internal func attributesAndFolderDates() throws {
        let box = try Sandbox()
        let stamp = Date(timeIntervalSince1970: 1_500_000_000)
        try box.file("A/docs/tool.sh", "#!/bin/sh", modified: stamp)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: box.url("A/docs/tool.sh").path)
        try FileManager.default.setAttributes(
            [.modificationDate: stamp, .posixPermissions: 0o700],
            ofItemAtPath: box.url("A/docs").path
        )
        func date(_ path: String) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: box.url(path).path))?[.modificationDate] as? Date
        }
        func mode(_ path: String) -> Int? {
            (try? FileManager.default.attributesOfItem(atPath: box.url(path).path))?[.posixPermissions] as? Int
        }
        runJob(.copy, [box.url("A/docs")], to: TargetSpec(directory: box.url("B")), replies: Replies()) {
            $0.options.preservesFolderDates = true
        }
        #expect(
            date("B/docs") == stamp && mode("B/docs") == 0o700 && date("B/docs/tool.sh") == stamp
                && mode("B/docs/tool.sh") == 0o750
        )

        runJob(.copy, [box.url("A/docs")], to: TargetSpec(directory: box.url("C")), replies: Replies()) {
            $0.options.preservesAttributes = false
        }
        #expect(mode("C/docs/tool.sh") == 0o644 && (date("C/docs/tool.sh") ?? stamp) > Date(timeIntervalSinceNow: -60))
        #expect(date("C/docs") != stamp)
    }

    @Test
    internal func linksAreCopiedAsLinksOrFollowed() throws {
        let box = try Sandbox()
        try box.file("real/inside.txt", "i")
        try box.file("real.txt", "content")
        for folder in ["A", "B", "C"] { try box.folder(folder) }
        try FileManager.default.createSymbolicLink(at: box.url("A/dir-link"), withDestinationURL: box.url("real"))
        try FileManager.default.createSymbolicLink(at: box.url("A/file-link"), withDestinationURL: box.url("real.txt"))
        let sources = [box.url("A/dir-link"), box.url("A/file-link")]
        func isLink(_ path: String) -> Bool {
            (try? FileManager.default.destinationOfSymbolicLink(atPath: box.url(path).path)) != nil
        }
        runJob(.copy, sources, to: TargetSpec(directory: box.url("B")), replies: Replies())
        #expect(isLink("B/dir-link") && isLink("B/file-link"))
        let replies = Replies()
        runJob(.copy, sources, to: TargetSpec(directory: box.url("C")), replies: replies) {
            $0.options.links = .followLinks
        }
        #expect(!isLink("C/dir-link") && !isLink("C/file-link"))
        #expect(box.read("C/dir-link/inside.txt") == "i" && box.read("C/file-link") == "content")
        #expect(replies.progress.last?.itemsTotal == 3 && replies.progress.last?.bytesTotal == 8)
    }

    @Test
    internal func verifyCatchesACorruptedCopy() throws {
        let box = try Sandbox()
        let (fileSystems, wrapped) = makeWrappedFileSystems()
        try box.file("A/data.bin", String(repeating: "d", count: 3_000))
        wrapped.base.addDirectory("/inbox")
        let source = [box.url("A/data.bin")]
        let target = TargetSpec(directory: wrapped.base.url("/inbox"))

        wrapped.corruptsWrites = true
        // Without Verify the damage goes unnoticed.
        runJob(.copy, source, to: target, replies: Replies(), fileSystems: fileSystems)
        // (The damaged bytes are no text any more, so there is nothing to read back as a string.)
        #expect(
            wrapped.base.item(at: wrapped.base.url("/inbox/data.bin"))?.size == 3_000
                && wrapped.base.contents("/inbox/data.bin") == nil
        )
        wrapped.base.removeTree("/inbox/data.bin")

        let replies = Replies()
        let failed = runJob(.copy, source, to: target, replies: replies, fileSystems: fileSystems) {
            $0.options.verifies = true
        }
        #expect(replies.errors.count == 1 && replies.errors[0].hasPrefix("Verify failed"))
        // Neither the damaged file nor its temporary name remains, and the source is untouched.
        #expect(wrapped.base.allPaths == ["/inbox"] && failed.completed.isEmpty && failed.failureCount == 1)
        #expect(box.read("A/data.bin")?.count == 3_000)

        // A verified move keeps the source when the copy is bad, and removes it when it is good.
        let moving = Replies()
        runJob(.move, source, to: target, replies: moving, fileSystems: fileSystems) { $0.options.verifies = true }
        #expect(box.exists("A/data.bin") && wrapped.base.allPaths == ["/inbox"])
        wrapped.corruptsWrites = false
        let good = runJob(.move, source, to: target, replies: Replies(), fileSystems: fileSystems) {
            $0.options.verifies = true
        }
        #expect(
            good.completed.count == 1 && !box.exists("A/data.bin")
                && wrapped.base.contents("/inbox/data.bin")?.count == 3_000
        )
    }

    @Test
    internal func checksumsCompareContents() throws {
        let (fileSystems, memory) = makeFileSystems()
        let box = try Sandbox()
        try box.file("a.txt", "same")
        memory.addFile("/b.txt", "same")
        memory.addFile("/c.txt", "samf")
        #expect(try Checksum.sameContents(box.url("a.txt"), memory.url("/b.txt"), in: fileSystems) == true)
        #expect(try Checksum.sameContents(box.url("a.txt"), memory.url("/c.txt"), in: fileSystems) == false)
        #expect(
            try Checksum.sameContents(box.url("a.txt"), memory.url("/b.txt"), in: fileSystems, isCancelled: { true })
                == nil
        )
        #expect(
            try Checksum.sha256(of: memory.url("/b.txt"), in: fileSystems)?.map { String(format: "%02x", $0) }.joined()
                .hasPrefix("0967115f") == true
        )
    }

    @Test
    internal func keepingGoingOnErrorsSkipsWithoutAskingAndCounts() {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/a/one.txt", "1")
        memory.addDirectory("/b")
        let replies = Replies()
        let result = runJob(
            .copy,
            [memory.url("/a/gone.txt"), memory.url("/a/one.txt")],
            to: TargetSpec(directory: memory.url("/b")),
            replies: replies,
            fileSystems: fileSystems
        ) { $0.options.skipsErrors = true }
        #expect(
            replies.errors.isEmpty && result.failureCount == 1 && result.failures.first?.contains("gone.txt") == true
        )
        #expect(memory.exists("/b/one.txt") && result.completed.count == 1)
    }

    @Test
    internal func aPartFileCanBeKeptAndResumed() throws {
        let box = try Sandbox()
        let (fileSystems, memory) = makeFileSystems()
        let content = String(repeating: "0123456789abcdef", count: (5 << 20) / 16)
        try box.file("A/big.bin", content)
        memory.addDirectory("/inbox")
        let target = TargetSpec(directory: memory.url("/inbox"))
        let replies = Replies()
        replies.cancelAtBytes = 2 << 20
        let cancelled = runJob(.copy, [box.url("A/big.bin")], to: target, replies: replies, fileSystems: fileSystems) {
            $0.options.keepsPartialFiles = true
        }
        let partial = memory.item(at: memory.url("/inbox/big.bin"))?.size ?? 0
        #expect(
            cancelled.cancelled && partial > 0 && partial < Int64(content.count)
                && memory.allPaths == ["/inbox", "/inbox/big.bin"]
        )
        let resumed = runJob(
            .copy,
            [box.url("A/big.bin")],
            to: target,
            replies: Replies(.resume),
            fileSystems: fileSystems
        ) { $0.options.verifies = true }
        #expect(resumed.completed.count == 1 && memory.contents("/inbox/big.bin") == content)
    }

    @Test
    internal func everyItemIsRecordedForTheLog() {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/a/docs/in.txt", "1")
        memory.addFile("/a/one.txt", "new")
        memory.addFile("/b/one.txt", "old")
        let lock = NSLock()
        // Guarded by `lock`.
        nonisolated(unsafe) var lines: [String] = []
        let collect = { @Sendable (record: OperationRecord) in
            lock.withLock { lines.append(OperationLog.line(for: record, at: "T")) }
        }
        let sources = [memory.url("/a/docs"), memory.url("/a/one.txt"), memory.url("/a/gone.txt")]
        runJob(
            .copy,
            sources,
            to: TargetSpec(directory: memory.url("/b")),
            replies: Replies(.skip),
            fileSystems: fileSystems
        ) { $0.onRecord = collect }
        #expect(
            Set(lines) == [
                "T: New folder: mem:/b/docs\n", "T: Copy: mem:/a/docs/in.txt -> mem:/b/docs/in.txt\n",
                "T: Skipped: Copy: mem:/a/one.txt -> mem:/b/one.txt\n",
                "T: Error: Copy: mem:/a/gone.txt: mem:/a/gone.txt does not exist any more!\n",
                "T: Skipped: Copy: mem:/a/gone.txt\n"
            ]
        )
        lines = []
        runJob(.delete(toTrash: false), [memory.url("/b/docs")], replies: Replies(), fileSystems: fileSystems) {
            $0.onRecord = collect
        }
        #expect(lines == ["T: Delete: mem:/b/docs/in.txt\n", "T: Delete folder: mem:/b/docs\n"])
        lines = []
        runJob(
            .move,
            [memory.url("/a/one.txt")],
            to: TargetSpec(directory: memory.url("/b")),
            replies: Replies(.append),
            fileSystems: fileSystems
        ) {
            $0.onRecord = collect
        }
        #expect(
            lines == ["T: Append: mem:/a/one.txt -> mem:/b/one.txt\n"] && memory.contents("/b/one.txt") == "oldnew"
                && !memory.exists("/a/one.txt")
        )
    }
}

/// Several small files at once, and what stays the same when they are.
@Suite
internal struct ParallelCopies {
    internal static let count = 120

    /// A tree of small files in memory: /src/file000.txt … and /src/sub/….
    internal func fill(_ memory: MemoryFileSystem) {
        for index in 0..<Self.count {
            memory.addFile(String(format: "/src/file%03d.txt", index), "content \(index)")
            if index % 4 == 0 { memory.addFile(String(format: "/src/sub/deep%03d.txt", index), "deep \(index)") }
        }
    }

    @Test
    internal func smallFilesAreCopiedSeveralAtOnceOnLocalStorage() {
        let (fileSystems, wrapped) = makeWrappedFileSystems()
        fill(wrapped.base)
        wrapped.base.addDirectory("/dst")
        wrapped.delay = 0.002
        let replies = Replies()
        let result = runJob(
            .copy,
            [wrapped.base.url("/src")],
            to: TargetSpec(directory: wrapped.base.url("/dst")),
            replies: replies,
            fileSystems: fileSystems
        ) { $0.parallelWidth = 4 }
        #expect(result.completed.count == 1 && !result.cancelled)
        #expect(wrapped.mostWritesAtOnce > 1 && wrapped.mostWritesAtOnce <= 4)
        for index in 0..<Self.count {
            #expect(wrapped.base.contents(String(format: "/dst/src/file%03d.txt", index)) == "content \(index)")
        }
        #expect(
            wrapped.base.allPaths.filter { $0.hasPrefix("/dst/") }.count == ParallelCopies.count + ParallelCopies.count
                / 4 + 2
        )
        // The counters stay consistent: they never go back, and they end at the totals.
        let progress = replies.progress
        #expect(
            zip(progress, progress.dropFirst())
                .allSatisfy {
                    $0.itemsDone <= $1.itemsDone && $0.bytesDone <= $1.bytesDone
                }
        )
        #expect(
            progress.last?.itemsDone == progress.last?.itemsTotal
                && progress.last?.bytesDone == progress.last?.bytesTotal
        )
        #expect(progress.last?.itemsTotal == ParallelCopies.count + ParallelCopies.count / 4 + 2)
    }

    @Test
    internal func aNetworkVolumeGetsASingleStream() {
        let (fileSystems, wrapped) = makeWrappedFileSystems()
        fill(wrapped.base)
        wrapped.base.addDirectory("/dst")
        wrapped.base.isLocal = false
        wrapped.delay = 0.001
        runJob(
            .copy,
            [wrapped.base.url("/src")],
            to: TargetSpec(directory: wrapped.base.url("/dst")),
            replies: Replies(),
            fileSystems: fileSystems
        )
        #expect(wrapped.mostWritesAtOnce == 1 && wrapped.base.exists("/dst/src/file119.txt"))
        // The same when the option is switched off.
        let (others, local) = makeWrappedFileSystems()
        fill(local.base)
        local.base.addDirectory("/dst")
        local.delay = 0.001
        runJob(
            .copy,
            [local.base.url("/src")],
            to: TargetSpec(directory: local.base.url("/dst")),
            replies: Replies(),
            fileSystems: others
        ) {
            $0.options.copiesSmallFilesInParallel = false
        }
        #expect(local.mostWritesAtOnce == 1)
    }

    @Test
    internal func conflictsAreAskedOneAtATimeInProcessingOrder() {
        let (fileSystems, wrapped) = makeWrappedFileSystems()
        fill(wrapped.base)
        for index in stride(from: 0, to: Self.count, by: 10) {
            wrapped.base.addFile(String(format: "/dst/src/file%03d.txt", index), "old")
        }
        wrapped.delay = 0.001
        let replies = Replies(.overwrite, .skip)
        runJob(
            .copy,
            [wrapped.base.url("/src")],
            to: TargetSpec(directory: wrapped.base.url("/dst")),
            replies: replies,
            fileSystems: fileSystems
        )
        #expect(
            replies.conflicts
                == stride(from: 0, to: ParallelCopies.count, by: 10).map { String(format: "file%03d.txt", $0) }
        )
        #expect(
            wrapped.base.contents("/dst/src/file000.txt") == "content 0"
                && wrapped.base.contents("/dst/src/file010.txt") == "old"
        )
        #expect(wrapped.base.contents("/dst/src/file011.txt") == "content 11")
    }

    @Test
    internal func aCancelledParallelCopyLeavesNoPartialFiles() throws {
        let box = try Sandbox()
        let (fileSystems, wrapped) = makeWrappedFileSystems()
        // Streams from memory onto the disk: each file arrives under a temporary name first.
        for index in 0..<Self.count {
            wrapped.base.addFile(
                String(format: "/src/file%03d.txt", index),
                String(repeating: "\(index % 10)", count: 3_000)
            )
        }
        try box.folder("B")
        let replies = Replies()
        replies.cancelAtItems = 30
        let result = runJob(
            .copy,
            [wrapped.base.url("/src")],
            to: TargetSpec(directory: box.url("B")),
            replies: replies,
            fileSystems: fileSystems
        ) {
            $0.parallelWidth = 6
        }
        #expect(result.cancelled && result.completed.isEmpty)
        let arrived = namesOnDisk(box.url("B/src"))
        #expect(arrived.count >= 29 && arrived.count < ParallelCopies.count)
        // No temporary names, and every file that is there is whole.
        #expect(arrived.allSatisfy { $0.hasPrefix("file") && box.read("B/src/" + $0)?.count == 3_000 })
        // Nothing arrives after the job has returned.
        Thread.sleep(forTimeInterval: 0.05)
        #expect(namesOnDisk(box.url("B/src")) == arrived)
    }

    @Test
    internal func manySmallFilesOnDiskArriveCompleteInBothDirections() throws {
        let box = try Sandbox()
        let (fileSystems, memory) = makeFileSystems()
        for index in 0..<200 {
            try box.file(String(format: "A/tree/d%d/f%03d.txt", index % 7, index), "disk \(index)")
        }
        let onDisk = runJob(
            .copy,
            [box.url("A/tree")],
            to: TargetSpec(directory: box.url("B")),
            replies: Replies(),
            fileSystems: fileSystems
        )
        #expect(onDisk.completed.count == 1)
        memory.addDirectory("/in")
        let toMemory = runJob(
            .copy,
            [box.url("B/tree")],
            to: TargetSpec(directory: memory.url("/in")),
            replies: Replies(),
            fileSystems: fileSystems
        )
        #expect(toMemory.completed.count == 1 && memory.allPaths.count == 1 + 1 + 7 + 200)
        let back = runJob(
            .move,
            [memory.url("/in/tree")],
            to: TargetSpec(directory: box.url("C")),
            replies: Replies(),
            fileSystems: fileSystems
        )
        #expect(back.completed.count == 1 && memory.allPaths == ["/in"])
        for index in 0..<200 {
            #expect(box.read(String(format: "C/tree/d%d/f%03d.txt", index % 7, index)) == "disk \(index)")
        }
        #expect(namesOnDisk(box.url("C/tree/d3")).allSatisfy { $0.hasPrefix("f") })
    }

    @Test
    internal func anErrorInAWorkerAsksLikeAnyOtherAndAbortStopsEverything() {
        let (fileSystems, wrapped) = makeWrappedFileSystems()
        fill(wrapped.base)
        wrapped.base.addDirectory("/dst")
        wrapped.corruptsWrites = true
        wrapped.base.refusesInternalCopy = true
        let replies = Replies()
        replies.failure = .abort
        let result = runJob(
            .copy,
            [wrapped.base.url("/src")],
            to: TargetSpec(directory: wrapped.base.url("/dst")),
            replies: replies,
            fileSystems: fileSystems
        ) { $0.options.verifies = true }
        #expect(result.cancelled && replies.errors.count == 1)
        #expect(wrapped.base.allPaths.filter { $0.hasPrefix("/dst/src/") && !$0.hasSuffix("/sub") }.isEmpty)
    }
}
