import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileOperationsPlugin
@testable import VirtualFoldersPlugin

/// Runs the job on a thread of its own and gives up waiting only after `Wait.ceiling`.
private func runInBackground(_ job: FileJob) -> JobResult? {
    let finished = DispatchSemaphore(value: 0)
    let result = Shared<JobResult?>(nil)
    Thread {
        result.value = job.run()
        finished.signal()
    }
    .start()
    return finished.wait(timeout: .now() + Wait.ceiling) == .success ? result.value : nil
}

/// Cancels the job from a thread of its own once `gate` is signalled (or after `Wait.ceiling`).
private func cancel(_ job: FileJob, when gate: DispatchSemaphore) {
    Thread {
        _ = gate.wait(timeout: .now() + Wait.ceiling)
        job.cancel()
    }
    .start()
}

/// A job that reads or writes through a virtual folder, with a server that stops answering.
@Suite
internal struct JobsThroughVirtualFolders {
    /// The far file system, in memory; it can be told to stop answering.
    internal let memory = MemoryFileSystem()
    /// The far file system as the registry knows it, telling the test when it is read, written or listed.
    internal let probe: ProbeFileSystem
    /// The disk, the far file system and the virtual folders.
    internal let registry = FileSystemRegistry()
    /// The virtual folders, over the registry.
    internal let virtual: VirtualFileSystem

    /// Registers the disk, the far file system and the virtual folders.
    internal init() {
        probe = ProbeFileSystem(memory)
        registry.register(LocalFileSystem())
        registry.register(probe)
        virtual = VirtualFileSystem(fileSystems: registry)
        registry.register(virtual)
    }

    /// Cancelling a copy whose source a branch view names ends the read that waits on the server,
    /// and nothing is left in the target.
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

    /// Cancelling a copy into a branch view ends the write that waits on the server, and nothing
    /// is left there.
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

    /// Setting the flag ends the listing of a branch view whose server stopped answering.
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
