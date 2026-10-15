import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import DirectorySyncPlugin

/// The run of a plan at the corners the other suites leave: files that cannot be replaced in one
/// step, targets in the way, runs cancelled at every point, folders that cannot go.
@Suite
internal struct CovSyncExecutor {
    private struct Refused: Error {}

    private let fileSystems = FileSystemRegistry()
    private let memory = MemoryFileSystem()
    private let moves = CovSyncMovesFileSystem()
    private let early = Date(timeIntervalSince1970: 1_000_000)

    /// Two memory file systems, for every test.
    internal init() {
        fileSystems.register(memory)
        fileSystems.register(moves)
    }

    /// The plan of the left folder `/L` of `memory` against `right`, with empty folders when `folders`.
    private func plan(to right: URL, folders: Bool = false, from left: URL? = nil) -> SyncPlan {
        var options = SyncOptions()
        options.emptyDirectories = folders
        let comparison = SyncComparison(options: options, fileSystems: fileSystems)
        return SyncPlan(rows: comparison.run(left: left ?? memory.url("/L"), right: right).rows)
    }

    /// Runs `plan` without asking before overwrites, with the executor as it is made.
    private func runAsIs(_ plan: SyncPlan) -> SyncOutcome {
        run(plan, cancellation: CancellationFlag()) { _ in
            // Nothing to prepare.
        }
    }

    /// Runs `plan` without asking before overwrites.
    private func run(
        _ plan: SyncPlan,
        cancellation: CancellationFlag = CancellationFlag(),
        _ prepare: (SyncExecutor) -> Void
    ) -> SyncOutcome {
        var options = SyncRunOptions()
        options.confirmOverwrites = false
        let executor = SyncExecutor(plan: plan, options: options, fileSystems: fileSystems, cancellation: cancellation)
        prepare(executor)
        return executor.run()
    }

    /// The text of a file of `moves`.
    private func text(_ path: String) -> String? {
        guard let reader = try? moves.read(moves.base.url(path)) else {
            return nil
        }
        defer { reader.close() }
        return (try? reader.read(upToCount: 1 << 20)).flatMap { String(bytes: $0, encoding: .utf8) }
    }

    /// Where a replacing move is refused, the old file steps aside under a free name, the new
    /// one takes its place and the old one goes.
    @Test
    internal func aFileIsReplacedInTwoSteps() {
        memory.addFile("/L/a.txt", "new", modified: early.addingTimeInterval(100))
        moves.base.addFile("/R/a.txt", "old", modified: early)
        moves.base.addFile("/R/.a.txt.afm-old", "a leftover", modified: early)
        moves.beforeMoves { _, _, replacing in if replacing { throw Refused() } }
        let outcome = runAsIs(plan(to: moves.base.url("/R")))
        #expect(outcome.copied == 1 && outcome.errors.isEmpty)
        #expect(text("/R/a.txt") == "new" && text("/R/.a.txt.afm-old") == "a leftover")
        #expect(moves.base.item(at: moves.base.url("/R/.a.txt.afm-old-2")) == nil)
    }

    /// When the new file cannot take the old one's place, the old one comes back; when it cannot
    /// come back either, the user is told where it is.
    @Test
    internal func anOldFileThatCannotComeBackIsNamed() {
        memory.addFile("/L/a.txt", "new", modified: early.addingTimeInterval(100))
        moves.base.addFile("/R/a.txt", "old", modified: early)
        moves.beforeMoves { source, _, replacing in
            if replacing || source.lastPathComponent.hasSuffix(".afm-sync") { throw Refused() }
        }
        let first = runAsIs(plan(to: moves.base.url("/R")))
        #expect(first.copied == 0 && first.errors.count == 1 && text("/R/a.txt") == "old")
        moves.beforeMoves { source, _, replacing in
            if replacing || source.lastPathComponent.contains(".afm-") { throw Refused() }
        }
        let second = runAsIs(plan(to: moves.base.url("/R")))
        #expect(second.errors.first?.contains("could not be put back and is kept as") == true)
    }

    /// A folder where a file is to go stops that copy with an error.
    @Test
    internal func aFolderInTheWayIsAnError() throws {
        memory.addFile("/L/a.txt", "new", modified: early.addingTimeInterval(100))
        moves.base.addFile("/R/a.txt", "old", modified: early)
        let plan = plan(to: moves.base.url("/R"))
        try moves.base.remove(moves.base.url("/R/a.txt"))
        _ = moves.base.addDirectory("/R/a.txt")
        let outcome = runAsIs(plan)
        #expect(outcome.copied == 0 && outcome.errors.first?.contains("a.txt") == true)
    }

