import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import DirectorySyncPlugin

/// Review round 2: the comparison must not pair names it cannot tell apart, must keep dates exact
/// where the file systems do, and the run must leave no temporary file behind.
@MainActor
@Suite
internal struct Review2DirectorySyncEngine {
    /// The folders of the tests.
    internal let memory = MemoryFileSystem()
    /// The kernel whose file systems the comparisons and runs go through.
    internal let bench: TestBench
    /// An old date for the files.
    internal let early = Date(timeIntervalSince1970: 1_000_000)

    /// A bench with the local and the memory file system.
    internal init() {
        memory.addDirectory("/A")
        memory.addDirectory("/B")
        bench = TestBench(
            plugins: [],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: MemorySettings()
        )
    }

    /// The rows of a comparison of two folders of the memory file system.
    private func rows(_ left: String, _ right: String, options: SyncOptions) -> [SyncRow] {
        SyncComparison(options: options, fileSystems: bench.kernel.fileSystems)
            .run(left: memory.url(left), right: memory.url(right))
            .rows
    }

    /// A name that differs only in case from one paired with its twin is not paired with another name.
    @Test
    internal func namesThatDifferOnlyInCaseAreNotPairedWithAnotherName() {
        let left = ["a.txt", "A.txt"]
            .map { name in
                FileItem(url: URL(fileURLWithPath: "/L/\(name)"), name: name)
            }
        let right = ["a.txt"].map { name in FileItem(url: URL(fileURLWithPath: "/R/\(name)"), name: name) }
        let pairs = SyncComparison.pair(left, right)
        #expect(pairs.count == 2)
        let single = pairs.first { pair in pair.right == nil }
        #expect(single?.left?.name == "A.txt" && single?.collides == true)
        let other = SyncComparison.pair(right, left).first { pair in pair.left == nil }
        #expect(other?.collides == true)
        // A name alone on its side, with no twin, is still just "only here".
        #expect(SyncComparison.pair(left, [])[0].collides == false)
    }

    /// Colliding names are rows that are never synchronized.
    @Test
    internal func collidingNamesAreExcludedRows() {
        memory.addFile("/C/a.txt", "x", modified: early)
        memory.addFile("/C/A.txt", "y", modified: early)
        memory.addFile("/D/a.txt", "x", modified: early)
        let found = rows("/C", "/D", options: SyncOptions()).sorted { first, second in first.name < second.name }
        #expect(found.map(\.name) == ["A.txt", "a.txt"])
        #expect(found[0].state == .excluded && found[0].action == .nothing)
        #expect(found[1].state == .equal)
    }

