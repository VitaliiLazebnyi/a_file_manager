import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileOperationsPlugin

// Review round 2, integration: the kernel calls that arrived after the file-operation pass
// was over, now used by `FileJob` — removal below a folder without following links (F043)
// and a commit that asks while it runs (F046).

/// The local file system with a moment to interfere right before an entry is removed.
///
/// Unchecked: what it records is guarded by `lock`; its switches are set by the test before use.
final class IntegrationRacingLocalFileSystem: FileSystemProvider, @unchecked Sendable {
    let local = LocalFileSystem()
    var scheme: String { local.scheme }
    var capabilities: FileSystemCapabilities { local.capabilities }
    var readsRootedPaths: Bool { local.readsRootedPaths }
    var beforeRemoving: ((URL) -> Void)?
    private let lock = NSLock()
    private var rooted: [String] = []
    private var plain: [String] = []

    /// The removals that came with the top of their tree, and those that came by path alone.
    var removals: (below: [String], byPath: [String]) { lock.withLock { (rooted, plain) } }

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
    func createDirectory(at url: URL) throws { try local.createDirectory(at: url) }
    func remove(_ url: URL) throws {
        beforeRemoving?(url)
        lock.withLock { plain.append(url.lastPathComponent) }
        try local.remove(url)
    }
    func remove(_ url: URL, cancellation: CancellationFlag) throws {
        beforeRemoving?(url)
        lock.withLock { plain.append(url.lastPathComponent) }
        try local.remove(url, cancellation: cancellation)
    }
    func remove(_ url: URL, below root: URL, cancellation: CancellationFlag) throws {
        beforeRemoving?(url)
        lock.withLock { rooted.append(url.lastPathComponent) }
        try local.remove(url, below: root, cancellation: cancellation)
    }
}

/// Answers every question with "go on" and keeps what was reported.
final class IntegrationReplies: FileJobDelegate {
    private let lock = NSLock()
    private var messages: [String] = []
    private var reports = 0
    /// Called with every progress report, on the thread that reports.
    var onProgress: ((JobProgress) -> Void)?

    var errors: [String] { lock.withLock { messages } }
    var progressReports: Int { lock.withLock { reports } }

    func job(_: FileJob, progress: JobProgress) {
        lock.withLock { reports += 1 }
        onProgress?(progress)
    }
    func job(_: FileJob, conflictAt _: FileItem, source _: FileItem) -> ConflictChoice { .overwrite }
    func job(_: FileJob, failedAt _: URL, error: any Error) -> ErrorChoice {
        lock.withLock { messages.append(error.localizedDescription) }
        return .skip
    }
    func job(_: FileJob, confirmDeleteNonEmpty _: URL) -> FolderDeleteChoice { .delete }
}

@Suite struct Review2IntegrationFileops {
    let box: Sandbox

    init() throws {
        box = try Sandbox()
    }

