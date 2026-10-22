import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import ArchivesPlugin
@testable import FileOperationsPlugin
@testable import ViewerPlugin
@testable import VirtualFoldersPlugin

// What several plugins do together, with the real providers: the archives and the file jobs,
// the quarantine mark across file systems, a job cancelled through a virtual folder.

private func isSound(_ archive: URL) -> Bool {
    runTool("/usr/bin/unzip", ["-tq", archive.path]).status == 0
}

private func members(of archive: URL) -> [String] {
    runTool("/usr/bin/unzip", ["-Z1", archive.path]).output.split(separator: "\n").map(String.init)
}

private func mark(_ url: URL, with value: String) {
    #expect(value.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0) } == 0)
}

private func markOf(_ url: URL) -> String? {
    let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
    guard size > 0 else {
        return nil
    }
    var value = [UInt8](repeating: 0, count: size)
    let got = getxattr(url.path, "com.apple.quarantine", &value, size, 0, XATTR_NOFOLLOW)
    return got > 0 ? String(decoding: value.prefix(got), as: UTF8.self) : nil
}

/// Runs the job on a thread of its own and gives up waiting only after `Wait.ceiling`.
private func runInBackground(_ job: FileJob) -> JobResult? {
    let finished = DispatchSemaphore(value: 0)
    let result = SharedBox<JobResult?>(nil)
    Thread {
        result.value = job.run()
        finished.signal()
    }
    .start()
    return finished.wait(timeout: .now() + Wait.ceiling) == .success ? result.value : nil
}

/// A value written by one thread and read by another after a semaphore ordered the two.
private final class SharedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    init(_ value: Value) { stored = value }
}

/// Cancels the job from a thread of its own once `gate` is signalled (or after `Wait.ceiling`).
private func cancel(_ job: FileJob, when gate: DispatchSemaphore) {
    Thread {
        _ = gate.wait(timeout: .now() + Wait.ceiling)
        job.cancel()
    }
    .start()
}

/// Answers every question with going on, and tells a test what the job is working on.
private final class BreakingAnswers: FileJobDelegate {
    var onLines: (([String]) -> Void)?
    private(set) var errors: [String] = []

    func job(_: FileJob, progress: JobProgress) { onLines?(progress.lines) }
    func job(_: FileJob, conflictAt _: FileItem, source _: FileItem) -> ConflictChoice { .overwrite }
    func job(_: FileJob, failedAt _: URL, error: any Error) -> ErrorChoice {
        errors.append(error.localizedDescription)
        return .skip
    }
    func job(_: FileJob, confirmDeleteNonEmpty _: URL) -> FolderDeleteChoice { .delete }
}

@Suite
internal struct ArchiveJobsEndToEnd {
    internal let bench: ArchiveBench
    internal var box: Sandbox { bench.box }

    internal init() throws {
        bench = try ArchiveBench()
    }

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

