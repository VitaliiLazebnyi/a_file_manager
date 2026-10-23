import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// File jobs where the world changes under them or answers oddly: a look that is cancelled, a view that answers
/// with the real place, a tree too deep, a target that goes or turns into a folder before it is extended, a partial
/// file shorter than it says, a read that fails halfway, a verify that is cancelled.
@Suite
internal struct CovFileOpsJobRaces {
    private let disk = CovFileOpsScriptedDisk()
    private let memory = MemoryFileSystem()
    private let fileSystems = FileSystemRegistry()

    /// A registry with the scripted disk and the memory file system.
    internal init() {
        fileSystems.register(disk)
        fileSystems.register(memory)
    }

    /// A job cancelled while it looks at a file ends there.
    @Test
    internal func aJobCancelledWhileItLooksEndsThere() {
        disk.base.addFile("/A/f.txt", "file")
        let job = FileJob(
            kind: .copy,
            sources: [disk.base.url("/A/f.txt")],
            target: TargetSpec(directory: disk.base.url("/B")),
            fileSystems: fileSystems
        )
        let held = Shared<FileJob?>(job)
        disk.beforeLook.value = { path, _ in
            if path == "/B/f.txt" { held.value?.cancel() }
        }
        let answers = Answers()
        job.delegate = answers
        let result = withExtendedLifetime(answers) { job.run() }
        held.value = nil
        #expect(result.cancelled && !disk.base.exists("/B/f.txt"))
    }

    /// A target folder, or a file in it, that the file system answers with the real place of another file system
    /// is written there.
    @Test
    internal func aViewIsWrittenThroughToTheRealPlace() {
        memory.addFile("/A/f.txt", "new")
        memory.addFile("/R/g.txt", "old")
        let folder = FileItem(url: memory.url("/R"), name: "R", kind: .directory)
        let file = FileItem(url: memory.url("/R/g.txt"), name: "g.txt", stat: .init(size: 3))
        disk.seen.value = ["/V": folder, "/W/g.txt": file]
        var result = Answers()
            .run(
                .copy,
                [memory.url("/A/f.txt")],
                to: TargetSpec(directory: disk.base.url("/V")),
                fileSystems: fileSystems
            )
        #expect(result.completed.count == 1 && memory.contents("/R/f.txt") == "new")
        disk.base.addDirectory("/W")
        result = Answers()
            .run(
                .copy,
                [memory.url("/A/f.txt")],
                to: TargetSpec(directory: disk.base.url("/W"), exactName: "g.txt"),
                fileSystems: fileSystems
            )
        #expect(result.completed.count == 1 && memory.contents("/R/g.txt") == "new")
    }

    /// A tree deeper than the job goes is reported for the folder where it stops.
    @Test
    internal func aTreeTooDeepIsReported() {
        memory.addFile("/A/one/two/three/f.txt", "deep")
        let job = FileJob(
            kind: .copy,
            sources: [memory.url("/A/one")],
            target: TargetSpec(directory: memory.url("/B")),
            fileSystems: fileSystems
        )
        job.depthLimit = 1
        let answers = CovFileOpsAnswers()
        job.delegate = answers
        _ = job.run()
        #expect(answers.asked.value.contains { $0.contains("nested too deep") } && !memory.exists("/B/one/two/three"))
    }

    /// A target that goes before it is extended, or becomes a folder, is told; the source stays.
    @Test
    internal func aTargetThatChangesBeforeItIsExtendedIsTold() {
        for change in ["gone", "folder"] {
            disk.base.addFile("/A/f.txt", "new")
            disk.base.addFile("/B/f.txt", "old")
            let base = disk.base
            disk.beforeLook.value = { path, count in
                guard path == "/B/f.txt", count == 1 else {
                    return
                }
                try? base.remove(base.url("/B/f.txt"))
                if change == "folder" { base.addDirectory("/B/f.txt") }
            }
            let answers = CovFileOpsAnswers()
            answers.conflicts.value = [.append]
            let job = FileJob(
                kind: .copy,
                sources: [disk.base.url("/A/f.txt")],
                target: TargetSpec(directory: disk.base.url("/B")),
                fileSystems: fileSystems
            )
            job.delegate = answers
            _ = job.run()
            #expect(answers.asked.value.contains { $0.hasPrefix("failed: f.txt") }, "\(change)")
            disk.beforeLook.value = nil
            disk.looks.value = [:]
            try? disk.base.remove(disk.base.url("/B/f.txt"))
        }
    }

