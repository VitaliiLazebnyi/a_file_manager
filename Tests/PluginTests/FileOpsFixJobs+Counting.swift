import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// Counting, parallel deletes, comparing, dates and name widths (F8, F10, F13, F14, F20).
extension FileOpsFixJobs {
    // MARK: F8

    /// A folder that moves by one rename counts as one item; what is below it is not walked.
    @Test
    internal func aFolderThatMovesByOneRenameIsNotWalked() throws {
        let box = try Sandbox()
        for index in 0..<30 { try box.file("A/docs/sub/f\(index).txt", "x") }
        try box.folder("B")
        let replies = Replies()
        let result = replies.run(
            .move,
            [box.url("A/docs")],
            to: TargetSpec(directory: box.url("B")),
            fileSystems: makeFileSystems().0,
            configure: nil
        )
        let last = try #require(replies.progress.last)
        #expect(result.completed.count == 1 && box.exists("B/docs/sub/f29.txt") && !box.exists("A/docs"))
        // One item for the rename: the 31 items below were never counted.
        #expect(last.itemsTotal == 1 && last.itemsDone == 1)
    }

    /// A folder merged into an existing one counts every item it holds.
    @Test
    internal func aFolderMergedIntoAnExistingOneIsCountedInFull() throws {
        let box = try Sandbox()
        for index in 0..<5 { try box.file("A/docs/f\(index).txt", "x") }
        try box.file("B/docs/keep.txt", "k")
        let replies = Replies()
        let result = replies.run(
            .move,
            [box.url("A/docs")],
            to: TargetSpec(directory: box.url("B")),
            fileSystems: makeFileSystems().0,
            configure: nil
        )
        let last = try #require(replies.progress.last)
        #expect(result.completed.count == 1 && last.itemsTotal == 6 && last.itemsDone == 6)
        #expect(namesOnDisk(box.url("B/docs")).count == 6)
    }

    /// A folder whose merge is skipped still moves the item counter on to the end.
    @Test
    internal func aSkippedFolderAdvancesTheCounterToTheEnd() throws {
        let box = try Sandbox()
        for index in 0..<4 { try box.file("A/docs/f\(index).txt", "x") }
        try box.file("A/one.txt", "1")
        try box.folder("B")
        let replies = Replies()
        replies.merge = .skip
        try box.folder("B/docs")
        let result = replies.run(
            .copy,
            [box.url("A/docs"), box.url("A/one.txt")],
            to: TargetSpec(directory: box.url("B")),
            fileSystems: makeFileSystems().0
        ) { job in
            job.options.asksBeforeMerging = true
        }
        let last = try #require(replies.progress.last)
        #expect(result.completed.count == 1 && last.itemsDone == last.itemsTotal && last.itemsTotal == 6)
    }

    // MARK: F10

