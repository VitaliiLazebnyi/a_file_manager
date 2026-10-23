import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import ArchivesPlugin
@testable import FileOperationsPlugin

// What several plugins do together, with the real providers: the archives and the file jobs,
// and the quarantine mark across file systems.

/// Whether `unzip` finds the archive sound.
private func isSound(_ archive: URL) -> Bool {
    runTool("/usr/bin/unzip", ["-tq", archive.path]).status == 0
}

/// The paths of the archive's members, as `unzip` lists them.
private func members(of archive: URL) -> [String] {
    runTool("/usr/bin/unzip", ["-Z1", archive.path]).output.split(separator: "\n").map(String.init)
}

/// Gives the file the quarantine mark `value`, as a browser does to what it downloads.
private func mark(_ url: URL, with value: String) {
    #expect(value.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0) } == 0)
}

/// The file's quarantine mark, or nil when it has none.
private func markOf(_ url: URL) -> String? {
    let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
    guard size > 0 else {
        return nil
    }
    var value = [UInt8](repeating: 0, count: size)
    let got = getxattr(url.path, "com.apple.quarantine", &value, size, 0, XATTR_NOFOLLOW)
    return got > 0 ? String(bytes: value.prefix(got), encoding: .utf8) : nil
}

/// File jobs into and out of a real zip archive, on the disk.
@Suite
internal struct ArchiveJobsEndToEnd {
    /// Answers every question with going on, and tells a test what the job is working on.
    internal final class BreakingAnswers: FileJobDelegate {
        /// Called with the lines of every progress report.
        internal var onLines: (([String]) -> Void)?
        /// The texts of the errors the job reported, in that order.
        internal private(set) var errors: [String] = []

        /// Passes the report's lines to `onLines`.
        internal func job(_: FileJob, progress: JobProgress) { onLines?(progress.lines) }

        /// Overwrites every target that is there.
        internal func job(_: FileJob, conflictAt _: FileItem, source _: FileItem) -> ConflictChoice { .overwrite }

        /// Notes the error's text and skips the item.
        internal func job(_: FileJob, failedAt _: URL, error: any Error) -> ErrorChoice {
            errors.append(error.localizedDescription)
            return .skip
        }

        /// Deletes every folder with its contents.
        internal func job(_: FileJob, confirmDeleteNonEmpty _: URL) -> FolderDeleteChoice { .delete }

        deinit {
            // Nothing to release.
        }
    }

    /// The archive store and file systems the jobs run with, in a sandbox of the test's own.
    internal let bench: ArchiveBench
    /// The sandbox on disk.
    internal var box: Sandbox { bench.box }

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// Zips `tree/` (a file `readme.txt` and an empty folder `sub`, plus what the test put there)
    /// into `tree.zip` with the system's `zip`.
    internal func makeZip() throws -> URL {
        try box.file("tree/readme.txt", "readme")
        try box.folder("tree/sub")
        #expect(runTool("/usr/bin/zip", ["-qr", "tree.zip", "tree"], in: box.root).status == 0)
        return box.url("tree.zip")
    }

    /// Files of the given sizes in `in/`, each of its own text.
    internal func makeSources(_ sizes: [String: Int]) throws -> [URL] {
        try sizes.sorted { $0.key < $1.key }
            .map { name, size in
                try box.file("in/" + name, String(repeating: name + " ", count: size / (name.count + 1)))
            }
    }

    /// Moving small and large files into an archive puts each in once, under its own name, and
    /// removes the sources only after the archive file was written.
    @Test
    internal func aMoveOfSmallAndLargeFilesPutsThemInTheArchiveFileOnceAndRemovesTheSources() throws {
        let archive = try makeZip()
        let sources = try makeSources([
            "a.txt": 20, "b.txt": 3_000, "big1.txt": 300_000, "big2.txt": 700_000, "c.txt": 7
        ])
        let wanted = try Dictionary(
            uniqueKeysWithValues: sources.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
        )
        let result = Answers()
            .run(
                .move,
                sources,
                to: TargetSpec(directory: bench.inside(archive, "tree")),
                fileSystems: bench.fileSystems
            )
        #expect(result.completed.count == 5 && !result.cancelled && result.failureCount == 0)
        #expect(sources.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        // Written before the sources went: nothing waits in memory any more.
        #expect(try !bench.store.archive(at: archive, cancellation: nil).hasPendingChanges)
        #expect(isSound(archive))
        let listed = members(of: archive)
        // Every member once, none of them under the temporary name it was written with.
        #expect(Set(listed).count == listed.count)
        #expect(!listed.contains { $0.contains(".afm-") || $0.hasSuffix(".tmp") })
        #expect(Set(listed).isSuperset(of: wanted.keys.map { "tree/" + $0 }))
        for (name, text) in wanted {
            #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/" + name]).output == text, "\(name)")
        }
        #expect(!namesOnDisk(box.root).contains { $0.hasSuffix(".tmp") || $0.hasPrefix(".afm-") })
    }

