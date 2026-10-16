import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// More arms of a file job: a deep tree in a move, a batch ended by a worker, ages kept, pipes, partial files that
/// changed, other volumes, deferred removals, the Trash refusing a lock, cancels while deleting, counts that are
/// cut short or not kept.
@Suite
internal struct CovFileOpsJobEdges {
    private let box: Sandbox
    private let memory = MemoryFileSystem()
    private let disk = CovFileOpsScriptedDisk()
    private let fileSystems = FileSystemRegistry()

    /// A sandbox and a registry with the disk, the memory file system and the scripted disk.
    internal init() throws {
        box = try Sandbox()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(memory)
        fileSystems.register(disk)
    }

    /// A move into a folder that exists goes into the tree, and stops where it is too deep.
    @Test
    internal func aMoveIntoAnExistingFolderStopsWhereItIsTooDeep() {
        memory.addFile("/A/one/two/f.txt", "deep")
        memory.addDirectory("/B/one")
        let job = FileJob(
            kind: .move,
            sources: [memory.url("/A/one")],
            target: TargetSpec(directory: memory.url("/B")),
            fileSystems: fileSystems
        )
        job.depthLimit = 1
        let answers = CovFileOpsAnswers()
        job.delegate = answers
        _ = job.run()
        #expect(answers.asked.value.contains { $0.contains("nested too deep") } && memory.exists("/A/one/two/f.txt"))
    }

