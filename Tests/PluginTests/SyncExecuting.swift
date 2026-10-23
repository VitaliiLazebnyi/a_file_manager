import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import DirectorySyncPlugin

/// Planning and carrying out (spec 09 › The "Synchronize" dialog and the run): the plan, both
/// directions, and the user's say on overwrites and failures.
@Suite
internal struct SyncExecuting {
    /// The trees and their file systems.
    private let fixture = SyncRunFixture()

    /// The trees.
    private var memory: MemoryFileSystem { fixture.memory }
    /// The local and the memory file system.
    private var fileSystems: FileSystemRegistry { fixture.fileSystems }
    /// The date the files are dated from.
    private var early: Date { SyncRunFixture.early }

    /// The plan holds what the rows ask for, and nothing a row cannot do.
    @Test
    internal func planCountsWhatTheRowsAsk() {
        let plan = SyncPlan(rows: fixture.rows())
        #expect(plan.toRight.map(\.relativePath) == ["new.txt", "update.txt"])
        #expect(plan.toLeft.map(\.relativePath) == ["back.txt", "sub/deep/arrives.txt"])
        #expect(plan.deleteLeft.isEmpty && plan.deleteRight.isEmpty && !plan.isEmpty)
        #expect(SyncPlan.describe(plan.toRight) == "Copy 2 files, total size: 30 bytes")
        #expect(plan.toLeft[1].target.path == "/L/sub/deep/arrives.txt")
        #expect(SyncPlan(rows: fixture.rows().filter { $0.state == .equal }).isEmpty)

        var changed = fixture.rows()
        for index in changed.indices {
            switch changed[index].name {
            case "same.txt":
                changed[index].action = .deleteBoth

            case "new.txt":
                changed[index].action = .deleteLeft

            case "update.txt":
                changed[index].action = .copyToLeft

            // What a row cannot do is not planned.
            case "arrives.txt":
                changed[index].action = .copyToRight

            default:
                changed[index].action = .nothing
            }
        }
        let second = SyncPlan(rows: changed)
        #expect(second.toRight.isEmpty && second.toLeft.map(\.relativePath) == ["update.txt"])
        #expect(
            second.deleteLeft.map(\.url.lastPathComponent) == ["new.txt", "same.txt"]
                && second.deleteRight.map(\.url.lastPathComponent) == ["same.txt"]
        )
    }

    /// Copies in both directions arrive with their dates, right to left first, and the sides are equal after.
    @Test
    internal func bothDirectionsArriveWithTheirDatesAndTheSidesAreEqualAfterwards() {
        var progress: [JobProgress] = []
        let outcome = fixture.run(SyncPlan(rows: fixture.rows())) { $0.onProgress = { progress.append($0) } }
        #expect(outcome.copied == 4 && outcome.skipped == 0 && outcome.errors.isEmpty && !outcome.wasCancelled)
        #expect(
            memory.contents("/R/new.txt") == "from the left" && memory.contents("/R/update.txt") == "newer on the left"
        )
        #expect(
            memory.contents("/L/back.txt") == "newer on the right"
                && memory.contents("/L/sub/deep/arrives.txt") == "from the right"
        )
        #expect(memory.item(at: memory.url("/R/new.txt"))?.modified == early.addingTimeInterval(500))
        #expect(memory.item(at: memory.url("/L/sub/deep/arrives.txt"))?.modified == early.addingTimeInterval(7))
        // No temporary file stays behind.
        #expect(
            memory.allPaths == [
                "/L", "/L/back.txt", "/L/new.txt", "/L/same.txt", "/L/sub", "/L/sub/deep", "/L/sub/deep/arrives.txt",
                "/L/update.txt", "/R", "/R/back.txt", "/R/new.txt", "/R/same.txt", "/R/sub", "/R/sub/deep",
                "/R/sub/deep/arrives.txt", "/R/update.txt"
            ]
        )
        #expect(Set(outcome.changedDirectories.map(\.path)) == ["/L", "/R", "/L/sub/deep"])
        // Right to left runs first (spec 09 › Running it).
        #expect(
            progress.first?.lines.first == "Right -> Left  (1 / 2)"
                && progress.last?.lines.first?.hasPrefix("Left -> Right") == true
        )
        #expect(progress.last?.itemsTotal == 4 && progress.last?.bytesTotal == 62)
        #expect(fixture.rows { $0.byContent = true }.allSatisfy { $0.state == .equal })
    }

    /// Overwrites are confirmed file by file, with Skip All and Overwrite All.
    @Test
    internal func overwritesAreConfirmedPerFile() {
        var asked: [String] = []
        var outcome = fixture.run(SyncPlan(rows: fixture.rows()), confirming: true) { executor in
            executor.onOverwrite = { target, copy in
                asked.append("\(target.name) \(copy.size)")
                return target.name == "back.txt" ? .skip : .overwrite
            }
        }
        #expect(asked == ["back.txt 18", "update.txt 17"])
        #expect(outcome.copied == 3 && outcome.skipped == 1 && memory.contents("/L/back.txt") == "older")

        // "Skip All" leaves every existing target alone but still brings the new files.
        memory.addFile("/R/update.txt", "older", modified: early)
        memory.removeTree("/R/new.txt")
        outcome = fixture.run(SyncPlan(rows: fixture.rows()), confirming: true) { executor in
            executor.onOverwrite = { _, _ in .skipAll }
        }
        #expect(
            outcome.copied == 1 && outcome.skipped == 2 && memory.contents("/R/update.txt") == "older"
                && memory.exists("/R/new.txt")
        )

        asked = []
        outcome = fixture.run(SyncPlan(rows: fixture.rows()), confirming: true) { executor in
            executor.onOverwrite = { target, _ in
                asked.append(target.name)
                return .overwriteAll
            }
        }
        #expect(asked == ["back.txt"] && outcome.copied == 2 && memory.contents("/R/update.txt") == "newer on the left")
    }

    /// Cancelling at a question, or before the run, stops it.
    @Test
    internal func cancellingAtAQuestionStopsTheRun() {
        let outcome = fixture.run(SyncPlan(rows: fixture.rows()), confirming: true) { executor in
            executor.onOverwrite = { _, _ in .cancel }
        }
        #expect(outcome.wasCancelled && outcome.copied == 0)
        #expect(memory.contents("/L/back.txt") == "older" && !memory.exists("/R/new.txt") && !memory.exists("/L/sub"))

        let flag = CancellationFlag()
        flag.cancel()
        let second = SyncExecutor(
            plan: SyncPlan(rows: fixture.rows()),
            options: SyncRunOptions(),
            fileSystems: fileSystems,
            cancellation: flag
        )
        .run()
        #expect(second.wasCancelled && second.copied == 0)
    }

    /// A failure can be skipped, tried again or end the run.
    @Test
    internal func errorsCanBeSkippedRetriedOrEndTheRun() {
        let plan = SyncPlan(rows: fixture.rows())
        memory.removeTree("/L/new.txt")
        memory.removeTree("/R/back.txt")
        var failed: [String] = []
        var outcome = fixture.run(plan) { executor in
            executor.onError = { url, _ in
                failed.append(url.lastPathComponent)
                return .skip
            }
        }
        #expect(
            failed == ["back.txt", "new.txt"] && outcome.errors.count == 2 && outcome.skipped == 2
                && outcome.copied == 2
        )
        #expect(memory.contents("/L/back.txt") == "older" && memory.contents("/R/update.txt") == "newer on the left")

        // Retry after the cause has gone.
        memory.addFile("/R/update.txt", "older", modified: early)
        outcome = fixture.run(plan) { executor in
            executor.onError = { url, _ in
                if url.lastPathComponent == "new.txt" { memory.addFile("/L/new.txt", "back again") }
                return url.lastPathComponent == "new.txt" ? .retry : .skip
            }
        }
        #expect(outcome.errors.count == 1 && memory.contents("/R/new.txt") == "back again")

        memory.removeTree("/R/new.txt")
        memory.removeTree("/L/new.txt")
        memory.addFile("/R/update.txt", "older", modified: early)
        outcome = fixture.run(plan) { $0.onError = { _, _ in .cancel } }
        #expect(outcome.wasCancelled && memory.contents("/R/update.txt") == "older")
    }
}