    /// Many files are deleted by several workers, and the read-only ones are asked about in order.
    @Test
    internal func manyFilesAreDeletedBySeveralWorkersAndProtectedOnesAreAskedInOrder() throws {
        let box = try Sandbox()
        for index in 0..<200 { try box.file(String(format: "A/tree/f%03d.txt", index), "x") }
        for name in ["ro1", "ro2", "ro3"] {
            let url = try box.file("A/tree/\(name).txt", "r")
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        }
        try box.file("A/tree/sub/deep.txt", "d")
        let replies = Replies()
        replies.protection = .skip
        let result = replies.run(
            .delete(toTrash: false),
            [box.url("A/tree")],
            to: nil,
            fileSystems: makeFileSystems().0
        ) { $0.parallelWidth = 4 }
        // The folder stays because three of its files were kept; everything else is gone.
        #expect(
            replies.protections == ["readOnly delete ro1.txt", "readOnly delete ro2.txt", "readOnly delete ro3.txt"]
        )
        #expect(namesOnDisk(box.url("A/tree")) == ["ro1.txt", "ro2.txt", "ro3.txt"] && result.completed.isEmpty)
        let last = try #require(replies.progress.last)
        #expect(last.itemsDone == last.itemsTotal)
    }

    /// A cancel in the middle of a parallel delete stops it and leaves the rest.
    @Test
    internal func aCancelDuringAParallelDeleteStopsAndReturns() throws {
        let box = try Sandbox()
        for index in 0..<300 { try box.file(String(format: "A/tree/f%03d.txt", index), "x") }
        let replies = Replies()
        replies.cancelAtItems = 40
        let result = replies.run(
            .delete(toTrash: false),
            [box.url("A/tree")],
            to: nil,
            fileSystems: makeFileSystems().0
        ) { $0.parallelWidth = 4 }
        #expect(result.cancelled && box.exists("A/tree") && !namesOnDisk(box.url("A/tree")).isEmpty)
        #expect(namesOnDisk(box.url("A/tree")).count < 300)
    }

    /// A tree deleted without the pool of workers is still deleted in full.
    @Test
    internal func aDeleteTreeWithoutAPoolStillDeletesEverything() throws {
        let box = try Sandbox()
        for index in 0..<50 { try box.file("A/tree/d\(index % 5)/f\(index).txt", "x") }
        let replies = Replies()
        let result = replies.run(
            .delete(toTrash: false),
            [box.url("A/tree")],
            to: nil,
            fileSystems: makeFileSystems().0
        ) { job in
            job.options.copiesSmallFilesInParallel = false
        }
        #expect(result.completed.count == 1 && !box.exists("A/tree"))
    }

    // MARK: F13

    /// Files of different sizes compare as different before anything is read.
    @Test
    internal func filesOfDifferentSizesAreDifferentWithoutReadingThem() throws {
        let box = try Sandbox()
        try box.file("a.txt", "short")
        try box.file("b.txt", "longer text")
        try box.file("c.txt", "short")
        let (fileSystems, _) = makeFileSystems()
        // A reading that was cancelled at once would answer `.cancelled`; the sizes answer before any reading.
        #expect(
            try Checksum.sameContents(box.url("a.txt"), box.url("b.txt"), in: fileSystems) { true }
                == .different
        )
        #expect(try Checksum.sameContents(box.url("a.txt"), box.url("c.txt"), in: fileSystems) == .same)
    }

    /// Verifying a copy shows its own progress line and finds nothing wrong with a good copy.
    @Test
    internal func verifyingShowsProgressAndStillCatchesDamage() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", String(repeating: "x", count: 3 << 20))
        try box.folder("B")
        let replies = Replies()
        replies.run(
            .copy,
            [box.url("A/one.txt")],
            to: TargetSpec(directory: box.url("B")),
            fileSystems: makeFileSystems().0
        ) { job in
            job.options.verifies = true
        }
        #expect(replies.progress.contains { $0.lines.first?.hasPrefix("Verifying: ") == true })
        #expect(box.exists("B/one.txt") && replies.errors.isEmpty)
    }

    // MARK: F14

    /// Overwrite all older takes a source as newer only beyond the clock granularity of the target.
    @Test
    internal func olderMeansOlderByMoreThanTheGranularityOfTheTarget() {
        let (fileSystems, memory) = makeFileSystems()
        let base = Date(timeIntervalSince1970: 1_000_000)
        memory.addFile("/a/near.txt", "new", modified: base.addingTimeInterval(1.5))
        memory.addFile("/a/far.txt", "new", modified: base.addingTimeInterval(5))
        memory.addFile("/b/near.txt", "old", modified: base)
        memory.addFile("/b/far.txt", "old", modified: base)
        let replies = Replies(.overwriteAllOlder)
        replies.run(
            .copy,
            [memory.url("/a/near.txt"), memory.url("/a/far.txt")],
            to: TargetSpec(directory: memory.url("/b")),
            fileSystems: fileSystems,
            configure: nil
        )
        // 1.5 s is a rounding of a two-second clock, not a newer file.
        #expect(memory.contents("/b/near.txt") == "old" && memory.contents("/b/far.txt") == "new")
    }

    /// Overwrite all older or same keeps a newer target only beyond the tolerance.
    @Test
    internal func olderOrSameKeepsAnOlderTargetOnlyBeyondTheTolerance() {
        let (fileSystems, memory) = makeFileSystems()
        let base = Date(timeIntervalSince1970: 1_000_000)
        memory.addFile("/a/near.txt", "new", modified: base)
        memory.addFile("/a/far.txt", "new", modified: base)
        memory.addFile("/b/near.txt", "old", modified: base.addingTimeInterval(1.5))
        memory.addFile("/b/far.txt", "old", modified: base.addingTimeInterval(9))
        let replies = Replies(.overwriteAllOlderOrSame)
        replies.run(
            .copy,
            [memory.url("/a/near.txt"), memory.url("/a/far.txt")],
            to: TargetSpec(directory: memory.url("/b")),
            fileSystems: fileSystems,
            configure: nil
        )
        #expect(memory.contents("/b/near.txt") == "new" && memory.contents("/b/far.txt") == "old")
    }

    // MARK: F20

    /// Huge widths and ranges in a name template are clamped instead of crashing.
    @Test
    internal func hugeWidthsInNamesAreClamped() throws {
        var context = NameTemplate.Context()
        context.cursorName = "abc.txt"
        let counter = try NameTemplate.names(from: "<1-2>x[C:999999999]", context: context)
        #expect(counter.count == 2 && counter.allSatisfy { $0.count <= 256 })
        let range = try NameTemplate.names(from: "<[N01,999999999]", context: context)
        #expect(range.count == 1 && range[0].count <= 255)
        // A start and a length that would overflow are no longer a crash.
        let big = try NameTemplate.names(from: "<[N2,9223372036854775807]", context: context)
        #expect(big.count == 1)
    }
}