    /// Aborted in a worker, a batch ends, also for a second file of the same name that waits for the first.
    @Test
    internal func anAbortInAWorkerEndsTheBatch() throws {
        let unreadable = try box.file("x/f.txt", "x")
        try box.file("y/f.txt", "y")
        try box.file("folder/a.txt", "a")
        let blocked = try box.file("folder/b.txt", "b")
        try box.folder("T")
        for file in [unreadable, blocked] {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        }
        defer {
            for file in [unreadable, blocked] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            }
        }
        let answers = CovFileOpsAnswers()
        answers.failures.value = [.abort]
        var job = FileJob(
            kind: .copy,
            sources: [box.url("x/f.txt"), box.url("y/f.txt")],
            target: TargetSpec(directory: box.url("T")),
            fileSystems: fileSystems
        )
        job.delegate = answers
        #expect(job.run().cancelled)
        job = FileJob(
            kind: .copy,
            sources: [box.url("folder")],
            target: TargetSpec(directory: box.url("U")),
            fileSystems: fileSystems
        )
        job.delegate = answers
        #expect(job.run().cancelled)
    }

    /// Of two files of one name, the older second one is not taken over the newer first one.
    @Test
    internal func anOlderSecondFileIsNotTakenOverTheFirst() {
        memory.addFile("/x/f.txt", "newer", modified: Date(timeIntervalSince1970: 9_000))
        memory.addFile("/y/f.txt", "older", modified: Date(timeIntervalSince1970: 1_000))
        let job = FileJob(
            kind: .copy,
            sources: [memory.url("/x/f.txt"), memory.url("/y/f.txt")],
            target: TargetSpec(directory: memory.url("/T")),
            fileSystems: fileSystems
        )
        job.options.overwrite = .renameOlderSkipNewer
        let answers = Answers()
        job.delegate = answers
        _ = withExtendedLifetime(answers) { job.run() }
        #expect(memory.contents("/T/f.txt") == "newer" && memory.allPaths.filter { $0.hasPrefix("/T/") }.count == 1)
    }

    /// A pipe is not copied, and nothing is appended from one.
    @Test
    internal func aPipeIsNotCopiedNorAppended() throws {
        let pipe = box.url("pipe")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        try box.file("T/pipe", "old")
        let answers = CovFileOpsAnswers()
        answers.conflicts.value = [.append]
        var job = FileJob(
            kind: .copy,
            sources: [pipe],
            target: TargetSpec(directory: box.url("T")),
            fileSystems: fileSystems
        )
        job.delegate = answers
        _ = job.run()
        job = FileJob(
            kind: .copy,
            sources: [pipe],
            target: TargetSpec(directory: box.url("U")),
            fileSystems: fileSystems
        )
        job.delegate = answers
        _ = job.run()
        #expect(answers.asked.value.filter { $0.contains("is a pipe, a device or a socket") }.count == 2)
        #expect(box.read("T/pipe") == "old")
    }

    /// A partial file kept from a failed try is not taken away when it has changed since.
    @Test
    internal func aKeptPartialFileThatChangedStays() {
        disk.base.addFile("/A/f.bin", String(repeating: "x", count: 3 << 20))
        disk.readsBeforeFailure.value = ["/A/f.bin": 1]
        memory.addDirectory("/B")
        let failures = Shared(0)
        let target = memory
        let answers = CovFileOpsAnswers()
        answers.failures.value = [.retry, .skip]
        answers.onFailure.value = {
            failures.modify { $0 += 1 }
            if failures.value == 1, let partial = target.contents("/B/f.bin") {
                target.addFile("/B/f.bin", partial + "changed")
            }
        }
        let job = FileJob(
            kind: .copy,
            sources: [disk.base.url("/A/f.bin")],
            target: TargetSpec(directory: memory.url("/B")),
            fileSystems: fileSystems
        )
        job.options.keepsPartialFiles = true
        job.delegate = answers
        _ = job.run()
        #expect(memory.contents("/B/f.bin")?.hasSuffix("changed") == true)
    }

    /// A volume in the way of a move is asked about: skipped, entered for all, or the job cancelled.
    @Test
    internal func aVolumeInTheWayOfAMoveIsAskedAbout() throws {
        guard let image = CoverageCoreDiskImage(in: box, name: "AFMMove") else {
            Issue.record("no disk image")
            return
        }
        defer { image.detach() }
        try "on the volume"
            .write(to: image.mountPoint.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try box.folder("T")
        let answers = CovFileOpsAnswers()
        for (answer, cancelled) in [(ProtectionChoice.skip, false), (.cancel, true)] {
            answers.volumes.value = [answer]
            let job = FileJob(
                kind: .move,
                sources: [image.mountPoint],
                target: TargetSpec(directory: box.url("T")),
                fileSystems: fileSystems
            )
            job.delegate = answers
            #expect(job.run().cancelled == cancelled, "\(answer)")
        }
        answers.volumes.value = [.all]
        let job = FileJob(
            kind: .move,
            sources: [image.mountPoint, image.mountPoint],
            target: TargetSpec(directory: box.url("U")),
            fileSystems: fileSystems
        )
        job.options.overwrite = .skipAll
        job.delegate = answers
        _ = job.run()
        #expect(answers.asked.value.filter { $0.hasPrefix("volume") }.count == 3)
    }

    /// Moves to a file system that writes later keep their sources when the job is cancelled before the writes.
    @Test
    internal func deferredRemovalsAreKeptWhenTheJobIsCancelled() {
        disk.abilities.value = [.write, .deferredWrites]
        memory.addFile("/A/one.txt", "1")
        memory.addFile("/A/two.txt", "2")
        disk.base.addDirectory("/B")
        let answers = CovFileOpsAnswers()
        answers.onProgress.value = { job, progress in
            if progress.itemsDone >= 1 { job.cancel() }
        }
        let job = FileJob(
            kind: .move,
            sources: [memory.url("/A/one.txt"), memory.url("/A/two.txt")],
            target: TargetSpec(directory: disk.base.url("/B")),
            fileSystems: fileSystems
        )
        job.delegate = answers
        #expect(job.run().cancelled && memory.exists("/A/one.txt"))
    }

    /// The Trash that refuses a locked item asks about it; kept, it is not trashed.
    @Test
    internal func theTrashRefusingALockedItemAsks() {
        disk.base.addFile("/A/f.txt", "f")
        disk.trashError.value = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let answers = CovFileOpsAnswers()
        answers.protections.value = [.skip]
        let job = FileJob(kind: .delete(toTrash: true), sources: [disk.base.url("/A/f.txt")], fileSystems: fileSystems)
        job.delegate = answers
        #expect(job.run().completed.isEmpty && disk.base.exists("/A/f.txt"))
        #expect(answers.asked.value.contains { $0.hasPrefix("protected: locked") })
    }

    /// Cancelled while the files of a folder are deleted by the workers, the job ends there.
    @Test
    internal func aCancelWhileWorkersDeleteEndsTheJob() throws {
        for number in 0..<40 {
            try box.file("d/f\(number).txt", "\(number)")
        }
        let answers = CovFileOpsAnswers()
        answers.onProgress.value = { job, progress in
            if progress.itemsDone >= 2 { job.cancel() }
        }
        let job = FileJob(kind: .delete(toTrash: false), sources: [box.url("d")], fileSystems: fileSystems)
        job.delegate = answers
        #expect(job.run().cancelled && box.exists("d"))
    }

    /// A locked file that cannot be removed even unlocked gets its lock back.
    @Test
    internal func aLockedFileThatStillCannotGoGetsItsLockBack() throws {
        let file = try box.file("d/f.txt", "f")
        #expect(chflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: box.url("d").path)
        defer {
            _ = chflags(file.path, 0)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: box.url("d").path)
        }
        let answers = CovFileOpsAnswers()
        answers.failures.value = [.skip]
        let job = FileJob(kind: .delete(toTrash: false), sources: [file], fileSystems: fileSystems)
        job.delegate = answers
        _ = job.run()
        #expect(box.exists("d/f.txt") && FileIdentity.flags(of: file).map { $0 & UInt32(UF_IMMUTABLE) != 0 } == true)
    }

    /// Links followed in a count take the size the listing brought; a count past the limit keeps large folders only;
    /// a count cut short by a cancel stops.
    @Test
    internal func countsFollowLinksKeepLargeFoldersAndStop() throws {
        try box.file("S/target.txt", "12345")
        try FileManager.default.createSymbolicLink(atPath: box.url("S/link").path, withDestinationPath: "target.txt")
        for number in 0..<70 {
            try box.file("S/big/f\(number)", "x")
        }
        try box.file("S/small/f", "x")
        var job = FileJob(
            kind: .copy,
            sources: [box.url("S")],
            target: TargetSpec(directory: box.url("T")),
            fileSystems: fileSystems
        )
        job.options.links = .followLinks
        job.rememberedLimit = 1
        let answers = Answers()
        job.delegate = answers
        _ = withExtendedLifetime(answers) { job.run() }
        #expect(box.read("T/S/link") == "12345" && box.exists("T/S/big/f69"))
        for number in 0..<300 {
            disk.base.addFile("/W/d\(number)/f", "x")
        }
        disk.base.addDirectory("/Z")
        job = FileJob(
            kind: .copy,
            sources: [disk.base.url("/W")],
            target: TargetSpec(directory: disk.base.url("/Z")),
            fileSystems: fileSystems
        )
        let held = Shared<FileJob?>(job)
        disk.beforeList.value = { path in
            if path == "/W/d3" { held.value?.cancel() }
        }
        job.delegate = answers
        #expect(withExtendedLifetime(answers) { job.run() }.cancelled)
        held.value = nil
    }
}
