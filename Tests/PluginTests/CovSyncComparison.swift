import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import DirectorySyncPlugin

/// The comparison of two folders at the corners the other suites leave: which file systems keep
/// exact dates, reading files that the cancel stops, and a result made without a comparison.
@Suite
internal struct CovSyncComparison {
    private let fileSystems = FileSystemRegistry()
    private let memory = MemoryFileSystem()
    private let moves = CovSyncMovesFileSystem()

    /// Two memory file systems, for every test.
    internal init() {
        fileSystems.register(memory)
        fileSystems.register(moves)
    }

    /// A result made on its own holds nothing.
    @Test
    internal func anEmptyResult() {
        let result = SyncResult()
        #expect(result.rows.isEmpty && result.errors.isEmpty && !result.wasCancelled)
        #expect(result.leftDirectories == 0 && result.rightDirectories == 0)
    }

    /// Only APFS and HFS+ keep exact dates: a folder of another file system, and one that is not
    /// there, need the tolerance.
    @Test
    internal func onlyAPFSAndHFSKeepExactDates() {
        let devices = URL(fileURLWithPath: "/dev")
        let missing = URL(fileURLWithPath: "/no/such/folder/here")
        let home = URL(fileURLWithPath: NSHomeDirectory())
        #expect(SyncComparison.needsTolerance(devices, home, fileSystems: fileSystems))
        #expect(SyncComparison.needsTolerance(missing, home, fileSystems: fileSystems))
        #expect(!SyncComparison.needsTolerance(home, home, fileSystems: fileSystems))
    }

    /// Reading two files stops when the run is cancelled before it begins or between two blocks.
    @Test
    internal func readingStopsWhenCancelled() throws {
        let block = SyncComparison.blockSize
        memory.addFile("/a", String(repeating: "x", count: block * 3))
        memory.addFile("/b", String(repeating: "x", count: block * 3))
        let (first, second) = (memory.url("/a"), memory.url("/b"))
        let before = CancellationFlag()
        before.cancel()
        #expect(try SyncComparison.sameContent(first, second, fileSystems: fileSystems, cancellation: before) == nil)
        let between = CancellationFlag()
        let cancel = { (_: Int) in between.cancel() }
        let verdict = try SyncComparison.sameContent(
            first,
            second,
            fileSystems: fileSystems,
            cancellation: between,
            progress: cancel
        )
        #expect(verdict == nil)
    }

    /// A pair whose reading the cancel stops stays open; a file that cannot be read is an error.
    @Test
    internal func pairsStoppedOrUnreadable() {
        let block = SyncComparison.blockSize
        moves.base.addFile("/L/big.txt", String(repeating: "x", count: block * 3))
        moves.base.addFile("/R/big.txt", String(repeating: "x", count: block * 3))
        var options = SyncOptions()
        options.byContent = true
        let comparison = SyncComparison(options: options, fileSystems: fileSystems)
        let stopped = comparison.run(left: moves.base.url("/L"), right: moves.base.url("/R")) { progress in
            if progress.bytesCompared > 0 { comparison.cancellation.cancel() }
        }
        #expect(stopped.rows.first?.state == .pending && stopped.errors.isEmpty)
        moves.refuseReading()
        let failed = SyncComparison(options: options, fileSystems: fileSystems)
            .run(left: moves.base.url("/L"), right: moves.base.url("/R"))
        #expect(failed.errors.count == 1 && failed.rows.first?.state == .pending)
    }

    /// A file that cannot be read while the comparison is cancelled is no error: the pair stays open.
    @Test
    internal func aReadStoppedByTheCancelIsNoError() async {
        memory.addFile("/L/a.txt", "same size")
        memory.addFile("/R/a.txt", "same size")
        memory.stallsReads = true
        var options = SyncOptions()
        options.byContent = true
        let comparison = SyncComparison(options: options, fileSystems: fileSystems)
        let (left, right) = (memory.url("/L"), memory.url("/R"))
        let running = Task.detached { comparison.run(left: left, right: right) }
        #expect(Wait.until { memory.stalledTransfers > 0 })
        comparison.cancellation.cancel()
        let result = await running.value
        #expect(result.errors.isEmpty && result.rows.first?.state == .pending)
    }
}
