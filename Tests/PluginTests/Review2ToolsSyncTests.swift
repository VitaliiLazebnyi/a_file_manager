import AFMContracts
import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import DirectorySyncPlugin

/// Review round 2: Synchronize directories must not delete a target because its source looks
/// empty, must say what went wrong, and must not pair names it cannot tell apart.
@MainActor @Suite struct Review2DirectorySync {
    let memory = MemoryFileSystem()
    let plugin = DirectorySyncPlugin(opensWindows: false)
    let settings = MemorySettings()
    let bench: TestBench
    let early = Date(timeIntervalSince1970: 1_000_000)
    var ui: ScriptedInteraction { bench.ui }

    init() {
        memory.addDirectory("/A")
        memory.addFile("/B/one.txt", "one", modified: early)
        memory.addFile("/B/two.txt", "two", modified: early)
        memory.addFile("/B/sub/three.txt", "three", modified: early)
        bench = TestBench(
            plugins: [plugin], fileSystems: [LocalFileSystem(), memory], left: memory.url("/A"),
            right: memory.url("/B"), settings: settings)
    }

    func opened(asymmetric: Bool = true, _ configure: (SyncSession) -> Void = { _ in }) -> SyncSession {
        bench.commands.perform(.synchronizeDirectories)
        let session = plugin.session!
        session.options.asymmetric = asymmetric
        configure(session)
        session.compare()
        return session
    }

    func checkbox(_ key: String) -> Bool? {
        for field in ui.forms.last ?? [] where field.key == key {
            if case .checkbox(let isOn) = field.kind { return isOn }
        }
        return nil
    }

    @Test func aMirrorOfAnEmptySourceWarnsAndLeavesTheDeletionUnticked() {
        let session = opened()
        #expect(session.sourceLooksEmpty && ui.log.contains("inform: The left directory is empty."))
        ui.formAnswers = [.accept]
        session.synchronize()
        // The line names the folder, and its box is off: accepting the dialog as it stands deletes nothing.
        #expect(ui.forms.last?.contains { $0.label == "Right: Delete 3 file(s) in mem:/B" } == true)
        #expect(checkbox("deleteRight") == false)
        #expect(memory.exists("/B/one.txt") && memory.exists("/B/two.txt") && memory.exists("/B/sub/three.txt"))
    }

    @Test func theDeletionRunsWhenTheUserTicksIt() {
        let session = opened()
        ui.formAnswers = [.values(["deleteRight": .flag(true), "confirm": .flag(false), "direct": .flag(true)])]
        session.synchronize()
        #expect(!memory.exists("/B/one.txt") && !memory.exists("/B/two.txt"))
    }

    @Test func anOrdinaryMirrorStillProposesTheDeletionTicked() {
        memory.addFile("/A/one.txt", "one", modified: early)
        let session = opened()
        #expect(!session.sourceLooksEmpty)
        ui.formAnswers = [.accept]
        session.synchronize()
        #expect(checkbox("deleteRight") == true)
    }

    @Test func aTwoWaySyncOfAnEmptySideIsNotAMirror() {
        let session = opened(asymmetric: false)
        #expect(!session.sourceLooksEmpty)
    }

    @Test func namesThatDifferOnlyInCaseAreNotPairedWithAnotherName() {
        let left = ["a.txt", "A.txt"].map {
            FileItem(url: URL(fileURLWithPath: "/L/\($0)"), name: $0, isDirectory: false)
        }
        let right = ["a.txt"].map { FileItem(url: URL(fileURLWithPath: "/R/\($0)"), name: $0, isDirectory: false) }
        let pairs = SyncComparison.pair(left, right)
        #expect(pairs.count == 2)
        let single = pairs.first { $0.right == nil }
        #expect(single?.left?.name == "A.txt" && single?.collides == true)
        let other = SyncComparison.pair(right, left).first { $0.left == nil }
        #expect(other?.collides == true)
        // A name alone on its side, with no twin, is still just "only here".
        #expect(SyncComparison.pair(left, [])[0].collides == false)
    }

