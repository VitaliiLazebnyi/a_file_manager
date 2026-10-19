import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// File jobs in the arms the other tests do not reach: the delegate's defaults, a job without a target, many
/// target folders and many folders compared by age, files read in another order, names a job produced twice,
/// protected targets, moves that are copies after all, links to pipes, temporary files that will not go.
@Suite
internal struct CovFileOpsJobs {
    private let memory = MemoryFileSystem()
    private let fileSystems = FileSystemRegistry()

    /// A registry with the memory file system and the disk.
    internal init() {
        fileSystems.register(LocalFileSystem())
        fileSystems.register(memory)
    }

    /// Whoever does not care merges, goes ahead with what is protected and stays out of other volumes.
    @Test
    internal func theDelegatesDefaults() {
        let job = FileJob(kind: .copy, sources: [], fileSystems: fileSystems)
        let folder = FileItem(url: memory.url("/A"), name: "A", kind: .directory)
        let answers = Answers()
        #expect(answers.job(job, mergeInto: folder, source: folder) == .merge)
        #expect(
            answers.job(job, confirm: ProtectionQuestion(reason: .hidden, purpose: .delete, item: folder)) == .proceed
        )
        #expect(answers.job(job, crossVolumeAt: folder, purpose: .move) == .skip)
        #expect(
            FileJobError.folderNotEmpty("/A").errorDescription == "/A still contains items that could not be processed."
        )
    }

    /// A transfer without a target does nothing.
    @Test
    internal func aTransferWithoutATargetDoesNothing() {
        memory.addFile("/A/one.txt", "1")
        let result = runJob(.copy, [memory.url("/A/one.txt")], fileSystems: fileSystems)
        #expect(result.completed.isEmpty && !result.cancelled)
    }

    /// The folders looked through for left-behind copies are forgotten after a while.
    @Test
    internal func theFoldersLookedThroughAreForgottenAfterAWhile() {
        for number in 0...1_024 {
            runJob(.copy, [], to: TargetSpec(directory: memory.url("/T\(number)")), fileSystems: fileSystems)
        }
        #expect(!memory.exists("/T0/x"))
    }

    /// Files from a file system that reads them best in another order are copied in that order; an order that is
    /// not of the same files is not followed.
    @Test
    internal func filesAreReadInTheOrderTheirFileSystemGives() {
        let disk = CovFileOpsScriptedDisk()
        fileSystems.register(disk)
        for name in ["a", "b", "c"] {
            disk.base.addFile("/S/\(name)", name)
            disk.base.addFile("/S/dir/\(name)", name)
        }
        let sources = ["a", "b", "c"].map { disk.base.url("/S/\($0)") }
        memory.addDirectory("/T")
        memory.addDirectory("/U")
        disk.order.value = { $0.reversed() }
        var result = runJob(
            .copy,
            sources + [disk.base.url("/S/dir")],
            to: TargetSpec(directory: memory.url("/T")),
            fileSystems: fileSystems
        )
        #expect(result.completed.count == 4 && memory.contents("/T/dir/c") == "c")
        disk.order.value = { urls in urls.dropLast() + [URL(string: "scripted:/elsewhere")!] }
        result = runJob(
            .copy,
            sources + [disk.base.url("/S/dir")],
            to: TargetSpec(directory: memory.url("/U")),
            fileSystems: fileSystems
        )
        #expect(result.completed.count == 4 && memory.contents("/U/dir/a") == "a")
    }

    /// Where two sources come to one name, the second meets the job's own file: skipped, the first renamed, or
    /// the older kept as the rule says.
    @Test
    internal func aNameTheJobProducedTwiceFollowsTheRule() {
        memory.addFile("/x/f.txt", "first", modified: Date(timeIntervalSince1970: 1_000))
        memory.addFile("/y/f.txt", "second", modified: Date(timeIntervalSince1970: 9_000))
        let sources = [memory.url("/x/f.txt"), memory.url("/y/f.txt")]
        for (mode, expected) in [
            (OverwriteMode.skipAll, "first"), (.autoRenameExisting, "second"), (.renameOlderSkipNewer, "second")
        ] {
            let job = FileJob(
                kind: .copy,
                sources: sources,
                target: TargetSpec(directory: memory.url("/T-\(mode)")),
                fileSystems: fileSystems
            )
            job.options.overwrite = mode
            let answers = Answers()
            job.delegate = answers
            _ = withExtendedLifetime(answers) { job.run() }
            #expect(memory.contents("/T-\(mode)/f.txt") == expected, "\(mode)")
        }
    }

    /// Ages are compared with the grain of every folder involved, also for many folders.
    @Test
    internal func agesAreComparedAcrossManyFolders() {
        var sources: [URL] = []
        for number in 0..<260 {
            sources.append(
                memory.addFile("/s\(number)/f\(number).txt", "new", modified: Date(timeIntervalSince1970: 9_000))
            )
            memory.addFile("/T/f\(number).txt", "old", modified: Date(timeIntervalSince1970: 1_000))
        }
        let job = FileJob(
            kind: .copy,
            sources: sources,
            target: TargetSpec(directory: memory.url("/T")),
            fileSystems: fileSystems
        )
        job.options.overwrite = .overwriteOlder
        let answers = Answers()
        job.delegate = answers
        let result = withExtendedLifetime(answers) { job.run() }
        #expect(result.completed.count == 260 && memory.contents("/T/f259.txt") == "new")
    }

    /// Cancelled at a protected target, the job ends; an append onto one that is left alone is skipped.
    @Test
    internal func protectedTargetsAreAskedAbout() {
        memory.addFile("/A/f.txt", "new")
        memory.addFile("/B/f.txt", "old", permissions: 0o444)
        let answers = CovFileOpsAnswers()
        answers.protections.value = [.cancel]
        let target = TargetSpec(directory: memory.url("/B"))
        var job = FileJob(kind: .copy, sources: [memory.url("/A/f.txt")], target: target, fileSystems: fileSystems)
        job.delegate = answers
        #expect(job.run().cancelled && memory.contents("/B/f.txt") == "old")
        answers.conflicts.value = [.append]
        answers.protections.value = [.skip]
        job = FileJob(kind: .copy, sources: [memory.url("/A/f.txt")], target: target, fileSystems: fileSystems)
        job.delegate = answers
        #expect(job.run().completed.isEmpty && memory.contents("/B/f.txt") == "old")
    }

    /// A move the file system cannot make a rename is a copy and a removal, for files and for folders.
    @Test
    internal func aMoveThatCannotBeARenameIsACopy() {
        let disk = CovFileOpsScriptedDisk()
        fileSystems.register(disk)
        disk.base.addFile("/A/f.txt", "file")
        disk.base.addFile("/A/dir/g.txt", "inside")
        disk.moveRule.value = { source, _ in
            source.lastPathComponent.hasPrefix(".afm-") ? nil : FileSystemError.crossesVolumes
        }
        let result = runJob(
            .move,
            [disk.base.url("/A/f.txt"), disk.base.url("/A/dir")],
            to: TargetSpec(directory: disk.base.url("/B")),
            fileSystems: fileSystems
        )
        #expect(result.completed.count == 2 && disk.base.contents("/B/dir/g.txt") == "inside")
        #expect(!disk.base.exists("/A/f.txt") && !disk.base.exists("/A/dir"))
    }

    /// A link to a pipe is copied as the link it is.
    @Test
    internal func aLinkToAPipeIsCopiedAsALink() throws {
        let box = try Sandbox()
        let pipe = box.url("pipe")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        try FileManager.default.createSymbolicLink(at: box.url("link"), withDestinationURL: pipe)
        let target = try box.folder("T")
        let result = runJob(.copy, [box.url("link")], to: TargetSpec(directory: target), fileSystems: fileSystems)
        #expect(result.completed.count == 1)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.url("T/link").path) == pipe.path)
    }

    /// The temporary file of a copy that failed is unlocked to be removed; where it still will not go, the user
    /// hears of it.
    @Test
    internal func aTemporaryFileThatWillNotGoIsUnlockedOrTold() {
        let disk = CovFileOpsScriptedDisk()
        fileSystems.register(disk)
        disk.base.addFile("/A/f.txt", "file")
        let base = disk.base
        disk.copyRule.value = { source, destination in
            try? base.copy(source, to: destination ?? source) { _ in true }
            return CocoaError(.fileWriteUnknown)
        }
        let refused = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        for removals in [1, 5] {
            let count = Shared(0)
            disk.removeRule.value = { url, _ in
                guard url.lastPathComponent.hasPrefix(".afm-") else {
                    return nil
                }
                count.modify { $0 += 1 }
                return count.value <= removals ? refused : nil
            }
            let answers = CovFileOpsAnswers()
            answers.failures.value = [.skip]
            let job = FileJob(
                kind: .copy,
                sources: [disk.base.url("/A/f.txt")],
                target: TargetSpec(directory: disk.base.url("/B-\(removals)")),
                fileSystems: fileSystems
            )
            job.delegate = answers
            let result = job.run()
            let left = disk.base.allPaths.filter { $0.hasPrefix("/B-\(removals)/.afm-") }
            #expect(left.count == (removals == 1 ? 0 : 1), "\(removals)")
            #expect(result.failures.contains { $0.contains("could not be removed") } == (removals > 1))
        }
    }

    /// A name of a temporary file's length that is not one is left in the target folder; a copy between file systems
    /// that keeps no attributes gets none.
    @Test
    internal func oddNamesInTheTargetAndNoAttributes() throws {
        let box = try Sandbox()
        let odd = ".afm-zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz.tmp"
        try box.file("T/\(odd)", "kept", modified: Date(timeIntervalSince1970: 1_000))
        memory.addFile("/A/f.txt", "file", modified: Date(timeIntervalSince1970: 5_000))
        let job = FileJob(
            kind: .copy,
            sources: [memory.url("/A/f.txt")],
            target: TargetSpec(directory: box.url("T")),
            fileSystems: fileSystems
        )
        job.options.preservesAttributes = false
        let answers = Answers()
        job.delegate = answers
        _ = withExtendedLifetime(answers) { job.run() }
        #expect(box.exists("T/\(odd)") && box.read("T/f.txt") == "file")
        let modified =
            try FileManager.default.attributesOfItem(atPath: box.url("T/f.txt").path)[.modificationDate] as? Date
        #expect(modified.map { $0.timeIntervalSince1970 > 5_000 } == true)
    }
}