    /// A run cancelled while a file is copied inside one file system, while one is streamed to
    /// another, and once one was written, stops there and leaves no temporary file.
    @Test
    internal func cancelledCopiesStopAndLeaveNothingBehind() {
        let big = String(repeating: "x", count: 3 << 20)
        memory.addFile("/L/a.txt", big, modified: early.addingTimeInterval(100))
        memory.addFile("/R/a.txt", "old", modified: early)
        for target in [memory.url("/R"), moves.base.url("/R")] {
            moves.base.addFile("/R/a.txt", "old", modified: early)
            let flag = CancellationFlag()
            let outcome = run(plan(to: target), cancellation: flag) { executor in
                executor.onProgress = { progress in if progress.bytesDone > 0 { flag.cancel() } }
            }
            #expect(outcome.wasCancelled && outcome.copied == 0)
        }
        memory.addFile("/L2/b.txt", "small", modified: early.addingTimeInterval(100))
        moves.base.addFile("/R2/b.txt", "older", modified: early)
        let flag = CancellationFlag()
        let written = plan(to: moves.base.url("/R2"), from: memory.url("/L2"))
        let outcome = run(written, cancellation: flag) { executor in
            executor.onProgress = { progress in if progress.bytesDone >= 5 { flag.cancel() } }
        }
        #expect(outcome.wasCancelled && moves.base.item(at: moves.base.url("/R2/.b.txt.afm-sync")) == nil)
    }

    /// A copy inside one file system that cannot be stopped half-way, and a streamed copy over a
    /// file whose last block was written, end as cancelled once they are done.
    @Test
    internal func copiesThatEndAfterTheCancelAreCancelled() {
        moves.base.addFile("/S/a.txt", "content", modified: early.addingTimeInterval(100))
        _ = moves.base.addDirectory("/T")
        let flag = CancellationFlag()
        let inside = run(plan(to: moves.base.url("/T"), from: moves.base.url("/S")), cancellation: flag) { executor in
            executor.onProgress = { progress in if progress.bytesDone > 0 { flag.cancel() } }
        }
        #expect(inside.wasCancelled && inside.copied == 0)
        memory.addFile("/U/a.txt", "older", modified: early)
        let again = CancellationFlag()
        let over = run(plan(to: memory.url("/U"), from: moves.base.url("/S")), cancellation: again) { executor in
            executor.onProgress = { progress in if progress.bytesDone > 0 { again.cancel() } }
        }
        #expect(over.wasCancelled && memory.item(at: memory.url("/U/.a.txt.afm-sync")) == nil)
    }

    /// A read that the cancel does not interrupt stops at the next block; a write that fails is an error.
    @Test
    internal func streamedCopiesStopAtTheNextBlockOrFail() {
        moves.base.addFile("/S/a.txt", String(repeating: "y", count: 3 << 20), modified: early.addingTimeInterval(100))
        _ = memory.addDirectory("/T")
        let flag = CancellationFlag()
        let toMemory = plan(to: memory.url("/T"), from: moves.base.url("/S"))
        let stopped = run(toMemory, cancellation: flag) { executor in
            executor.onProgress = { progress in if progress.bytesDone > 0 { flag.cancel() } }
        }
        #expect(stopped.wasCancelled && memory.item(at: memory.url("/T/a.txt")) == nil)
        memory.addFile("/L3/c.txt", "text", modified: early)
        _ = moves.base.addDirectory("/R3")
        moves.refuseWriting()
        let failed = runAsIs(plan(to: moves.base.url("/R3"), from: memory.url("/L3")))
        #expect(failed.errors.count == 1 && failed.copied == 0)
    }

    /// What a run wrote to a file system that keeps writes back and that cannot make them durable
    /// is no failure when the run was cancelled anyway.
    @Test
    internal func aCommitThatFailsAfterTheCancelIsACancel() {
        memory.addFile("/L/a.txt", "one", modified: early)
        memory.addFile("/L/b.txt", "two", modified: early)
        memory.capabilities.insert(.deferredWrites)
        memory.commitFailure = CocoaError(.fileWriteUnknown)
        _ = memory.addDirectory("/R")
        let flag = CancellationFlag()
        var steps = 0
        let outcome = run(plan(to: memory.url("/R")), cancellation: flag) { executor in
            executor.onProgress = { progress in
                if progress.lines.first?.contains("(2 / 2)") == true, steps == 0 {
                    steps += 1
                    flag.cancel()
                }
            }
        }
        #expect(outcome.wasCancelled && !outcome.commitFailed && outcome.copied == 1)
    }