    @Test
    internal func aMoveOfSmallAndLargeFilesPutsThemInTheArchiveFileOnceAndRemovesTheSources() throws {
        let archive = try makeZip()
        let sources = try makeSources([
            "a.txt": 20, "b.txt": 3_000, "big1.txt": 300_000, "big2.txt": 700_000, "c.txt": 7
        ])
        let wanted = try Dictionary(
            uniqueKeysWithValues: sources.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
        )
        let result = runJob(
            .move,
            sources,
            to: TargetSpec(directory: bench.inside(archive, "tree")),
            fileSystems: bench.fileSystems
        )
        #expect(result.completed.count == 5 && !result.cancelled && result.failureCount == 0)
        #expect(sources.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        // Written before the sources went: nothing waits in memory any more.
        #expect(try !bench.store.archive(at: archive).hasPendingChanges)
        #expect(isSound(archive))
        let listed = members(of: archive)
        // Every member once, none of them under the temporary name it was written with.
        #expect(Set(listed).count == listed.count)
        #expect(listed.filter { $0.contains(".afm-") || $0.hasSuffix(".tmp") }.isEmpty)
        #expect(Set(listed).isSuperset(of: wanted.keys.map { "tree/" + $0 }))
        for (name, text) in wanted {
            #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/" + name]).output == text, "\(name)")
        }
        #expect(namesOnDisk(box.root).filter { $0.hasSuffix(".tmp") || $0.hasPrefix(".afm-") }.isEmpty)
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
            answers.onLines = { if $0.contains(where: { $0.hasSuffix("big3.txt") }) { setFolder(locked) } }
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

    @Test
    internal func aCopyOutOfAnArchiveCarriesTheArchivesQuarantineMark() throws {
        try box.file("tree/sub/deep/inner.txt", "inner")
        let archive = try makeZip()
        let value = "0083;5e8b1c2d;Safari;"
        mark(archive, with: value)
        let out = try box.folder("out")
        let result = runJob(
            .copy,
            [bench.inside(archive, "tree/readme.txt"), bench.inside(archive, "tree/sub")],
            to: TargetSpec(directory: out),
            fileSystems: bench.fileSystems
        )
        #expect(result.completed.count == 2 && result.failureCount == 0)
        #expect(markOf(out.appendingPathComponent("readme.txt")) == value)
        #expect(markOf(out.appendingPathComponent("sub/deep/inner.txt")) == value)
    }

    @Test
    internal func aCopyFromOneFolderOfTheDiskToAnotherIsNotMarked() throws {
        // The folder of the source is marked, as a folder that was downloaded is; its files are not.
        try box.file("plain/x.txt", "x")
        mark(box.url("plain"), with: "0083;5e8b1c2d;Safari;")
        let out = try box.folder("out")
        let result = runJob(
            .copy,
            [box.url("plain/x.txt")],
            to: TargetSpec(directory: out),
            fileSystems: bench.fileSystems
        )
        #expect(result.completed.count == 1 && box.read("out/x.txt") == "x")
        #expect(markOf(out.appendingPathComponent("x.txt")) == nil)
    }
}

/// A job that reads or writes through a virtual folder, with a server that stops answering.
@Suite
internal struct JobsThroughVirtualFolders {
    internal let memory = MemoryFileSystem()
    internal let probe: ProbeFileSystem
    internal let registry = FileSystemRegistry()
    internal let virtual: VirtualFileSystem

    internal init() {
        probe = ProbeFileSystem(memory)
        registry.register(LocalFileSystem())
        registry.register(probe)
        virtual = VirtualFileSystem(fileSystems: registry)
        registry.register(virtual)
    }

    @Test
    internal func cancelEndsAReadOfAFileNamedThroughABranchViewAtOnce() throws {
        let box = try Sandbox()
        memory.stallsReads = true
        let gate = DispatchSemaphore(value: 0)
        probe.onRead = { gate.signal() }
        memory.addFile("/A/big.bin", "some data")
        let out = try box.folder("out")
        let source = virtual.branch(of: memory.url("/A/big.bin"))
        let job = FileJob(kind: .copy, sources: [source], target: TargetSpec(directory: out), fileSystems: registry)
        let answers = Answers()
        job.delegate = answers
        cancel(job, when: gate)
        let result = withExtendedLifetime(answers) { runInBackground(job) }
        #expect(result?.cancelled == true)
        #expect(memory.interruptions >= 1)
        #expect(namesOnDisk(out).isEmpty)
    }

    @Test
    internal func cancelEndsAWriteIntoABranchViewAtOnce() throws {
        let box = try Sandbox()
        memory.stallsWrites = true
        let gate = DispatchSemaphore(value: 0)
        probe.onWrite = { gate.signal() }
        memory.addDirectory("/A")
        let source = try box.file("in/data.bin", "some data")
        let job = FileJob(
            kind: .copy,
            sources: [source],
            target: TargetSpec(directory: virtual.branch(of: memory.url("/A"))),
            fileSystems: registry
        )
        let answers = Answers()
        job.delegate = answers
        cancel(job, when: gate)
        let result = withExtendedLifetime(answers) { runInBackground(job) }
        #expect(result?.cancelled == true)
        #expect(memory.interruptions >= 1)
        #expect(memory.allPaths == ["/A"])
    }

