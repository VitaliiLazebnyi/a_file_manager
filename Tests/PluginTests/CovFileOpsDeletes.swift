import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// Deleting and moving to the Trash in the arms the other tests do not reach: the Trash moving or refusing, what is
/// gone or kept, folders asked about for all or cancelled, locked files among many, items that stay protected.
@Suite
internal struct CovFileOpsDeletes {
    private let disk = CovFileOpsScriptedDisk()
    private let fileSystems = FileSystemRegistry()

    /// A registry with the scripted disk and the disk.
    internal init() {
        fileSystems.register(disk)
        fileSystems.register(LocalFileSystem())
    }

    /// What the Trash takes goes there; where there is none, what is gone is told and what is there is deleted
    /// when the user agrees, or kept.
    @Test
    internal func theTrashTakesOrRefuses() {
        disk.base.addFile("/A/f.txt", "f")
        var result = runJob(.delete(toTrash: true), [disk.base.url("/A/f.txt")], fileSystems: fileSystems)
        #expect(result.completed.count == 1 && disk.base.exists("/.Trash/f.txt"))
        disk.trashError.value = FileSystemError.notSupported("Trash")
        disk.base.addFile("/A/g.txt", "g")
        disk.base.addFile("/A/h.txt", "h")
        let answers = CovFileOpsAnswers()
        answers.protections.value = [.proceed, .skip]
        let job = FileJob(
            kind: .delete(toTrash: true),
            sources: [disk.base.url("/A/gone.txt"), disk.base.url("/A/g.txt"), disk.base.url("/A/h.txt")],
            fileSystems: fileSystems
        )
        job.delegate = answers
        result = job.run()
        #expect(!disk.base.exists("/A/g.txt") && disk.base.exists("/A/h.txt"))
        #expect(answers.asked.value.contains { $0.hasPrefix("failed: gone.txt") })
    }

    /// What says it has no Trash is told apart from other failures, also behind another error.
    @Test
    internal func whatSaysItHasNoTrash() {
        #expect(FileJob.isNoTrash(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))))
        #expect(FileJob.isNoTrash(NSError(domain: NSPOSIXErrorDomain, code: Int(EOPNOTSUPP))))
        let wrapped = NSError(
            domain: "afm",
            code: 1,
            userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSCocoaErrorDomain, code: CocoaError.featureUnsupported.rawValue)
            ]
        )
        #expect(
            FileJob.isNoTrash(wrapped) && !FileJob.isNoTrash(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)))
        )
        let locked = NSError(
            domain: "afm",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))]
        )
        #expect(FileJob.isRefusedAsLocked(locked) && !FileJob.isRefusedAsLocked(NSError(domain: "afm", code: 1)))
    }

    /// Folders that are not empty: deleted for all after one answer, or the job cancelled.
    @Test
    internal func foldersThatAreNotEmpty() {
        for name in ["a", "b", "c"] {
            disk.base.addFile("/D/\(name)/f.txt", "f")
        }
        let answers = CovFileOpsAnswers()
        answers.nonEmpty.value = [.all]
        var job = FileJob(
            kind: .delete(toTrash: false),
            sources: [disk.base.url("/D/a"), disk.base.url("/D/b")],
            fileSystems: fileSystems
        )
        job.delegate = answers
        #expect(job.run().completed.count == 2 && answers.asked.value.filter { $0.hasPrefix("not empty") }.count == 1)
        answers.nonEmpty.value = [.cancel]
        job = FileJob(kind: .delete(toTrash: false), sources: [disk.base.url("/D/c")], fileSystems: fileSystems)
        job.delegate = answers
        #expect(job.run().cancelled && disk.base.exists("/D/c/f.txt"))
    }

    /// A removal refused as locked is tried again after unlocking; refused again, the file gets back what it had.
    @Test
    internal func aLockedRemovalRefusedAgainRestoresTheFile() {
        disk.base.addFile("/L/f.txt", "f", permissions: 0o444)
        disk.removeRule.value = { _, _ in NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) }
        let answers = CovFileOpsAnswers()
        answers.protections.value = [.proceed]
        answers.failures.value = [.skip]
        let job = FileJob(kind: .delete(toTrash: false), sources: [disk.base.url("/L/f.txt")], fileSystems: fileSystems)
        job.options.asksAboutReadOnly = false
        job.delegate = answers
        _ = job.run()
        #expect(disk.base.exists("/L/f.txt") && disk.base.item(at: disk.base.url("/L/f.txt"))?.permissions == 0o444)
    }

    /// Among many files of a folder, locked ones that are kept keep the folder; a cancel in a worker or in a question
    /// ends the job; protection is asked about only where it is wanted.
    @Test
    internal func manyFilesWithLockedAndProtectedOnes() throws {
        let box = try Sandbox()
        for round in ["kept", "cancelled", "asked"] {
            for number in 0..<20 {
                try box.file("\(round)/f\(number).txt", "\(number)")
            }
        }
        let locked = box.url("kept/f3.txt")
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(locked.path, 0) }
        let answers = CovFileOpsAnswers()
        answers.protections.value = [.skip]
        var job = FileJob(kind: .delete(toTrash: false), sources: [box.url("kept")], fileSystems: fileSystems)
        job.delegate = answers
        _ = job.run()
        #expect(box.exists("kept/f3.txt") && !box.exists("kept/f4.txt"))

        let workerLocked = box.url("cancelled/f5.txt")
        #expect(chflags(workerLocked.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(workerLocked.path, 0) }
        answers.protections.value = [.cancel]
        job = FileJob(kind: .delete(toTrash: false), sources: [box.url("cancelled")], fileSystems: fileSystems)
        job.delegate = answers
        #expect(job.run().cancelled && box.exists("cancelled/f5.txt"))

        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: box.url("asked/f7.txt").path)
        try box.file("asked/.hidden", "h")
        answers.protections.value = [.cancel]
        job = FileJob(kind: .delete(toTrash: false), sources: [box.url("asked")], fileSystems: fileSystems)
        job.options.asksAboutHidden = true
        job.delegate = answers
        #expect(job.run().cancelled && box.exists("asked/f7.txt"))
    }

    /// What ignores protection, and a link, is never asked about.
    @Test
    internal func protectionIsIgnoredWhereAsked() throws {
        let box = try Sandbox()
        for number in 0..<20 {
            try box.file("d/f\(number).txt", "\(number)")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: box.url("d/f1.txt").path)
        try FileManager.default.createSymbolicLink(atPath: box.url("d/link").path, withDestinationPath: "f2.txt")
        let answers = CovFileOpsAnswers()
        let job = FileJob(kind: .delete(toTrash: false), sources: [box.url("d")], fileSystems: fileSystems)
        job.options.ignoresProtection = true
        job.delegate = answers
        #expect(job.run().completed.count == 1 && !box.exists("d"))
        #expect(!answers.asked.value.contains { $0.hasPrefix("protected") })
    }

    /// An entry gets back the flags it had; what is not on the disk, or has them already, is left alone.
    @Test
    internal func flagsAreRestored() throws {
        let box = try Sandbox()
        let file = try box.file("f.txt", "f")
        FileIdentity.restoreFlags(UInt32(UF_NODUMP), of: URL(string: "scripted:/f.txt")!)
        FileIdentity.restoreFlags(0, of: file)
        FileIdentity.restoreFlags(UInt32(UF_NODUMP), of: file)
        #expect(FileIdentity.flags(of: file) == UInt32(UF_NODUMP))
    }
}
