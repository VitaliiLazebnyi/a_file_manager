import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// File jobs stopped where they are hard to stop: workers deleting, locks that come back, counts cut short, a
/// verify after a resume that fails, a verify cancelled while it reads, questions that come while the job is
/// being cancelled, two workers failing at once.
@Suite
internal struct CovFileOpsJobStops {
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

    /// A verify after a resume that fails takes off again what was added.
    @Test
    internal func aFailedVerifyAfterAResumeTakesOffWhatWasAdded() {
        disk.abilities.value = [.write, .append]
        disk.base.capabilities = [.write, .append]
        disk.base.addFile("/A/f.txt", "0123456789")
        disk.base.addFile("/B/f.txt", "012")
        // The start is compared, the rest read and its end seen; the verify's read then fails.
        disk.readsBeforeFailure.value = ["/A/f.txt": 3]
        let answers = CovFileOpsAnswers()
        answers.conflicts.value = [.resume]
        let job = FileJob(
            kind: .copy,
            sources: [disk.base.url("/A/f.txt")],
            target: TargetSpec(directory: disk.base.url("/B")),
            fileSystems: fileSystems
        )
        job.options.verifies = true
        job.delegate = answers
        _ = job.run()
        #expect(disk.base.contents("/B/f.txt") == "012")
    }

    /// A verify cancelled while its reads wait ends the job.
    @Test
    internal func aVerifyCancelledWhileItReadsEndsTheJob() {
        memory.addFile("/A/f.txt", "contents")
        memory.addDirectory("/B")
        let job = FileJob(
            kind: .copy,
            sources: [memory.url("/A/f.txt")],
            target: TargetSpec(directory: memory.url("/B")),
            fileSystems: fileSystems
        )
        job.options.verifies = true
        let target = memory
        let held = Shared<FileJob?>(job)
        let answers = CovFileOpsAnswers()
        answers.onProgress.value = { _, progress in
            guard progress.lines.first?.hasPrefix("Verifying") == true, !target.stallsReads else {
                return
            }
            target.stallsReads = true
            OtherThread.start {
                _ = Wait.until { target.stalledTransfers >= 2 }
                held.value?.cancel()
            }
        }
        job.delegate = answers
        #expect(job.run().cancelled)
        memory.releaseStalls()
        held.value = nil
    }

    /// Cancelled while it reports the volume it is about to enter, a delete asks nothing more.
    @Test
    internal func aDeleteCancelledAtAVolumeAsksNothing() throws {
        guard let image = CoverageCoreDiskImage(in: box, name: "AFMStopAtVolume") else {
            Issue.record("no disk image")
            return
        }
        defer { image.detach() }
        try "kept".write(to: image.mountPoint.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let answers = CovFileOpsAnswers()
        let mount = image.mountPoint.path
        answers.onProgress.value = { job, progress in
            if progress.lines.first == "Deleting: \(mount)" { job.cancel() }
        }
        let job = FileJob(kind: .delete(toTrash: false), sources: [image.mountPoint], fileSystems: fileSystems)
        job.delegate = answers
        #expect(job.run().cancelled && !answers.asked.value.contains { $0.hasPrefix("volume") })
        #expect(FileManager.default.fileExists(atPath: image.mountPoint.appendingPathComponent("f.txt").path))
    }

    /// A protected file agreed to while the job is being cancelled ends the delete when the workers are done; a
    /// cancel among protected files only ends it as well.
    @Test
    internal func questionsAnsweredWhileTheJobIsCancelled() throws {
        for number in 0..<20 {
            try box.file("d/f\(number).txt", "\(number)")
            let file = try box.file("p/f\(number).txt", "\(number)")
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: box.url("d/f0.txt").path)
        var job = FileJob(kind: .delete(toTrash: false), sources: [box.url("d")], fileSystems: fileSystems)
        let held = Shared<FileJob?>(job)
        let answers = CovFileOpsAnswers()
        answers.onQuestion.value = { question in
            if question.hasPrefix("protected") { held.value?.cancel() }
        }
        job.delegate = answers
        #expect(job.run().cancelled)
        answers.onQuestion.value = nil
        answers.protections.value = [.cancel]
        job = FileJob(kind: .delete(toTrash: false), sources: [box.url("p")], fileSystems: fileSystems)
        job.delegate = answers
        #expect(job.run().cancelled && box.exists("p/f19.txt"))
        // Cancelled at the question about the one protected file, which is kept, once the workers have deleted
        // the others: nothing fails, the job ends all the same.
        for number in 0..<16 {
            try box.file("q/f\(number).txt", "\(number)")
        }
        let kept = try box.file("q/kept.txt", "kept")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: kept.path)
        let folder = box.url("q")
        answers.protections.value = [.skip]
        job = FileJob(kind: .delete(toTrash: false), sources: [folder], fileSystems: fileSystems)
        held.value = job
        answers.onQuestion.value = { question in
            guard question.hasPrefix("protected") else {
                return
            }
            _ = Wait.until { (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["kept.txt"] }
            held.value?.cancel()
        }
        job.delegate = answers
        #expect(job.run().cancelled && box.exists("q/kept.txt"))
        held.value = nil
    }

    /// Two workers that fail at once: the second, which waited for the first's question, asks nothing once that
    /// one aborted.
    @Test
    internal func twoWorkersFailingAtOnceAskOnce() throws {
        var unreadable: [URL] = []
        for number in 0..<20 {
            let file = try box.file("s/f\(number).txt", "\(number)")
            if number < 2 { unreadable.append(file) }
        }
        for file in unreadable {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        }
        defer {
            for file in unreadable {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            }
        }
        let failed = Shared(0)
        let answers = CovFileOpsAnswers()
        answers.failures.value = [.abort]
        answers.onFailure.value = {
            _ = Wait.until { failed.value >= 2 }
        }
        let job = FileJob(
            kind: .copy,
            sources: [box.url("s")],
            target: TargetSpec(directory: box.url("T")),
            fileSystems: fileSystems
        )
        job.onRecord = { record in
            if case .failed = record.status { failed.modify { $0 += 1 } }
        }
        job.delegate = answers
        #expect(job.run().cancelled && answers.asked.value.filter { $0.hasPrefix("failed") }.count == 1)
    }
}