    @Test func collidingNamesAreExcludedRows() {
        memory.addFile("/C/a.txt", "x", modified: early)
        memory.addFile("/C/A.txt", "y", modified: early)
        memory.addFile("/D/a.txt", "x", modified: early)
        let result = SyncComparison(options: SyncOptions(), fileSystems: bench.kernel.fileSystems).run(
            left: memory.url("/C"), right: memory.url("/D"))
        let rows = result.rows.sorted { $0.name < $1.name }
        #expect(rows.map(\.name) == ["A.txt", "a.txt"])
        #expect(rows[0].state == .excluded && rows[0].action == .none)
        #expect(rows[1].state == .equal)
    }

    @Test func datesAreComparedExactlyOnlyWhereBothSidesKeepThemExactly() {
        let a = memory.addFile("/T/a.txt", "x", modified: early)
        _ = a
        memory.addFile("/U/a.txt", "x", modified: early.addingTimeInterval(2))
        // The memory file system is no APFS: the two-second tolerance applies.
        let tolerant = SyncComparison(options: SyncOptions(), fileSystems: bench.kernel.fileSystems).run(
            left: memory.url("/T"), right: memory.url("/U"))
        #expect(tolerant.toleranceSeconds == 3 && tolerant.rows.first?.state == .equal)
        #expect(
            SyncComparison.needsTolerance(memory.url("/T"), memory.url("/U"), fileSystems: bench.kernel.fileSystems))
    }

    @Test func aLocalApfsPairKeepsNoTolerance() throws {
        let box = try Sandbox()
        try box.file("L/a.txt", "x", modified: early)
        try box.file("R/a.txt", "x", modified: early.addingTimeInterval(2))
        let registry = bench.kernel.fileSystems
        let result = SyncComparison(options: SyncOptions(), fileSystems: registry).run(
            left: box.url("L"), right: box.url("R"))
        // On a volume that keeps exact dates (APFS, HFS+) two seconds are a difference.
        if !SyncComparison.needsTolerance(box.url("L"), box.url("R"), fileSystems: registry) {
            #expect(result.toleranceSeconds == 0 && result.rows.first?.state == .rightNewer)
        } else {
            #expect(result.toleranceSeconds == 3)
        }
    }

    @Test func timeOffsetsAreAppliedToTheCopiedDates() {
        var options = SyncOptions()
        options.timeOffsetHours = 2
        memory.addFile("/V/a.txt", "new", modified: early.addingTimeInterval(10_000))
        memory.addFile("/W/b.txt", "right", modified: early.addingTimeInterval(20_000))
        let rows = SyncComparison(options: options, fileSystems: bench.kernel.fileSystems).run(
            left: memory.url("/V"), right: memory.url("/W")
        ).rows
        let plan = SyncPlan(rows: rows, timeOffsetHours: 2)
        #expect(plan.toRight[0].targetModified == plan.toRight[0].modified.addingTimeInterval(-7200))
        #expect(plan.toLeft[0].targetModified == plan.toLeft[0].modified.addingTimeInterval(7200))
    }

    @Test func aFailedCommitIsSaidAndNothingIsDeleted() {
        struct Refused: Error {}
        memory.capabilities = [.write, .deferredWrites]
        memory.commitFailure = Refused()
        memory.addFile("/A/new.txt", "fresh", modified: early.addingTimeInterval(100))
        memory.addFile("/B/extra.txt", "only right", modified: early)
        let session = opened()
        ui.formAnswers = [.values(["confirm": .flag(false), "direct": .flag(true)])]
        session.synchronize()
        #expect(ui.log.contains("inform: Synchronize did not finish without errors."))
        #expect(memory.exists("/B/extra.txt"))
    }

    @Test func errorsAfterSkipAllAreSummarised() {
        memory.addFile("/A/x1.txt", "1", modified: early.addingTimeInterval(100))
        memory.addFile("/A/x2.txt", "2", modified: early.addingTimeInterval(100))
        let session = opened(asymmetric: false)
        memory.removeTree("/A/x1.txt")
        memory.removeTree("/A/x2.txt")
        ui.formAnswers = [.values(["confirm": .flag(false)])]
        ui.choiceAnswers = [1]  // Skip All
        session.synchronize()
        #expect(ui.log.contains("inform: Synchronize did not finish without errors."))
    }

    @Test func loadingASetOrAdoptingDuringAComparisonDropsTheOldRun() {
        let session = opened()
        session.saveSet(named: "mine")
        // The state is cleared and a running comparison would be cancelled; nothing stale arrives later.
        #expect(session.loadSet(named: "mine"))
        #expect(session.phase == .idle && session.rows.isEmpty)
    }

    @Test func aNewFileOnAFileSystemThatKeepsWritesBackIsWrittenAsATemporaryFirst() {
        memory.capabilities = [.write, .deferredWrites]
        memory.refusesInternalCopy = true
        memory.addFile("/L/new.txt", "fresh", modified: early.addingTimeInterval(500))
        memory.addDirectory("/R")
        let rows = SyncComparison(options: SyncOptions(), fileSystems: bench.kernel.fileSystems).run(
            left: memory.url("/L"), right: memory.url("/R")
        ).rows
        let outcome = SyncExecutor(
            plan: SyncPlan(rows: rows), options: SyncRunOptions(), fileSystems: bench.kernel.fileSystems
        ).run()
        #expect(outcome.errors.isEmpty && outcome.copied == 1 && memory.contents("/R/new.txt") == "fresh")
        #expect(memory.allPaths.allSatisfy { !$0.contains("afm-sync") })
        #expect(!memory.commits.isEmpty)
    }

    @Test func aCancelledCopyLeavesNoTemporaryBehind() {
        memory.addFile("/L/f.bin", "new content", modified: early.addingTimeInterval(500))
        memory.addFile("/R/f.bin", "old", modified: early)
        let rows = SyncComparison(options: SyncOptions(), fileSystems: bench.kernel.fileSystems).run(
            left: memory.url("/L"), right: memory.url("/R")
        ).rows
        let flag = CancellationFlag()
        let executor = SyncExecutor(
            plan: SyncPlan(rows: rows),
            options: {
                var o = SyncRunOptions()
                o.confirmOverwrites = false
                return o
            }(),
            fileSystems: bench.kernel.fileSystems, cancellation: flag)
        // The cancel arrives once the copy to the temporary is complete: the first progress report after the transfer.
        var reports = 0
        executor.onProgress = { _ in
            reports += 1
            if reports == 3 { flag.cancel() }
        }
        let outcome = executor.run()
        #expect(memory.allPaths.allSatisfy { !$0.contains("afm-sync") })
        #expect(outcome.copied == 0 || memory.contents("/R/f.bin") == "new content")
    }

    @Test func aListingCutShortByTheCancelIsNotAnEmptyFolder() {
        memory.addFile("/R/keep/inside.txt", "mine")
        let flag = CancellationFlag()
        flag.cancel()
        var plan = SyncPlan(rows: [])
        plan.deleteRight = [SyncPlan.Deletion(url: memory.url("/R/keep"), isDirectory: true)]
        let executor = SyncExecutor(
            plan: plan,
            options: {
                var o = SyncRunOptions()
                o.useTrash = false
                return o
            }(), fileSystems: bench.kernel.fileSystems, cancellation: flag)
        _ = executor.run()
        #expect(memory.exists("/R/keep/inside.txt"))
    }

    @Test func aLargeListIsLaidOutByKeysAndTheSameWayEveryTime() {
        // The layout is a pure function of the rows: sorted by extracted keys, ties by position.
        var items: [SyncRow] = []
        for index in 0..<50 {
            let item = FileItem(
                url: URL(fileURLWithPath: "/L/f\(index).txt"), name: "f\(index).txt", isDirectory: false,
                size: Int64((index * 7) % 5),
                modified: early.addingTimeInterval(Double(index % 3)))
            items.append(
                SyncRow(
                    directory: "", isDirectory: false, left: item, right: nil,
                    leftDirectory: URL(fileURLWithPath: "/L"),
                    rightDirectory: URL(fileURLWithPath: "/R"), state: .leftOnly, asymmetric: false))
        }
        let layout = SyncSession.layout(rows: items, show: .all, sort: (.size, .left, true))
        let sizes = layout.entries.compactMap { entry -> Int64? in
            if case .row(let index) = entry { return items[index].left?.size }
            return nil
        }
        #expect(sizes == sizes.sorted() && sizes.count == 50)
        let descending = SyncSession.layout(rows: items, show: .all, sort: (.size, .left, false))
        #expect(descending.entries.count == 50 && layout.actionableCount == 50 && layout.summary.uniqueLeft == 50)
    }
}
