import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import CompareContentPlugin
@testable import DirectorySyncPlugin

/// The Synchronize directories session at the corners the other suites leave: comparisons and
/// lists made away from the main thread, what a run does not allow, and what is told afterwards.
@MainActor
@Suite
internal struct CovSyncSession {
    private let memory = MemoryFileSystem()
    private let plugin = DirectorySyncPlugin(opensWindows: false)
    private let bench: TestBench

    /// Two folders with a few files of every kind, for every test.
    internal init() {
        let early = Date(timeIntervalSince1970: 1_000_000)
        memory.addFile("/A/new.txt", "from the left", modified: early.addingTimeInterval(500))
        memory.addFile("/A/update.txt", "newer on the left", modified: early.addingTimeInterval(60))
        memory.addFile("/B/update.txt", "older", modified: early)
        memory.addFile("/B/sub/arrives.txt", "from the right", modified: early)
        memory.addFile("/A/odd.txt", "left text", modified: early)
        memory.addFile("/B/odd.txt", "rightxtext", modified: early.addingTimeInterval(1))
        memory.addFile("/A/zero.txt", "", modified: early)
        memory.addFile("/B/zero.txt", "", modified: early.addingTimeInterval(1))
        memory.addFile("/A/alike.txt", "abc", modified: early)
        memory.addFile("/B/alike.txt", "abd", modified: early)
        bench = TestBench(
            plugins: [plugin, CompareContentPlugin(opensWindows: false)],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
    }

    /// Opens the tool on the panels' folders.
    private func opened() throws -> SyncSession {
        bench.commands.perform(.synchronizeDirectories)
        return try #require(plugin.session)
    }

    /// A comparison by content away from the main thread reports what it reads, with and without bytes to read.
    @Test
    internal func aBackgroundComparisonReportsItsProgress() async throws {
        let session = try opened()
        session.runsInline = false
        session.progressInterval = 0
        session.options.byContent = true
        var statuses: [String] = []
        session.onChange = { statuses.append(session.status) }
        session.compare()
        #expect(await AppWait.until { session.phase == .compared })
        #expect(statuses.contains { $0.hasPrefix("Comparing by content:") && $0.hasSuffix("%)") })
        #expect(statuses.contains { $0.hasPrefix("Comparing: ") })
        // Only files without bytes to read: no share of bytes.
        statuses = []
        session.options.mask = "zero.txt"
        session.compare()
        #expect(await AppWait.until { session.phase == .compared })
        #expect(statuses.contains { $0.hasPrefix("Comparing by content:") && $0.hasSuffix("bytes") })
    }

    /// Reports and results of a comparison that was replaced meanwhile are dropped.
    @Test
    internal func aReplacedComparisonIsDropped() async throws {
        let session = try opened()
        session.runsInline = false
        session.progressInterval = 0
        memory.stallsListings = true
        session.compare()
        #expect(Wait.until { memory.stalledListings(of: "/A") + memory.stalledListings(of: "/B") > 0 })
        session.adopt(left: bench.left.model, right: bench.right.model, includeHidden: false)
        memory.releaseStalls()
        var later = false
        DispatchQueue.main.async { later = true }
        #expect(await AppWait.until { later })
        #expect(session.phase == .idle && session.rows.isEmpty)
    }

    /// A large list is laid out away from the main thread; an action set meanwhile is counted, and
    /// a layout overtaken by another is dropped.
    @Test
    internal func aLargeListIsLaidOutInTheBackground() async throws {
        let session = try opened()
        session.runsInline = false
        session.worksInBackgroundFrom = 1
        var preparing = 0
        session.onChange = {
            guard session.status.hasPrefix("Preparing the list"), preparing == 0 else {
                return
            }
            preparing += 1
            session.setAction(.none, rows: Array(session.rows.indices))
            session.markDefault(rows: Array(session.rows.indices))
        }
        session.compare()
        #expect(await AppWait.until { session.phase == .compared && !session.entries.isEmpty })
        #expect(await AppWait.until { !session.status.hasPrefix("Preparing") })
        #expect(session.canSynchronize && preparing == 1)
        // A layout overtaken by the next is dropped.
        session.show = [.copyToRight, .duplicates, .singles]
        session.show = .all
        #expect(await AppWait.until { !session.status.hasPrefix("Preparing") })
        #expect(session.entries.count - session.visibleRows.count == 1)
    }

    /// A large plan is made away from the main thread; nothing changes meanwhile, and a plan
    /// that comes after the rows went is not run.
    @Test
    internal func aLargePlanIsMadeInTheBackground() async throws {
        let session = try opened()
        session.compare()
        session.runsInline = false
        session.worksInBackgroundFrom = 1
        bench.interaction.formAnswers = [.cancel]
        session.synchronize()
        #expect(session.status == "Preparing the plan…")
        let before = session.rows.map(\.action)
        session.setAction(.none, rows: Array(session.rows.indices))
        session.synchronize()
        #expect(session.rows.map(\.action) == before)
        #expect(await AppWait.until { bench.interaction.log.contains { $0.hasPrefix("form:") } })
        // Again, but the rows go while the plan is made.
        session.synchronize()
        session.adopt(left: bench.left.model, right: bench.right.model, includeHidden: false)
        var later = false
        DispatchQueue.main.async { later = true }
        #expect(await AppWait.until { later })
        #expect(bench.interaction.log.filter { $0.hasPrefix("form:") }.count == 1)
    }

    /// While the files are synchronized nothing new starts: no new folders, no comparison, no saved set.
    @Test
    internal func nothingStartsWhileTheRunGoes() throws {
        let session = try opened()
        session.compare()
        session.saveSet(named: "Kept")
        var tried = false
        session.onChange = {
            guard session.phase == .synchronizing, !tried else {
                return
            }
            tried = true
            session.adopt(left: bench.right.model, right: bench.left.model, includeHidden: true)
            session.compare()
            #expect(!session.loadSet(named: "Kept") && session.phase == .synchronizing)
        }
        bench.interaction.formAnswers = [.accept]
        bench.interaction.choiceAnswers = [1]
        session.synchronize()
        #expect(tried && session.leftPath == "mem:/A")
    }

    /// A mirror of an empty folder onto one that cannot be read gives no warning; many folders
    /// that cannot be read are counted beyond twelve.
    @Test
    internal func emptySourcesAndManyUnreadableFolders() throws {
        _ = memory.addDirectory("/E")
        for index in 0..<14 { memory.addFile("/B/locked\(index)/f.txt", "x") }
        memory.unreadable = Set((0..<14).map { "/B/locked\($0)" })
        let session = try opened()
        session.leftPath = "mem:/E"
        session.rightPath = "mem:/missing"
        session.options.asymmetric = true
        session.compare()
        #expect(!session.sourceLooksEmpty)
        session.leftPath = "mem:/A"
        session.rightPath = "mem:/B"
        session.compare()
        #expect(bench.interaction.log.last?.hasPrefix("inform: Some directories or files could not be read") == true)
    }

    /// Picking or comparing what is not a file does nothing; without the comparison tool the user is told.
    @Test
    internal func pickingAndComparingOnlyFiles() throws {
        let session = try opened()
        session.options.emptyDirectories = true
        _ = memory.addDirectory("/A/empty")
        session.compare()
        let folder = try #require(session.rows.firstIndex { $0.isDirectory })
        session.pick(.left, row: folder)
        #expect(session.picked.left == nil)
        session.compareContents(row: nil)
        session.compareContents(row: folder)
        let new = try #require(session.rows.firstIndex { $0.name == "new.txt" })
        session.compareContents(row: new)
        let arrives = try #require(session.rows.firstIndex { $0.name == "arrives.txt" })
        session.compareContents(row: arrives)
        #expect(!bench.interaction.log.contains("inform: Compare by content is not available."))
        let lonely = DirectorySyncPlugin(opensWindows: false)
        let alone = TestBench(
            plugins: [lonely],
            fileSystems: [memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
        alone.commands.perform(.synchronizeDirectories)
        let other = try #require(lonely.session)
        other.compare()
        other.compareContents(row: other.rows.firstIndex { $0.name == "odd.txt" })
        #expect(alone.interaction.log.last == "inform: Compare by content is not available.")
    }

    /// A plan with nothing to do asks nothing; a stopped run, one with many errors and one that
    /// could not be written durably each say so.
    @Test
    internal func whatIsToldAfterARun() throws {
        let session = try opened()
        session.compare()
        session.setAction(.none, rows: Array(session.rows.indices))
        session.synchronize()
        #expect(bench.interaction.log.isEmpty)
        var stopped = SyncOutcome()
        stopped.wasCancelled = true
        session.report(stopped)
        #expect(bench.interaction.log.last == "inform: Synchronize was stopped.")
        var failed = SyncOutcome()
        failed.errors = (0..<14).map { "error \($0)" }
        session.report(failed)
        var unsafe = SyncOutcome()
        unsafe.commitFailed = true
        session.report(unsafe)
        let failures = bench.interaction.log.suffix(2)
        #expect(failures.allSatisfy { $0 == "inform: Synchronize did not finish without errors." })
        session.report(SyncOutcome())
        #expect(bench.interaction.log.count == 3)
    }
}
