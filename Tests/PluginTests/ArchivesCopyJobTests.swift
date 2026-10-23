import AFMKernel
import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The copy job and many threads at once on the archive file systems, and a cancelled pack.
@Suite
internal struct ArchivesCopyJobTests {
    /// The archive file systems in a sandbox of their own.
    internal let bench: ArchiveBench
    /// The sandbox the archives and trees are made in.
    internal var box: Sandbox { bench.box }

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// The copy job copies out of an archive and into it, moves and deletes inside it, and copies between two.
    @Test
    internal func theCopyJobStreamsOutOfAndIntoArchives() throws {
        let archive = try bench.zipOfTree("tree.zip")
        let tree = bench.inside(archive, "tree", scheme: ArchiveURL.writableScheme)
        try copyOut(of: tree)
        try copyIn(to: tree, archive: archive)
        try moveDeleteAndCopyAcross(in: tree, archive: archive)
    }

    // MARK: Many threads

    /// Readers, listers and writers on many threads at once leave a sound ZIP with every change in it.
    @Test
    internal func manyThreadsUseTheProviderAtOnce() throws {
        let archive = try bench.zipOfTree("tree.zip")
        let tree = bench.inside(archive, "tree", scheme: ArchiveURL.writableScheme)
        try bench.pack([box.url("tree")], to: box.url("tree.tar.bz2"), innerFolder: "") { options in
            options.format = .compressedTar(.bzip2)
        }
        let inTar = bench.inside(box.url("tree.tar.bz2"), "tree", scheme: ArchiveURL.readOnlyScheme)
        let expected = try Data(contentsOf: box.url("tree/big.log"))
        let failures = SharedCounter()
        // Readers, listers and writers on every core, on a ZIP that is being changed and on an
        // archive that is opened by all of them at the same moment.
        DispatchQueue.concurrentPerform(iterations: 48) { index in
            let fine = try? work(index, tree: tree, inTar: inTar, archive: archive, expected: expected)
            if fine != true { failures.add(1) }
        }
        #expect(failures.value == 0)
        #expect(bench.store.flushAll(cancellation: nil).isEmpty)
        let names = try bench.names(tree.appending(name: "sub"), showHidden: true)
        #expect(names.count { $0.hasPrefix("t") } == 8)
        #expect(try bench.names(tree, showHidden: true).count { $0.hasPrefix("moved") } == 8)
        #expect(runTool("/usr/bin/unzip", ["-tq", archive.path], in: nil).status == 0)
    }

    /// A cancelled pack stops before it writes anything and leaves no file behind.
    @Test
    internal func cancellingStopsPackingAndLeavesNothingBehind() throws {
        let tree = try bench.makeTree("tree")
        bench.monitor.cancellation.cancel()
        var options = PackOptions()
        options.format = .compressedTar(.gzip)
        let packer = Packer(
            fileSystems: bench.fileSystems,
            store: bench.store,
            monitor: bench.monitor,
            options: options
        )
        let result = packer.run([try bench.item(tree)], archive: box.url("out/cancelled.tgz"), innerFolder: "")
        #expect(result.cancelled && result.archives.isEmpty && result.failure == nil)
        #expect(namesOnDisk(box.url("out")).isEmpty)
    }

    /// One thread's work, by its index: read, list, write, make and move, read the tar, or flush; true when all
    /// it saw was right.
    private func work(_ index: Int, tree: URL, inTar: URL, archive: URL, expected: Data) throws -> Bool {
        switch index % 6 {
        case 0:
            return try bench.read(tree.appending(name: "big.log")) == expected

        case 1:
            return try bench.zip.list(tree, showHidden: true).count >= 5
                && bench.zip.item(at: tree.appending(name: "readme.txt"))?.size == 17_600

        case 2:
            try bench.writeText(
                "thread \(index)",
                to: tree.appending(name: "sub").appending(name: "t\(index).txt"),
                modified: nil
            )
            return true

        case 3:
            try bench.zip.createDirectory(at: tree.appending(name: "made\(index)"))
            try bench.zip.move(
                tree.appending(name: "made\(index)"),
                to: tree.appending(name: "moved\(index)"),
                replacing: false
            )
            return true

        case 4:
            return try bench.read(inTar.appending(name: "big.log")) == expected
                && bench.readOnly.list(inTar, showHidden: true).count == 5

        default:
            try bench.store.flush(archive, cancellation: nil)
            return bench.zip.parent(of: tree) == bench.inside(archive, "", scheme: ArchiveURL.writableScheme)
        }
    }