    /// Dates two seconds apart are equal on a file system that may round them.
    @Test
    internal func datesAreComparedExactlyOnlyWhereBothSidesKeepThemExactly() {
        memory.addFile("/T/a.txt", "x", modified: early)
        memory.addFile("/U/a.txt", "x", modified: early.addingTimeInterval(2))
        // The memory file system is no APFS: the two-second tolerance applies.
        let tolerant = SyncComparison(options: SyncOptions(), fileSystems: bench.kernel.fileSystems)
            .run(left: memory.url("/T"), right: memory.url("/U"))
        #expect(tolerant.toleranceSeconds == 3 && tolerant.rows.first?.state == .equal)
        #expect(
            SyncComparison.needsTolerance(memory.url("/T"), memory.url("/U"), fileSystems: bench.kernel.fileSystems)
        )
    }

    /// On a local volume that keeps exact dates, two seconds are a difference.
    @Test
    internal func aLocalApfsPairKeepsNoTolerance() throws {
        let box = try Sandbox()
        try box.file("L/a.txt", "x", modified: early)
        try box.file("R/a.txt", "x", modified: early.addingTimeInterval(2))
        let registry = bench.kernel.fileSystems
        let result = SyncComparison(options: SyncOptions(), fileSystems: registry)
            .run(left: box.url("L"), right: box.url("R"))
        // On a volume that keeps exact dates (APFS, HFS+) two seconds are a difference.
        if !SyncComparison.needsTolerance(box.url("L"), box.url("R"), fileSystems: registry) {
            #expect(result.toleranceSeconds == 0 && result.rows.first?.state == .rightNewer)
        } else {
            #expect(result.toleranceSeconds == 3)
        }
    }

    /// The copies carry dates moved by the time offset, so that the pair compares equal next time.
    @Test
    internal func timeOffsetsAreAppliedToTheCopiedDates() {
        var options = SyncOptions()
        options.timeOffsetHours = 2
        memory.addFile("/V/a.txt", "new", modified: early.addingTimeInterval(10_000))
        memory.addFile("/W/b.txt", "right", modified: early.addingTimeInterval(20_000))
        let plan = SyncPlan(rows: rows("/V", "/W", options: options), timeOffsetHours: 2)
        #expect(plan.toRight[0].targetModified == plan.toRight[0].modified.addingTimeInterval(-7_200))
        #expect(plan.toLeft[0].targetModified == plan.toLeft[0].modified.addingTimeInterval(7_200))
    }

    /// A new file on a file system that keeps writes back is written under a temporary name and committed.
    @Test
    internal func aNewFileOnAFileSystemThatKeepsWritesBackIsWrittenAsATemporaryFirst() {
        memory.capabilities = [.write, .deferredWrites]
        memory.refusesInternalCopy = true
        memory.addFile("/L/new.txt", "fresh", modified: early.addingTimeInterval(500))
        memory.addDirectory("/R")
        let outcome = SyncExecutor(
            plan: SyncPlan(rows: rows("/L", "/R", options: SyncOptions())),
            options: SyncRunOptions(),
            fileSystems: bench.kernel.fileSystems
        )
        .run()
        #expect(outcome.errors.isEmpty && outcome.copied == 1 && memory.contents("/R/new.txt") == "fresh")
        #expect(memory.allPaths.allSatisfy { path in !path.contains("afm-sync") })
        #expect(!memory.commits.isEmpty)
    }

    /// A copy cancelled once its temporary is complete leaves no temporary behind.
    @Test
    internal func aCancelledCopyLeavesNoTemporaryBehind() {
        memory.addFile("/L/f.bin", "new content", modified: early.addingTimeInterval(500))
        memory.addFile("/R/f.bin", "old", modified: early)
        let flag = CancellationFlag()
        var run = SyncRunOptions()
        run.confirmOverwrites = false
        let executor = SyncExecutor(
            plan: SyncPlan(rows: rows("/L", "/R", options: SyncOptions())),
            options: run,
            fileSystems: bench.kernel.fileSystems,
            cancellation: flag
        )
        // The cancel arrives once the copy to the temporary is complete: the first progress report after the transfer.
        var reports = 0
        executor.onProgress = { _ in
            reports += 1
            if reports == 3 {
                flag.cancel()
            }
        }
        let outcome = executor.run()
        #expect(memory.allPaths.allSatisfy { path in !path.contains("afm-sync") })
        #expect(outcome.copied == 0 || memory.contents("/R/f.bin") == "new content")
    }

    /// A folder whose listing the cancel cut short is not taken for empty and not deleted.
    @Test
    internal func aListingCutShortByTheCancelIsNotAnEmptyFolder() {
        memory.addFile("/R/keep/inside.txt", "mine")
        let flag = CancellationFlag()
        flag.cancel()
        var plan = SyncPlan(rows: [])
        plan.deleteRight = [SyncPlan.Deletion(url: memory.url("/R/keep"), isDirectory: true)]
        var run = SyncRunOptions()
        run.useTrash = false
        let executor = SyncExecutor(plan: plan, options: run, fileSystems: bench.kernel.fileSystems, cancellation: flag)
        _ = executor.run()
        #expect(memory.exists("/R/keep/inside.txt"))
    }

    /// The layout of a list is a pure function of the rows: sorted by their keys, ties by position.
    @Test
    internal func aLargeListIsLaidOutByKeysAndTheSameWayEveryTime() {
        var items: [SyncRow] = []
        for index in 0..<50 {
            let item = FileItem(
                url: URL(fileURLWithPath: "/L/f\(index).txt"),
                name: "f\(index).txt",
                stat: .init(size: Int64((index * 7) % 5), modified: early.addingTimeInterval(Double(index % 3)))
            )
            items.append(
                SyncRow(
                    directory: "",
                    isDirectory: false,
                    left: item,
                    right: nil,
                    leftDirectory: URL(fileURLWithPath: "/L"),
                    rightDirectory: URL(fileURLWithPath: "/R"),
                    state: .leftOnly,
                    asymmetric: false
                )
            )
        }
        let layout = SyncSession.layout(
            rows: items,
            show: .all,
            sort: SyncSort(key: .size, side: .left, ascending: true)
        )
        let sizes = layout.entries.compactMap { entry -> Int64? in
            if case .row(let index) = entry {
                return items[index].left?.size
            }
            return nil
        }
        #expect(sizes == sizes.sorted() && sizes.count == 50)
        let descending = SyncSession.layout(
            rows: items,
            show: .all,
            sort: SyncSort(key: .size, side: .left, ascending: false)
        )
        #expect(descending.entries.count == 50 && layout.actionableCount == 50 && layout.summary.uniqueLeft == 50)
    }
}
