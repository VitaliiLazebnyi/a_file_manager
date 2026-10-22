import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileOperationsPlugin

// The job code on real volumes. These need disk images mounted by hand, so they run only when
// AFM_VOLUME_TESTS=1 and the mount points are given:
//
//   AFM_VOLUME_A, AFM_VOLUME_B   two APFS volumes (case-insensitive)
//   AFM_VOLUME_CS                one "Case-sensitive APFS" volume
//
//   hdiutil create -size 64m -fs APFS -volname AFMA a.dmg
//   hdiutil create -size 64m -fs "Case-sensitive APFS" -volname AFMCS cs.dmg
//   hdiutil attach -nobrowse -mountpoint /some/dir a.dmg   (and so on)

private let environment = ProcessInfo.processInfo.environment
private let volumesAreMounted =
    environment["AFM_VOLUME_TESTS"] == "1" && environment["AFM_VOLUME_A"] != nil
    && environment["AFM_VOLUME_B"] != nil && environment["AFM_VOLUME_CS"] != nil

private func volume(_ key: String) -> URL {
    URL(fileURLWithPath: environment[key] ?? "/nonexistent", isDirectory: true).resolvingSymlinksInPath()
}

/// The local disk behind a layer that makes copies take a moment, counts how many run at once
/// and per file, and lets chosen removals fail once.
///
/// Unchecked: what it records is guarded by `lock`; its switches are set by the test before use.
internal final class LocalProbe: FileSystemProvider, @unchecked Sendable {
    private let local = LocalFileSystem()
    internal var scheme: String { local.scheme }
    internal var capabilities: FileSystemCapabilities { local.capabilities }
    /// Names whose first removal fails.
    internal var failsOnce: Set<String> = []
    private let lock = NSLock()
    private var running = 0, most = 0
    private var copied: [String: Int] = [:]
    private var removalsFailed = 0

    internal var mostCopiesAtOnce: Int { lock.withLock { most } }
    internal var totalCopies: Int { lock.withLock { copied.values.reduce(0, +) } }
    internal var failedRemovals: Int { lock.withLock { removalsFailed } }
    internal func copies(of name: String) -> Int { lock.withLock { copied[name] ?? 0 } }

    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try local.list(directory, showHidden: showHidden)
    }
    internal func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        try local.list(directory, showHidden: showHidden, cancellation: cancellation)
    }
    internal func item(at url: URL) -> FileItem? { local.item(at: url) }
    internal func parent(of directory: URL) -> URL? { local.parent(of: directory) }
    internal func read(_ url: URL) throws -> any FileReader { try local.read(url) }
    internal func createDirectory(at url: URL) throws { try local.createDirectory(at: url) }
    internal func write(_ url: URL) throws -> any FileWriter { try local.write(url) }
    internal func append(to url: URL, at offset: Int64?, cancellation: CancellationFlag) throws -> any FileWriter {
        try local.append(to: url, at: offset, cancellation: cancellation)
    }
    internal func remove(_ url: URL) throws {
        let fails: Bool = lock.withLock {
            guard failsOnce.remove(url.lastPathComponent) != nil else {
                return false
            }
            removalsFailed += 1
            return true
        }
        if fails { throw CocoaError(.fileWriteNoPermission) }
        try local.remove(url)
    }
    internal func trash(_ url: URL) throws { try local.trash(url) }
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try local.move(source, to: destination, replacing: replacing)
    }
    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        lock.withLock {
            running += 1
            most = max(most, running)
            copied[source.lastPathComponent, default: 0] += 1
        }
        defer { lock.withLock { running -= 1 } }
        // Long enough for the copies of a pool to overlap.
        Thread.sleep(forTimeInterval: 0.03)
        try local.copy(source, to: destination, progress: progress)
    }
    internal func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        try local.setAttributes(attributes, of: url)
    }
    internal func copyMetadata(from source: URL, to destination: URL) throws {
        try local.copyMetadata(from: source, to: destination)
    }
    internal func quarantine(of url: URL) -> Data? { local.quarantine(of: url) }
    internal func setQuarantine(_ value: Data, of url: URL) throws { try local.setQuarantine(value, of: url) }
    internal func displayPath(_ url: URL) -> String { local.displayPath(url) }
    internal func volume(of url: URL) -> VolumeInfo? { local.volume(of: url) }
}