    private func names(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: box.url(path).path)) ?? []).sorted()
    }

    // MARK: F043 — a tree is deleted from its top folder down, through no link

    @Test func whatLiesBelowADeletedFolderIsRemovedFromThatFolderDownAndTheFolderByItsPath() throws {
        let racing = IntegrationRacingLocalFileSystem()
        let registry = FileSystemRegistry()
        registry.register(racing)
        try box.file("tree/a.txt", "a")
        try box.file("tree/sub/b.txt", "b")
        try box.file("tree/sub/deep/c.txt", "c")
        try box.file("alone.txt", "x")
        let replies = IntegrationReplies()
        let job = FileJob(
            kind: .delete(toTrash: false),
            sources: [box.url("tree"), box.url("alone.txt")],
            fileSystems: registry
        )
        job.delegate = replies
        _ = job.run()
        #expect(replies.errors.isEmpty && !box.exists("tree") && !box.exists("alone.txt"))
        let removals = racing.removals
        // Everything inside the folder by the walk from the folder; the job's own sources by path.
        #expect(Set(removals.below) == ["a.txt", "b.txt", "c.txt", "deep", "sub"])
        #expect(Set(removals.byPath) == ["tree", "alone.txt"])
    }

    @Test func aFolderSwappedForALinkWhileItsTreeIsDeletedCostsNothingOutsideTheTree() throws {
        let racing = IntegrationRacingLocalFileSystem()
        let registry = FileSystemRegistry()
        registry.register(racing)
        try box.file("victim/sub/a.txt", "inside")
        try box.file("victim/sub/b.txt", "inside")
        try box.file("outside/a.txt", "not the job's")
        try box.file("outside/b.txt", "not the job's")
        let (sub, aside, outside) = (box.url("victim/sub"), box.url("victim/sub.real"), box.url("outside"))
        // After the folder was listed and right before its first file goes, the folder is
        // moved aside and a link to another folder, with files of the same names, takes its place.
        var swapped = false
        racing.beforeRemoving = { url in
            guard !swapped, url.deletingLastPathComponent().lastPathComponent == "sub" else { return }
            swapped = true
            try? FileManager.default.moveItem(at: sub, to: aside)
            try? FileManager.default.createSymbolicLink(at: sub, withDestinationURL: outside)
        }
        let replies = IntegrationReplies()
        let job = FileJob(kind: .delete(toTrash: false), sources: [box.url("victim")], fileSystems: registry)
        // One after the other, so that the swap comes before every removal in the folder.
        job.options.copiesSmallFilesInParallel = false
        job.delegate = replies
        _ = job.run()
        #expect(swapped)
        // Nothing of the folder the link leads to is gone, and the user was told.
        #expect(names("outside") == ["a.txt", "b.txt"] && box.read("outside/a.txt") == "not the job's")
        #expect(!replies.errors.isEmpty)
        #expect(
            replies.errors.allSatisfy {
                $0.contains("no longer a folder") || $0.contains("not empty") || $0.contains("Directory not empty")
            },
            "\(replies.errors)"
        )
        // The files that were moved aside are as they were; the tree could not be emptied, so it stays.
        #expect(names("victim/sub.real") == ["a.txt", "b.txt"] && box.exists("victim"))
    }

    @Test func aMoveToAnotherFileSystemTakesTheOriginalsAwayFromTheirTopFolderDown() {
        let (from, to) = (MemoryFileSystem(scheme: "from"), MemoryFileSystem(scheme: "to"))
        let registry = FileSystemRegistry()
        registry.register(from)
        registry.register(to)
        from.addFile("/s/tree/a.txt", "a")
        from.addFile("/s/tree/sub/b.txt", "b")
        from.addFile("/s/single.txt", "s")
        to.addDirectory("/t")
        let replies = IntegrationReplies()
        let job = FileJob(
            kind: .move,
            sources: [from.url("/s/tree"), from.url("/s/single.txt")],
            target: TargetSpec(directory: to.url("/t")),
            fileSystems: registry
        )
        job.delegate = replies
        _ = job.run()
        #expect(
            replies.errors.isEmpty && to.contents("/t/tree/sub/b.txt") == "b" && to.contents("/t/single.txt") == "s"
        )
        #expect(from.allPaths.filter { $0.hasPrefix("/s/") }.isEmpty)
        let removals = Set(from.flaggedChanges.filter { $0.hasPrefix("remove") })
        #expect(
            removals == [
                "remove below /s/tree /s/tree/a.txt", "remove below /s/tree /s/tree/sub/b.txt",
                "remove below /s/tree /s/tree/sub",
                "remove /s/tree", "remove /s/single.txt"
            ]
        )
    }

    // MARK: F046 — a commit that takes long reports, can be paused and can be ended

    private func slowTarget() -> (from: MemoryFileSystem, to: MemoryFileSystem, registry: FileSystemRegistry) {
        let (from, to) = (MemoryFileSystem(scheme: "from"), MemoryFileSystem(scheme: "late"))
        to.capabilities = [.write, .deferredWrites]
        to.commitSteps = 50
        let registry = FileSystemRegistry()
        registry.register(from)
        registry.register(to)
        from.addFile("/s/a.txt", "a")
        from.addFile("/s/b.txt", "b")
        to.addDirectory("/t")
        return (from, to, registry)
    }

    @Test func aCommitThatTakesLongReportsWhileItRunsSoThatAPausedJobWaitsInsideIt() {
        let (from, to, registry) = slowTarget()
        let replies = IntegrationReplies()
        let lock = NSLock()
        var duringCommit = 0
        replies.onProgress = { progress in
            // Where a paused job would be held: the report is made from inside the commit.
            if progress.lines.first?.hasPrefix("Writing:") == true { lock.withLock { duringCommit += 1 } }
        }
        let job = FileJob(
            kind: .move,
            sources: [from.url("/s/a.txt"), from.url("/s/b.txt")],
            target: TargetSpec(directory: to.url("/t")),
            fileSystems: registry
        )
        job.delegate = replies
        _ = job.run()
        #expect(replies.errors.isEmpty && to.commits == ["/t"])
        // One report announces the commit; the others came while it ran (every step of it is asked).
        #expect(lock.withLock { duringCommit } > 10)
        #expect(from.allPaths.filter { $0.hasPrefix("/s/") }.isEmpty && to.contents("/t/a.txt") == "a")
    }

    @Test func aCommitThatIsStoppedWhileItRunsRemovesNoOriginal() {
        let (from, to, registry) = slowTarget()
        let replies = IntegrationReplies()
        let job = FileJob(
            kind: .move,
            sources: [from.url("/s/a.txt"), from.url("/s/b.txt")],
            target: TargetSpec(directory: to.url("/t")),
            fileSystems: registry
        )
        job.delegate = replies
        var reportsOfTheCommit = 0
        replies.onProgress = { [weak job] progress in
            guard progress.lines.first?.hasPrefix("Writing:") == true else { return }
            reportsOfTheCommit += 1
            // In the middle of the commit the user presses Cancel.
            if reportsOfTheCommit == 5 { job?.cancel() }
        }
        _ = job.run()
        // The commit was ended before it was made, and what is not known to be written keeps its original.
        #expect(to.commits.isEmpty)
        #expect(from.contents("/s/a.txt") == "a" && from.contents("/s/b.txt") == "b")
    }
}
