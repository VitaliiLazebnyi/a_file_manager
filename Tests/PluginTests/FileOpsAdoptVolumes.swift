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

/// The environment the test process was started with.
private let kEnvironment = ProcessInfo.processInfo.environment
/// Whether the three volumes were given and the tests are asked for.
private let kVolumesAreMounted =
    kEnvironment["AFM_VOLUME_TESTS"] == "1" && kEnvironment["AFM_VOLUME_A"] != nil
    && kEnvironment["AFM_VOLUME_B"] != nil && kEnvironment["AFM_VOLUME_CS"] != nil

/// The mount point named by the environment variable `key`.
private func volume(_ key: String) -> URL {
    URL(fileURLWithPath: kEnvironment[key] ?? "/nonexistent", isDirectory: true).resolvingSymlinksInPath()
}

/// A new empty folder of its own on the volume.
private func scratch(_ volume: URL) throws -> URL {
    let folder = volume.appendingPathComponent("test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Writes the text to the file, making the folders above it.
private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

/// The file's text; nil when it cannot be read.
private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

/// Whether anything is at `url`.
private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// Whether names that differ in letter case are one entry on the volume that holds `folder`.
private func foldsCase(in folder: URL) throws -> Bool {
    try write("probe", to: folder.appendingPathComponent("Probe-File"))
    defer { try? FileManager.default.removeItem(at: folder.appendingPathComponent("Probe-File")) }
    return exists(folder.appendingPathComponent("probe-file"))
}

/// The job code on real volumes: moves between two of them, letter case, and other spellings of a folder.
@Suite(
    .enabled(
        if: kVolumesAreMounted,
        "needs mounted disk images: set AFM_VOLUME_TESTS=1, AFM_VOLUME_A, AFM_VOLUME_B, AFM_VOLUME_CS"
    )
)
internal struct FileOpsAdoptVolumes {
    /// The given volumes are what the tests need: A and B apart, A folding letter case, CS not.
    @Test
    internal func theThreeVolumesAreTheKindsTheseTestsNeed() throws {
        let (volumeA, volumeB, caseSensitive) = (
            volume("AFM_VOLUME_A"), volume("AFM_VOLUME_B"), volume("AFM_VOLUME_CS")
        )
        #expect(FileIdentity.device(of: volumeA) != FileIdentity.device(of: volumeB))
        #expect(FileIdentity.device(of: volumeA) != FileIdentity.device(of: caseSensitive))
        let (folderA, folderCS) = (try scratch(volumeA), try scratch(caseSensitive))
        defer {
            try? FileManager.default.removeItem(at: folderA)
            try? FileManager.default.removeItem(at: folderCS)
        }
        #expect(try foldsCase(in: folderA))
        #expect(try !foldsCase(in: folderCS))
    }

    // MARK: (a) A folder move between two volumes

    /// A tree of 40 files and three subfolders of 5 files each, and the text of every file by path.
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

    /// A folder moved between volumes is copied file by file in parallel, then its sources go.
    @Test
    internal func aFolderMoveBetweenVolumesCopiesInParallelAndRemovesTheSources() throws {
        let (folderA, folderB) = (try scratch(volume("AFM_VOLUME_A")), try scratch(volume("AFM_VOLUME_B")))
        defer {
            try? FileManager.default.removeItem(at: folderA)
            try? FileManager.default.removeItem(at: folderB)
        }
        let (tree, files) = try makeTree(in: folderA)
        let probe = LocalProbe()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(probe)
        let replies = Replies()
        let job = FileJob(
            kind: .move,
            sources: [tree],
            target: TargetSpec(directory: folderB),
            fileSystems: fileSystems
        )
        job.delegate = replies
        let result = withExtendedLifetime(replies) { job.run() }

        #expect(!result.cancelled && result.completed == [tree] && result.failureCount == 0)
        for (path, content) in files {
            #expect(text(folderB.appendingPathComponent("tree/" + path)) == content, "\(path)")
        }
        #expect(!exists(tree), "the source folder is gone")
        #expect(probe.totalCopies == files.count)
        #expect(probe.mostCopiesAtOnce > 1, "small files went to the pool")
        #expect(!namesOnDisk(folderB.appendingPathComponent("tree")).contains { $0.hasPrefix(".afm-") })
    }

    /// Retry after a source that could not be removed removes it again without copying it twice.
    @Test
    internal func aRetryAfterAFailedSourceDeleteDoesNotCopyTheFileAgain() throws {
        let (folderA, folderB) = (try scratch(volume("AFM_VOLUME_A")), try scratch(volume("AFM_VOLUME_B")))
        defer {
            try? FileManager.default.removeItem(at: folderA)
            try? FileManager.default.removeItem(at: folderB)
        }
        let (tree, files) = try makeTree(in: folderA)
        let probe = LocalProbe()
        probe.failsOnce = ["f7.txt"]
        let fileSystems = FileSystemRegistry()
        fileSystems.register(probe)
        let retry = RetryOnce()
        let job = FileJob(
            kind: .move,
            sources: [tree],
            target: TargetSpec(directory: folderB),
            fileSystems: fileSystems
        )
        job.delegate = retry
        let result = withExtendedLifetime(retry) { job.run() }

        #expect(probe.failedRemovals == 1 && retry.errors.count == 1)
        #expect(probe.copies(of: "f7.txt") == 1, "the Retry removed the source, it did not copy again")
        #expect(result.completed == [tree] && !exists(tree))
        for (path, content) in files {
            #expect(text(folderB.appendingPathComponent("tree/" + path)) == content, "\(path)")
        }
    }

    // MARK: (b) Letter case on a case-sensitive volume

    /// On a case-sensitive volume a rename to another case never replaces the file of that name.
    @MainActor
    @Test
    internal func renamingToAnotherCaseNeverReplacesTheFileThatHasThatName() throws {
        let folderCS = try scratch(volume("AFM_VOLUME_CS"))
        defer { try? FileManager.default.removeItem(at: folderCS) }
        try write("lower", to: folderCS.appendingPathComponent("readme"))
        try write("UPPER", to: folderCS.appendingPathComponent("README"))
        try write("solo", to: folderCS.appendingPathComponent("solo"))
        let bench = TestBench(
            plugins: [FileOperationsPlugin()],
            fileSystems: [LocalFileSystem()],
            left: folderCS,
            right: folderCS
        )

        bench.left.moveCursor(toName: "readme")
        bench.commands.perform(.renameOnly, .text("README"))
        #expect(text(folderCS.appendingPathComponent("readme")) == "lower")
        #expect(text(folderCS.appendingPathComponent("README")) == "UPPER")
        #expect(
            bench.interaction.log.contains { $0.hasPrefix("inform: readme cannot be renamed!") },
            "\(bench.interaction.log)"
        )

        // Nothing else has the name: a rename that only changes the case is just a rename.
        bench.left.moveCursor(toName: "solo")
        bench.commands.perform(.renameOnly, .text("SOLO"))
        let names = namesOnDisk(folderCS)
        #expect(names.contains("SOLO") && !names.contains("solo"))
        #expect(text(folderCS.appendingPathComponent("SOLO")) == "solo")
    }

    /// A move onto a name that differs only in case asks about it and keeps both files.
    @Test
    internal func aMoveOntoAnotherCaseAsksAboutTheCollisionAndKeepsBothFiles() throws {
        let folderCS = try scratch(volume("AFM_VOLUME_CS"))
        defer { try? FileManager.default.removeItem(at: folderCS) }
        let readme = folderCS.appendingPathComponent("readme")
        try write("lower", to: readme)
        try write("UPPER", to: folderCS.appendingPathComponent("README"))
        let replies = Replies(.skip)
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        let result = replies.run(
            .move,
            [readme],
            to: TargetSpec(directory: folderCS, exactName: "README"),
            fileSystems: fileSystems,
            configure: nil
        )
        #expect(replies.conflicts == ["README"])
        #expect(result.completed.isEmpty)
        #expect(text(readme) == "lower" && text(folderCS.appendingPathComponent("README")) == "UPPER")
    }

    // MARK: (c) Copying into oneself through another spelling

    /// A copy into its own subfolder spelled in another case is refused.
    @Test
    internal func aCopyIntoItsOwnSubfolderThroughAnotherSpellingIsRefused() throws {
        let folderA = try scratch(volume("AFM_VOLUME_A"))
        defer { try? FileManager.default.removeItem(at: folderA) }
        try write("in", to: folderA.appendingPathComponent("Tree/Sub/file.txt"))
        let tree = folderA.appendingPathComponent("Tree")
        let spelled = folderA.appendingPathComponent("TREE/sUB", isDirectory: true)
        #expect(exists(spelled), "the volume folds letter case")
        let replies = Replies()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        let result = replies.run(
            .copy,
            [tree],
            to: TargetSpec(directory: spelled),
            fileSystems: fileSystems,
            configure: nil
        )
        #expect(result.completed.isEmpty)
        #expect(replies.errors.count == 1 && replies.errors[0].contains("own subfolders"), "\(replies.errors)")
        #expect(namesOnDisk(folderA.appendingPathComponent("Tree/Sub")) == ["file.txt"])
    }
}