private func scratch(_ volume: URL) throws -> URL {
    let folder = volume.appendingPathComponent("test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// Whether names that differ in letter case are one entry on the volume that holds `folder`.
private func foldsCase(in folder: URL) throws -> Bool {
    try write("probe", to: folder.appendingPathComponent("Probe-File"))
    defer { try? FileManager.default.removeItem(at: folder.appendingPathComponent("Probe-File")) }
    return exists(folder.appendingPathComponent("probe-file"))
}

@Suite(
    .enabled(
        if: volumesAreMounted,
        "needs mounted disk images: set AFM_VOLUME_TESTS=1, AFM_VOLUME_A, AFM_VOLUME_B, AFM_VOLUME_CS"
    )
)
internal struct FileOpsAdoptVolumes {
    @Test
    internal func theThreeVolumesAreTheKindsTheseTestsNeed() throws {
        let (a, b, cs) = (volume("AFM_VOLUME_A"), volume("AFM_VOLUME_B"), volume("AFM_VOLUME_CS"))
        #expect(FileIdentity.device(of: a) != FileIdentity.device(of: b))
        #expect(FileIdentity.device(of: a) != FileIdentity.device(of: cs))
        let (folderA, folderCS) = (try scratch(a), try scratch(cs))
        defer {
            try? FileManager.default.removeItem(at: folderA)
            try? FileManager.default.removeItem(at: folderCS)
        }
        #expect(try foldsCase(in: folderA))
        #expect(try !foldsCase(in: folderCS))
    }

    // MARK: (a) A folder move between two volumes

    private func makeTree(in folder: URL) throws -> (tree: URL, files: [String: String]) {
        let tree = folder.appendingPathComponent("tree", isDirectory: true)
        var files: [String: String] = [:]
        for index in 0..<40 { files["f\(index).txt"] = "content of file \(index)" }
        for sub in ["one", "two", "three"] {
            for index in 0..<5 { files["\(sub)/g\(index).txt"] = "\(sub) file \(index)" }
        }
        for (path, content) in files { try write(content, to: tree.appendingPathComponent(path)) }
        return (tree, files)
    }

    @Test
    internal func aFolderMoveBetweenVolumesCopiesInParallelAndRemovesTheSources() throws {
        let (a, b) = (try scratch(volume("AFM_VOLUME_A")), try scratch(volume("AFM_VOLUME_B")))
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let (tree, files) = try makeTree(in: a)
        let probe = LocalProbe()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(probe)
        let replies = Replies()
        let job = FileJob(kind: .move, sources: [tree], target: TargetSpec(directory: b), fileSystems: fileSystems)
        job.delegate = replies
        let result = withExtendedLifetime(replies) { job.run() }

        #expect(!result.cancelled && result.completed == [tree] && result.failureCount == 0)
        for (path, content) in files { #expect(text(b.appendingPathComponent("tree/" + path)) == content, "\(path)") }
        #expect(!exists(tree), "the source folder is gone")
        #expect(probe.totalCopies == files.count)
        #expect(probe.mostCopiesAtOnce > 1, "small files went to the pool")
        #expect(!namesOnDisk(b.appendingPathComponent("tree")).contains { $0.hasPrefix(".afm-") })
    }

    @Test
    internal func aRetryAfterAFailedSourceDeleteDoesNotCopyTheFileAgain() throws {
        let (a, b) = (try scratch(volume("AFM_VOLUME_A")), try scratch(volume("AFM_VOLUME_B")))
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let (tree, files) = try makeTree(in: a)
        let probe = LocalProbe()
        probe.failsOnce = ["f7.txt"]
        let fileSystems = FileSystemRegistry()
        fileSystems.register(probe)
        let retry = RetryOnce()
        let job = FileJob(kind: .move, sources: [tree], target: TargetSpec(directory: b), fileSystems: fileSystems)
        job.delegate = retry
        let result = withExtendedLifetime(retry) { job.run() }

        #expect(probe.failedRemovals == 1 && retry.errors.count == 1)
        #expect(probe.copies(of: "f7.txt") == 1, "the Retry removed the source, it did not copy again")
        #expect(result.completed == [tree] && !exists(tree))
        for (path, content) in files { #expect(text(b.appendingPathComponent("tree/" + path)) == content, "\(path)") }
    }

    // MARK: (b) Letter case on a case-sensitive volume

    @MainActor
    @Test
    internal func renamingToAnotherCaseNeverReplacesTheFileThatHasThatName() throws {
        let cs = try scratch(volume("AFM_VOLUME_CS"))
        defer { try? FileManager.default.removeItem(at: cs) }
        try write("lower", to: cs.appendingPathComponent("readme"))
        try write("UPPER", to: cs.appendingPathComponent("README"))
        try write("solo", to: cs.appendingPathComponent("solo"))
        let bench = TestBench(plugins: [FileOperationsPlugin()], fileSystems: [LocalFileSystem()], left: cs, right: cs)

        bench.left.moveCursor(toName: "readme")
        bench.commands.perform(.renameOnly, .text("README"))
        #expect(text(cs.appendingPathComponent("readme")) == "lower")
        #expect(text(cs.appendingPathComponent("README")) == "UPPER")
        #expect(
            bench.interaction.log.contains { $0.hasPrefix("inform: readme cannot be renamed!") },
            "\(bench.interaction.log)"
        )

        // Nothing else has the name: a rename that only changes the case is just a rename.
        bench.left.moveCursor(toName: "solo")
        bench.commands.perform(.renameOnly, .text("SOLO"))
        let names = namesOnDisk(cs)
        #expect(names.contains("SOLO") && !names.contains("solo"))
        #expect(text(cs.appendingPathComponent("SOLO")) == "solo")
    }

    @Test
    internal func aMoveOntoAnotherCaseAsksAboutTheCollisionAndKeepsBothFiles() throws {
        let cs = try scratch(volume("AFM_VOLUME_CS"))
        defer { try? FileManager.default.removeItem(at: cs) }
        let readme = cs.appendingPathComponent("readme")
        try write("lower", to: readme)
        try write("UPPER", to: cs.appendingPathComponent("README"))
        let replies = Replies(.skip)
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        let result = runJob(
            .move,
            [readme],
            to: TargetSpec(directory: cs, exactName: "README"),
            replies: replies,
            fileSystems: fileSystems
        )
        #expect(replies.conflicts == ["README"])
        #expect(result.completed.isEmpty)
        #expect(text(readme) == "lower" && text(cs.appendingPathComponent("README")) == "UPPER")
    }

    // MARK: (c) Copying into oneself through another spelling

    @Test
    internal func aCopyIntoItsOwnSubfolderThroughAnotherSpellingIsRefused() throws {
        let a = try scratch(volume("AFM_VOLUME_A"))
        defer { try? FileManager.default.removeItem(at: a) }
        try write("in", to: a.appendingPathComponent("Tree/Sub/file.txt"))
        let tree = a.appendingPathComponent("Tree")
        let spelled = a.appendingPathComponent("TREE/sUB", isDirectory: true)
        #expect(exists(spelled), "the volume folds letter case")
        let replies = Replies()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        let result = runJob(
            .copy,
            [tree],
            to: TargetSpec(directory: spelled),
            replies: replies,
            fileSystems: fileSystems
        )
        #expect(result.completed.isEmpty)
        #expect(replies.errors.count == 1 && replies.errors[0].contains("own subfolders"), "\(replies.errors)")
        #expect(namesOnDisk(a.appendingPathComponent("Tree/Sub")) == ["file.txt"])
    }
}