    @Test
    internal func cancelEndsTheListingOfABranchViewThatWaits() {
        memory.stallsListings = true
        let gate = DispatchSemaphore(value: 0)
        probe.onList = { gate.signal() }
        memory.addFile("/A/sub/f.txt")
        let flag = CancellationFlag()
        let branch = virtual.branch(of: memory.url("/A"))
        let finished = DispatchSemaphore(value: 0)
        Thread {
            _ = try? virtual.list(branch, showHidden: false, cancellation: flag)
            finished.signal()
        }
        .start()
        Thread {
            _ = gate.wait(timeout: .now() + Wait.ceiling)
            flag.cancel()
        }
        .start()
        #expect(finished.wait(timeout: .now() + Wait.ceiling) == .success)
    }
}

/// A branch view that names two files by their paths: the names of what a job processed are
/// found by location.
@MainActor
@Suite
internal struct NamesInBranchViews {
    @Test
    internal func processedItemsAreFoundByLocationWhereNamesArePaths() throws {
        let registry = FileSystemRegistry()
        let memory = MemoryFileSystem()
        registry.register(memory)
        let virtual = VirtualFileSystem(fileSystems: registry)
        registry.register(virtual)
        memory.addFile("/A/x/same.txt")
        memory.addFile("/A/y/same.txt")
        memory.addFile("/A/other.txt")
        let picked = virtual.registerPicked(
            [memory.url("/A/x/same.txt"), memory.url("/A/y/same.txt"), memory.url("/A/other.txt")],
            in: memory.url("/A")
        )
        let items = try virtual.list(picked, showHidden: false)
        let (first, second) = (
            try #require(items.first { $0.url.path == "/A/x/same.txt" }),
            try #require(items.first { $0.url.path == "/A/y/same.txt" })
        )
        #expect(first.name != "same.txt" && second.name != "same.txt" && first.name != second.name)
        let names = FileOperations.names(of: [memory.url("/A/y/same.txt"), memory.url("/A/other.txt")], among: items)
        #expect(Set(names) == [second.name, "other.txt"])
    }
}

/// The viewer reads a file that a branch view names, from a server that stops answering.
@Suite
internal struct ViewerThroughVirtualFolders {
    @Test
    internal func aBlockedReadEndsWhenItsFlagIsSet() throws {
        let memory = MemoryFileSystem()
        let probe = ProbeFileSystem(memory)
        let registry = FileSystemRegistry()
        registry.register(probe)
        let virtual = VirtualFileSystem(fileSystems: registry)
        registry.register(virtual)
        memory.addFile("/far/big.txt", String(repeating: "line of text\n", count: 8_000))
        let gate = DispatchSemaphore(value: 0)
        probe.onRead = { gate.signal() }
        let source = try ProviderByteSource.open(virtual.branch(of: memory.url("/far/big.txt")), fileSystems: registry)
        memory.stallsReads = true
        let flag = CancellationFlag()
        let outcome = SharedBox<Result<Data, any Error>?>(nil)
        let finished = DispatchSemaphore(value: 0)
        Thread {
            outcome.value = Result { try source.read(at: 10, count: 5_000, cancellation: flag) }
            finished.signal()
        }
        .start()
        Thread {
            _ = gate.wait(timeout: .now() + Wait.ceiling)
            flag.cancel()
        }
        .start()
        #expect(finished.wait(timeout: .now() + Wait.ceiling) == .success)
        if case .success? = outcome.value { Issue.record("The read was not ended") }
        #expect(memory.interruptions >= 1)
        // The source is usable again afterwards, with another flag.
        memory.stallsReads = false
        #expect(try source.read(at: 0, count: 13, cancellation: CancellationFlag()) == Data("line of text\n".utf8))
    }
}
