import AFMKernel
import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

/// Several small files at once, and what stays the same when they are.
@Suite
internal struct ParallelCopies {
    /// How many files `fill` makes at the top of the tree.
    internal static let count = 120

    /// A tree of small files in memory: /src/file000.txt … and /src/sub/….
    internal func fill(_ memory: MemoryFileSystem) {
        for index in 0..<Self.count {
            memory.addFile(String(format: "/src/file%03d.txt", index), "content \(index)")
            if index.isMultiple(of: 4) {
                memory.addFile(String(format: "/src/sub/deep%03d.txt", index), "deep \(index)")
            }
        }
    }

    /// On local storage small files are written several at once, and the progress counters still only go forward.
    @Test
    internal func smallFilesAreCopiedSeveralAtOnceOnLocalStorage() {
        let (fileSystems, wrapped) = makeWrappedFileSystems()
        fill(wrapped.base)
        wrapped.base.addDirectory("/dst")
        wrapped.delay = 0.002
        let replies = Replies()
        let result = replies.run(
            .copy,
            [wrapped.base.url("/src")],
            to: TargetSpec(directory: wrapped.base.url("/dst")),
            fileSystems: fileSystems
        ) { $0.parallelWidth = 4 }
        #expect(result.completed.count == 1 && !result.cancelled)
        #expect(wrapped.mostWritesAtOnce > 1 && wrapped.mostWritesAtOnce <= 4)
        for index in 0..<Self.count {
            #expect(wrapped.base.contents(String(format: "/dst/src/file%03d.txt", index)) == "content \(index)")
        }
        // The files, one in four again in sub, and the two folders.
        let copied = wrapped.base.allPaths.filter { $0.hasPrefix("/dst/") }
        #expect(copied.count == ParallelCopies.count + ParallelCopies.count / 4 + 2)
        // The counters stay consistent: they never go back, and they end at the totals.
        let progress = replies.progress
        #expect(
            zip(progress, progress.dropFirst())
                .allSatisfy { earlier, later in
                    earlier.itemsDone <= later.itemsDone && earlier.bytesDone <= later.bytesDone
                }
        )
        #expect(
            progress.last?.itemsDone == progress.last?.itemsTotal
                && progress.last?.bytesDone == progress.last?.bytesTotal
        )
        #expect(progress.last?.itemsTotal == ParallelCopies.count + ParallelCopies.count / 4 + 2)
    }

    /// A volume that is not local, or the option switched off, gets one write at a time.
    @Test
    internal func aNetworkVolumeGetsASingleStream() {
        let (fileSystems, wrapped) = makeWrappedFileSystems()
        fill(wrapped.base)
        wrapped.base.addDirectory("/dst")
        wrapped.base.isLocal = false
        wrapped.delay = 0.001
        Replies()
            .run(
                .copy,
                [wrapped.base.url("/src")],
                to: TargetSpec(directory: wrapped.base.url("/dst")),
                fileSystems: fileSystems,
                configure: nil
            )
        #expect(wrapped.mostWritesAtOnce == 1 && wrapped.base.exists("/dst/src/file119.txt"))
        // The same when the option is switched off.
        let (others, local) = makeWrappedFileSystems()
        fill(local.base)
        local.base.addDirectory("/dst")
        local.delay = 0.001
        Replies()
            .run(
                .copy,
                [local.base.url("/src")],
                to: TargetSpec(directory: local.base.url("/dst")),
                fileSystems: others
            ) { job in
                job.options.copiesSmallFilesInParallel = false
            }
        #expect(local.mostWritesAtOnce == 1)
    }

    /// Conflicts met by parallel workers are asked about one at a time, in the order of the files.
    @Test
    internal func conflictsAreAskedOneAtATimeInProcessingOrder() {
        let (fileSystems, wrapped) = makeWrappedFileSystems()
        fill(wrapped.base)
        for index in stride(from: 0, to: Self.count, by: 10) {
            wrapped.base.addFile(String(format: "/dst/src/file%03d.txt", index), "old")
        }
        wrapped.delay = 0.001
        let replies = Replies(.overwrite, .skip)
        replies.run(
            .copy,
            [wrapped.base.url("/src")],
            to: TargetSpec(directory: wrapped.base.url("/dst")),
            fileSystems: fileSystems,
            configure: nil
        )
        #expect(
            replies.conflicts
                == stride(from: 0, to: ParallelCopies.count, by: 10).map { String(format: "file%03d.txt", $0) }
        )
        #expect(
            wrapped.base.contents("/dst/src/file000.txt") == "content 0"
                && wrapped.base.contents("/dst/src/file010.txt") == "old"
        )
        #expect(wrapped.base.contents("/dst/src/file011.txt") == "content 11")
    }

    /// A cancelled parallel copy leaves only whole files, and nothing arrives after the job has returned.
    @Test
    internal func aCancelledParallelCopyLeavesNoPartialFiles() throws {
        let box = try Sandbox()
        let (fileSystems, wrapped) = makeWrappedFileSystems()
        // Streams from memory onto the disk: each file arrives under a temporary name first.
        for index in 0..<Self.count {
            wrapped.base.addFile(
                String(format: "/src/file%03d.txt", index),
                String(repeating: "\(index % 10)", count: 3_000)
            )
        }
        try box.folder("B")
        let replies = Replies()
        replies.cancelAtItems = 30
        let result = replies.run(
            .copy,
            [wrapped.base.url("/src")],
            to: TargetSpec(directory: box.url("B")),
            fileSystems: fileSystems
        ) { job in
            job.parallelWidth = 6
        }
        #expect(result.cancelled && result.completed.isEmpty)
        let arrived = namesOnDisk(box.url("B/src"))
        #expect(arrived.count >= 29 && arrived.count < ParallelCopies.count)
        // No temporary names, and every file that is there is whole.
        #expect(arrived.allSatisfy { $0.hasPrefix("file") && box.read("B/src/" + $0)?.count == 3_000 })
        // Nothing arrives after the job has returned.
        Thread.sleep(forTimeInterval: 0.05)
        #expect(namesOnDisk(box.url("B/src")) == arrived)
    }

    /// Many small files arrive complete from the disk to memory and back again.
    @Test
    internal func manySmallFilesOnDiskArriveCompleteInBothDirections() throws {
        let box = try Sandbox()
        let (fileSystems, memory) = makeFileSystems()
        for index in 0..<200 {
            try box.file(String(format: "A/tree/d%d/f%03d.txt", index % 7, index), "disk \(index)")
        }
        let onDisk = Replies()
            .run(
                .copy,
                [box.url("A/tree")],
                to: TargetSpec(directory: box.url("B")),
                fileSystems: fileSystems,
                configure: nil
            )
        #expect(onDisk.completed.count == 1)
        memory.addDirectory("/in")
        let toMemory = Replies()
            .run(
                .copy,
                [box.url("B/tree")],
                to: TargetSpec(directory: memory.url("/in")),
                fileSystems: fileSystems,
                configure: nil
            )
        #expect(toMemory.completed.count == 1 && memory.allPaths.count == 1 + 1 + 7 + 200)
        let back = Replies()
            .run(
                .move,
                [memory.url("/in/tree")],
                to: TargetSpec(directory: box.url("C")),
                fileSystems: fileSystems,
                configure: nil
            )
        #expect(back.completed.count == 1 && memory.allPaths == ["/in"])
        for index in 0..<200 {
            #expect(box.read(String(format: "C/tree/d%d/f%03d.txt", index % 7, index)) == "disk \(index)")
        }
        #expect(namesOnDisk(box.url("C/tree/d3")).allSatisfy { $0.hasPrefix("f") })
    }

    /// An error in a worker is asked about like any other, and Abort stops every worker.
    @Test
    internal func anErrorInAWorkerAsksLikeAnyOtherAndAbortStopsEverything() {
        let (fileSystems, wrapped) = makeWrappedFileSystems()
        fill(wrapped.base)
        wrapped.base.addDirectory("/dst")
        wrapped.corruptsWrites = true
        wrapped.base.refusesInternalCopy = true
        let replies = Replies()
        replies.failure = .abort
        let result = replies.run(
            .copy,
            [wrapped.base.url("/src")],
            to: TargetSpec(directory: wrapped.base.url("/dst")),
            fileSystems: fileSystems
        ) { $0.options.verifies = true }
        #expect(result.cancelled && replies.errors.count == 1)
        #expect(!wrapped.base.allPaths.contains { $0.hasPrefix("/dst/src/") && !$0.hasSuffix("/sub") })
    }
}
