import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FileOperationsPlugin

// The jobs and commands that use the provider API of the last round: cancelling a blocked
// stream, metadata of folders, continuing a partial file, per-location capabilities, commits
// before a move deletes, origin marks.

/// Cancelling a job whose stream or listing waits for the file system.
@Suite
internal struct FileOpsAdoptCancellation {
    /// Counts calls made from several threads.
    ///
    /// Unchecked: the state is guarded by `lock`.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0

        func next() -> Int {
            lock.withLock {
                calls += 1
                return calls
            }
        }

        deinit {
            // Nothing to release.
        }
    }

    /// A cancel ends a read that waits and leaves no temporary file in the target.
    @Test
    internal func cancelEndsAReadThatWaitsAndLeavesNoTemporaryFile() throws {
        let box = try Sandbox()
        let base = MemoryFileSystem()
        base.stallsReads = true
        let probe = ProbeFileSystem(base)
        let gate = DispatchSemaphore(value: 0)
        probe.onRead = { gate.signal() }
        let source = base.addFile("/src/big.bin", "some data")
        let out = try box.folder("out")
        let job = FileJob(
            kind: .copy,
            sources: [source],
            target: TargetSpec(directory: out),
            fileSystems: FileSystemRegistry.localDisk(and: probe)
        )
        let answers = Answers()
        job.delegate = answers
        cancel(job, when: gate)
        let result = withExtendedLifetime(answers) { run(job) }
        #expect(result?.cancelled == true)
        #expect(base.interruptions >= 1)
        #expect(namesOnDisk(out).isEmpty)
    }

    /// A cancel ends a write that waits and removes what had arrived.
    @Test
    internal func cancelEndsAWriteThatWaitsAndRemovesWhatArrived() throws {
        let box = try Sandbox()
        let base = MemoryFileSystem()
        base.stallsWrites = true
        let probe = ProbeFileSystem(base)
        let gate = DispatchSemaphore(value: 0)
        probe.onWrite = { gate.signal() }
        let source = try box.file("A/data.bin", "some data")
        base.addDirectory("/out")
        let job = FileJob(
            kind: .copy,
            sources: [source],
            target: TargetSpec(directory: base.url("/out")),
            fileSystems: FileSystemRegistry.localDisk(and: probe)
        )
        let answers = Answers()
        job.delegate = answers
        cancel(job, when: gate)
        let result = withExtendedLifetime(answers) { run(job) }
        #expect(result?.cancelled == true)
        #expect(base.interruptions >= 1)
        #expect(base.allPaths == ["/out"])
    }

    /// A cancel ends the read of a verification that waits, and the copy goes.
    @Test
    internal func cancelEndsAVerifyingReadThatWaits() throws {
        let box = try Sandbox()
        let base = MemoryFileSystem()
        let probe = ProbeFileSystem(base)
        let gate = DispatchSemaphore(value: 0)
        // The copy reads the source (the data, then the end); the read of the verification is the third and waits.
        let reads = CallCounter()
        probe.onRead = {
            switch reads.next() {
            case 2:
                base.stallsReads = true

            case 3:
                gate.signal()

            default:
                break
            }
        }
        let source = base.addFile("/src/big.bin", "some data")
        let out = try box.folder("out")
        let job = FileJob(
            kind: .copy,
            sources: [source],
            target: TargetSpec(directory: out),
            fileSystems: FileSystemRegistry.localDisk(and: probe)
        )
        job.options.verifies = true
        let answers = Answers()
        job.delegate = answers
        cancel(job, when: gate)
        let result = withExtendedLifetime(answers) { run(job) }
        #expect(result?.cancelled == true)
        #expect(base.interruptions >= 1)
        #expect(namesOnDisk(out).isEmpty)
    }

    /// A cancel ends a listing that waits, and nothing counts as done.
    @Test
    internal func cancelEndsAListingThatWaits() throws {
        let box = try Sandbox()
        let base = MemoryFileSystem()
        base.stallsListings = true
        let probe = ProbeFileSystem(base)
        let gate = DispatchSemaphore(value: 0)
        probe.onList = { gate.signal() }
        base.addFile("/src/tree/a.txt")
        let out = try box.folder("out")
        let job = FileJob(
            kind: .copy,
            sources: [base.url("/src/tree")],
            target: TargetSpec(directory: out),
            fileSystems: FileSystemRegistry.localDisk(and: probe)
        )
        let answers = Answers()
        job.delegate = answers
        cancel(job, when: gate)
        let result = withExtendedLifetime(answers) { run(job) }
        #expect(result?.cancelled == true)
        #expect(result?.completed.isEmpty == true)
    }

    /// A stream that is not cancelled arrives in full, and nothing is interrupted.
    @Test
    internal func aStreamThatIsNotCancelledStillCompletes() throws {
        let box = try Sandbox()
        let base = MemoryFileSystem()
        let source = base.addFile("/src/a.txt", "payload")
        let out = try box.folder("out")
        let result = Answers()
            .run(.copy, [source], to: TargetSpec(directory: out), fileSystems: FileSystemRegistry.localDisk(and: base))
        #expect(!result.cancelled && result.completed == [source])
        #expect(try String(contentsOf: out.appendingPathComponent("a.txt")) == "payload")
        #expect(base.interruptions == 0)
    }

    /// Runs the job on a thread of its own and gives up waiting after `seconds`.
    private func run(_ job: FileJob, within seconds: Double = 60) -> JobResult? {
        let finished = DispatchSemaphore(value: 0)
        // Written by the thread before it signals `finished`, read only after that.
        nonisolated(unsafe) var result: JobResult?
        let thread = Thread {
            result = job.run()
            finished.signal()
        }
        thread.start()
        return finished.wait(timeout: .now() + seconds) == .success ? result : nil
    }

    /// Cancels the job as soon as `gate` is signalled (or after a minute, so that nothing hangs).
    private func cancel(_ job: FileJob, when gate: DispatchSemaphore) {
        let thread = Thread {
            _ = gate.wait(timeout: .now() + 60)
            job.cancel()
        }
        thread.start()
    }
}