    /// A target that keeps no date leaves the source's date alone when that may not be changed.
    @Test
    internal func aSourceDateThatMayNotChangeStays() {
        memory.addFile("/L/a.txt", "one", modified: early)
        _ = moves.base.addDirectory("/R")
        moves.loseDates(settable: false)
        var options = SyncRunOptions()
        options.mayChangeSourceDates = false
        let outcome = SyncExecutor(plan: plan(to: moves.base.url("/R")), options: options, fileSystems: fileSystems)
            .run()
        #expect(outcome.copied == 1 && memory.item(at: memory.url("/L/a.txt"))?.modified == early)
    }

    /// A target that loses the date when it is written gets it set afterwards.
    @Test
    internal func aLostDateIsSetAfterwards() {
        memory.addFile("/L/a.txt", "one", modified: early)
        _ = moves.base.addDirectory("/R")
        moves.loseDates(settable: true)
        let outcome = runAsIs(plan(to: moves.base.url("/R")))
        #expect(outcome.copied == 1 && moves.dateSet(at: moves.base.url("/R/a.txt").path) == early)
        #expect(memory.item(at: memory.url("/L/a.txt"))?.modified == early)
    }

    /// Asked before an overwrite, the run overwrites unless told otherwise; deleted files go to
    /// the Trash where there is one.
    @Test
    internal func overwritesAndTheTrash() {
        memory.addFile("/L/a.txt", "new", modified: early.addingTimeInterval(100))
        moves.base.addFile("/R/a.txt", "old", modified: early)
        moves.base.addFile("/R/extra.txt", "gone", modified: early)
        moves.base.capabilities.insert(.trash)
        var plan = plan(to: moves.base.url("/R"))
        plan.toLeft = []
        plan.deleteRight = [SyncPlan.Deletion(url: moves.base.url("/R/extra.txt"), isDirectory: false)]
        let outcome = SyncExecutor(plan: plan, options: SyncRunOptions(), fileSystems: fileSystems).run()
        #expect(outcome.copied == 1 && outcome.deleted == 1, "\(outcome)")
        #expect(moves.base.item(at: moves.base.url("/R/extra.txt")) == nil && text("/R/a.txt") == "new")
    }

    /// A copy whose date arrived within the tolerance is left as it is.
    @Test
    internal func aDateWithinTheToleranceIsKept() {
        memory.addFile("/L/a.txt", "one", modified: early)
        _ = memory.addDirectory("/R")
        var options = SyncRunOptions()
        options.toleranceSeconds = Int.max / 2
        let outcome = SyncExecutor(plan: plan(to: memory.url("/R")), options: options, fileSystems: fileSystems).run()
        #expect(outcome.copied == 1)
    }

    /// Empty folders that cannot be removed stay, and the folder above them with them.
    @Test
    internal func emptyFoldersThatCannotGoStay() {
        _ = memory.addDirectory("/L")
        _ = moves.base.addDirectory("/R/keep/inner")
        _ = moves.base.addDirectory("/R/gone")
        _ = moves.base.addDirectory("/R/locked/below")
        moves.base.unreadable = [moves.base.url("/R/locked").path]
        moves.refuseRemoving([moves.base.url("/R/keep/inner").path])
        var options = SyncRunOptions()
        options.removeEmptyDirectoriesBelow = moves.base.url("/R")
        var plan = SyncPlan(rows: [])
        plan.deleteRight = [SyncPlan.Deletion(url: moves.base.url("/R/none"), isDirectory: false)]
        let outcome = SyncExecutor(plan: plan, options: options, fileSystems: fileSystems).run()
        #expect(moves.base.item(at: moves.base.url("/R/keep/inner")) != nil)
        #expect(moves.base.item(at: moves.base.url("/R/gone")) == nil && outcome.deleted == 1)
    }

    /// The summary names the folders to make; a copy whose path is no plain name has no place in another folder.
    @Test
    internal func describingAndRetargeting() {
        _ = memory.addDirectory("/L/folder")
        _ = memory.addDirectory("/R")
        var plan = plan(to: memory.url("/R"), folders: true)
        #expect(SyncPlan.describe(plan.toRight).hasSuffix(", create 1 directories"))
        let copy = plan.toRight[0]
        plan.toRight.append(
            SyncPlan.Copy(
                source: copy.source,
                target: copy.target,
                relativePath: "../x",
                isDirectory: false,
                size: 1,
                modified: early,
                targetModified: early,
                permissions: 0o644
            )
        )
        plan.retarget(toRight: true, root: memory.url("/Other"))
        #expect(plan.toRight.map(\.relativePath) == ["folder"])
    }
}