    /// With the quick write at each rename (the default) a file that cannot be written fails on its
    /// own.
    ///
    /// Without it the renames succeed and everything waits for the commit; the folder of the
    /// archive stops being writable when the last file is begun, so that file and the commit fail.
    @Test(arguments: [true, false])
    internal func aMoveKeepsEverySourceWhenTheArchiveCannotBeWritten(quickWrites: Bool) throws {
        if !quickWrites { bench.environment.immediateWriteLimit = 0 }
        let archive = try makeZip()
        let sources = try makeSources(["big1.txt": 300_000, "big2.txt": 700_000, "big3.txt": 400_000])
        let before = try Data(contentsOf: archive)
        let answers = BreakingAnswers()
        let (locked, open) = (FileAttributes(permissions: 0o555), FileAttributes(permissions: 0o755))
        func setFolder(_ attributes: FileAttributes) { try? LocalFileSystem().setAttributes(attributes, of: box.root) }
        if quickWrites {
            setFolder(locked)
        } else {
            answers.onLines = { lines in
                if lines.contains(where: { $0.hasSuffix("big3.txt") }) { setFolder(locked) }
            }
        }
        let job = FileJob(
            kind: .move,
            sources: sources,
            target: TargetSpec(directory: bench.inside(archive, "tree")),
            fileSystems: bench.fileSystems
        )
        job.delegate = answers
        // One file after the other, so that the folder is locked before the last one is begun and not before.
        job.parallelWidth = 1
        let result = job.run()
        setFolder(open)
        #expect(result.completed.isEmpty && result.failureCount >= 1)
        // At the commit the job ends, after the question about the last file and the one about the commit;
        // at the renames each file fails on its own.
        if !quickWrites { #expect(result.cancelled && answers.errors.count == 2) }
        for source in sources {
            #expect(FileManager.default.fileExists(atPath: source.path), "\(source.lastPathComponent)")
        }
        // The archive file was not touched.
        #expect(try Data(contentsOf: archive) == before && isSound(archive))
    }

    /// Files copied out of a marked archive, a folder's contents too, carry the archive's
    /// quarantine mark.
    @Test
    internal func aCopyOutOfAnArchiveCarriesTheArchivesQuarantineMark() throws {
        try box.file("tree/sub/deep/inner.txt", "inner")
        let archive = try makeZip()
        let value = "0083;5e8b1c2d;Safari;"
        mark(archive, with: value)
        let out = try box.folder("out")
        let result = Answers()
            .run(
                .copy,
                [bench.inside(archive, "tree/readme.txt"), bench.inside(archive, "tree/sub")],
                to: TargetSpec(directory: out),
                fileSystems: bench.fileSystems
            )
        #expect(result.completed.count == 2 && result.failureCount == 0)
        #expect(markOf(out.appendingPathComponent("readme.txt")) == value)
        #expect(markOf(out.appendingPathComponent("sub/deep/inner.txt")) == value)
    }

    /// A copy from one folder of the disk to another adds no mark, even when the source's folder
    /// has one.
    @Test
    internal func aCopyFromOneFolderOfTheDiskToAnotherIsNotMarked() throws {
        // The folder of the source is marked, as a folder that was downloaded is; its files are not.
        try box.file("plain/x.txt", "x")
        mark(box.url("plain"), with: "0083;5e8b1c2d;Safari;")
        let out = try box.folder("out")
        let result = Answers()
            .run(.copy, [box.url("plain/x.txt")], to: TargetSpec(directory: out), fileSystems: bench.fileSystems)
        #expect(result.completed.count == 1 && box.read("out/x.txt") == "x")
        #expect(markOf(out.appendingPathComponent("x.txt")) == nil)
    }
}