    /// Copies a folder and a file out of the archive onto the disk, with their dates.
    private func copyOut(of tree: URL) throws {
        // Out: a folder with everything in it, onto the disk.
        try box.folder("out")
        let result = runJob(
            .copy,
            [tree.appending(name: "sub"), tree.appending(name: "readme.txt")],
            to: TargetSpec(directory: box.url("out")),
            fileSystems: bench.fileSystems
        )
        #expect(result.completed.count == 2 && !result.cancelled)
        #expect(snapshot(box.url("out/sub")) == snapshot(box.url("tree/sub")))
        #expect(try Data(contentsOf: box.url("out/readme.txt")) == Data(contentsOf: box.url("tree/readme.txt")))
        let date =
            try FileManager.default.attributesOfItem(atPath: box.url("out/readme.txt").path)[.modificationDate] as? Date
        #expect(abs((date ?? .distantPast).timeIntervalSince(Date(timeIntervalSince1970: 1_600_000_000))) < 2)
    }

    /// Copies a tree from the disk into a folder of the archive, replacing an existing member, in one rewrite.
    private func copyIn(to tree: URL, archive: URL) throws {
        // In: a tree from the disk into a folder of the archive; an existing member is replaced.
        try box.file("in/alpha.txt", "alpha")
        try box.file("in/more/beta.txt", String(repeating: "beta ", count: 50_000))
        try box.file("in/readme.txt", "replaced")
        let answers = Answers()
        let result = runJob(
            .copy,
            [box.url("in/alpha.txt"), box.url("in/more"), box.url("in/readme.txt")],
            to: TargetSpec(directory: tree),
            answers: answers,
            fileSystems: bench.fileSystems
        )
        #expect(result.completed.count == 3 && answers.conflicts == ["readme.txt"] && answers.errors.isEmpty)
        // One rewrite of the archive for the whole job, however many files it brought.
        #expect(bench.store.flushAll(cancellation: nil).isEmpty)
        #expect(
            try bench.names(tree, showHidden: true) == [
                "alpha.txt", "big.log", "empty.txt", "hollow", "more", "readme.txt", "sub"
            ]
        )
        #expect(runTool("/usr/bin/unzip", ["-tq", archive.path], in: nil).status == 0)
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/readme.txt"], in: nil).output == "replaced")
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/more/beta.txt"], in: nil).output.count == 250_000)
    }

    /// Moves inside the archive (a rename), deletes with the tree walked, and copies into another archive.
    private func moveDeleteAndCopyAcross(in tree: URL, archive: URL) throws {
        // Move inside the archive is a rename; delete walks the tree.
        var result = runJob(
            .move,
            [tree.appending(name: "more")],
            to: TargetSpec(directory: tree.appending(name: "hollow")),
            fileSystems: bench.fileSystems
        )
        #expect(
            try result.completed.count == 1
                && bench.names(tree.appending(name: "hollow").appending(name: "more"), showHidden: true) == ["beta.txt"]
        )
        result = runJob(
            .delete(toTrash: false),
            [tree.appending(name: "hollow"), tree.appending(name: "big.log")],
            fileSystems: bench.fileSystems
        )
        #expect(result.completed.count == 2)
        // From one archive into another.
        try bench.pack([box.url("in/alpha.txt")], to: box.url("second.zip"), innerFolder: "") { $0.format = .zip }
        result = runJob(
            .copy,
            [tree.appending(name: "sub")],
            to: TargetSpec(directory: bench.inside(box.url("second.zip"), "", scheme: ArchiveURL.writableScheme)),
            fileSystems: bench.fileSystems
        )
        #expect(result.completed.count == 1 && bench.store.flushAll(cancellation: nil).isEmpty)
        let listed = runTool("/usr/bin/unzip", ["-Z1", box.url("second.zip").path], in: nil).output
            .split(separator: "\n")
            .map(String.init)
            .sorted()
        // (The system's unzip garbles the Unicode name when it lists; the name itself is checked above.)
        #expect(
            listed.count == 6
                && Set(listed).isSuperset(of: ["alpha.txt", "sub/", "sub/.hidden", "sub/deep/", "sub/random.bin"])
        )
        #expect(
            try bench.names(
                bench.inside(box.url("second.zip"), "sub/deep", scheme: ArchiveURL.writableScheme),
                showHidden: true
            ) == ["übung – ñ 日本.txt"]
        )
        #expect(try bench.names(tree, showHidden: true) == ["alpha.txt", "empty.txt", "readme.txt", "sub"])
        #expect(
            runTool("/usr/bin/unzip", ["-tq", archive.path], in: nil).status == 0
                && runTool("/usr/bin/unzip", ["-tq", box.url("second.zip").path], in: nil).status == 0
        )
    }
}