    /// A partial file that is shorter than it says cannot be resumed; a read that fails halfway leaves the partial
    /// file as it was.
    @Test
    internal func resumingNeedsAWholeStartAndAWholeRead() {
        disk.abilities.value = [.write, .append]
        disk.base.capabilities = [.write, .append]
        disk.base.addFile("/A/f.txt", "0123456789")
        disk.base.addFile("/B/f.txt", "012")
        disk.seen.value = ["/B/f.txt": FileItem(url: disk.base.url("/B/f.txt"), name: "f.txt", stat: .init(size: 5))]
        let answers = CovFileOpsAnswers()
        answers.conflicts.value = [.resume]
        var job = FileJob(
            kind: .copy,
            sources: [disk.base.url("/A/f.txt")],
            target: TargetSpec(directory: disk.base.url("/B")),
            fileSystems: fileSystems
        )
        job.delegate = answers
        _ = job.run()
        #expect(answers.asked.value.contains { $0.contains("cannot be resumed") || $0.contains("resume") })
        disk.seen.value = [:]
        disk.readsBeforeFailure.value = ["/A/f.txt": 1]
        job = FileJob(
            kind: .copy,
            sources: [disk.base.url("/A/f.txt")],
            target: TargetSpec(directory: disk.base.url("/B")),
            fileSystems: fileSystems
        )
        job.delegate = answers
        _ = job.run()
        #expect(disk.base.contents("/B/f.txt")?.hasPrefix("012") == true)
    }

    /// A verify that is cancelled ends the job.
    @Test
    internal func aCancelledVerifyEndsTheJob() {
        memory.addFile("/A/f.txt", String(repeating: "x", count: 4_096))
        disk.base.addDirectory("/B")
        let job = FileJob(
            kind: .copy,
            sources: [memory.url("/A/f.txt")],
            target: TargetSpec(directory: disk.base.url("/B")),
            fileSystems: fileSystems
        )
        job.options.verifies = true
        let answers = CovFileOpsAnswers()
        // Cancelled at the second report of the verify: its reads are open by then.
        let reports = Shared(0)
        answers.onProgress.value = { job, progress in
            guard progress.lines.first?.hasPrefix("Verifying") == true else {
                return
            }
            reports.modify { $0 += 1 }
            if reports.value == 2 { job.cancel() }
        }
        job.delegate = answers
        #expect(job.run().cancelled)
    }

    /// A target that turns out to be the source itself, once seen through, is never written over nor taken for a
    /// second copy: refused before a write or an append, and a move keeps its source when it shows only afterwards.
    @Test
    internal func aTargetThatIsTheSourceItselfIsNeverWrittenOver() {
        memory.addFile("/A/f.txt", "source")
        disk.base.addDirectory("/V")
        let source = memory.url("/A/f.txt")
        disk.realPlaces.value = { path, _ in path == "/V/f.txt" ? source : nil }
        let answers = CovFileOpsAnswers()
        var job = FileJob(
            kind: .copy,
            sources: [source],
            target: TargetSpec(directory: disk.base.url("/V")),
            fileSystems: fileSystems
        )
        job.delegate = answers
        _ = job.run()
        #expect(answers.asked.value.contains { $0.hasPrefix("failed: f.txt") } && !disk.base.exists("/V/f.txt"))
        disk.base.addFile("/V/f.txt", "old")
        answers.conflicts.value = [.append]
        job = FileJob(
            kind: .copy,
            sources: [source],
            target: TargetSpec(directory: disk.base.url("/V")),
            fileSystems: fileSystems
        )
        job.delegate = answers
        _ = job.run()
        #expect(disk.base.contents("/V/f.txt") == "old")
        try? disk.base.remove(disk.base.url("/V/f.txt"))
        disk.realAsks.value = [:]
        // Seen through only after the move has written: the source stays.
        disk.realPlaces.value = { path, count in path == "/V/f.txt" && count > 0 ? source : nil }
        job = FileJob(
            kind: .move,
            sources: [source],
            target: TargetSpec(directory: disk.base.url("/V")),
            fileSystems: fileSystems
        )
        job.delegate = answers
        _ = job.run()
        #expect(memory.contents("/A/f.txt") == "source" && disk.base.contents("/V/f.txt") == "source")
    }

    /// A view that says nothing of what it shows is still seen through by the folder above it that it answers: the
    /// same path on another file system.
    @Test
    internal func aViewIsSeenThroughByItsParent() {
        disk.parents.value = ["/V": memory.url("/V")]
        #expect(RealLocation.resolve(disk.base.url("/V"), in: fileSystems) == memory.url("/V"))
    }

    /// A copy within one file system that fails is told; cancelled meanwhile, it is the cancel.
    @Test
    internal func aCopyWithinOneFileSystemThatFails() {
        disk.base.addFile("/A/f.txt", "f")
        disk.base.addDirectory("/B")
        let held = Shared<FileJob?>(nil)
        disk.copyRule.value = { _, _ in
            held.value?.cancel()
            return CocoaError(.fileWriteUnknown)
        }
        let job = FileJob(
            kind: .copy,
            sources: [disk.base.url("/A/f.txt")],
            target: TargetSpec(directory: disk.base.url("/B")),
            fileSystems: fileSystems
        )
        held.value = job
        let answers = CovFileOpsAnswers()
        job.delegate = answers
        #expect(job.run().cancelled && !answers.asked.value.contains { $0.hasPrefix("failed") })
        held.value = nil
    }
}
