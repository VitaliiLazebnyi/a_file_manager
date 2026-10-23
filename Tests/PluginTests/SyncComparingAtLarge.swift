import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import DirectorySyncPlugin

/// The comparison engine at large: cancelled, at every combination of options, on all cores, across
/// file systems, and the rows it makes (spec 09 › Comparison algorithm).
@Suite
internal struct SyncComparingAtLarge {
    /// The trees and their file systems.
    private let fixture = SyncTreeFixture()

    /// The trees.
    private var memory: MemoryFileSystem { fixture.memory }
    /// The local and the memory file system.
    private var fileSystems: FileSystemRegistry { fixture.fileSystems }
    /// The date most files are dated.
    private var early: Date { SyncTreeFixture.early }

    /// A cancelled comparison stops and says so; pairs not read stay pending.
    @Test
    internal func cancelledComparisonStopsAndSaysSo() {
        fixture.makeTree()
        let comparison = SyncComparison(options: SyncOptions(), fileSystems: fileSystems)
        comparison.cancellation.cancel()
        let result = comparison.run(left: memory.url("/L"), right: memory.url("/R"))
        #expect(result.wasCancelled && result.rows.isEmpty)

        // Cancelled while comparing by content: the pairs not read stay undecided.
        var options = SyncOptions()
        options.byContent = true
        let second = SyncComparison(options: options, fileSystems: fileSystems)
        let afterWalk = second.run(left: memory.url("/L"), right: memory.url("/R")) { progress in
            if progress.filesToCompare > 0 { second.cancellation.cancel() }
        }
        #expect(afterWalk.wasCancelled && afterWalk.rows.contains { $0.state == .pending && $0.action == .nothing })
    }

    /// A finished comparison is let go, though its progress closure held it.
    @Test
    internal func aFinishedComparisonIsLetGo() {
        fixture.makeTree()
        weak var finished: SyncComparison?
        do {
            let comparison = SyncComparison(options: SyncOptions(), fileSystems: fileSystems)
            // The progress holds the comparison, as that of a caller who may cancel it does.
            let result = comparison.run(left: memory.url("/L"), right: memory.url("/R")) { _ in
                _ = comparison.cancellation.isCancelled
            }
            #expect(!result.rows.isEmpty)
            finished = comparison
        }
        #expect(finished == nil)
    }

    /// Every combination of the options keeps what each promises.
    @Test
    internal func everyCombinationOfOptionsKeepsItsPromises() {
        fixture.makeTree()
        memory.addDirectory("/L/hollow")
        for bits in 0..<32 {
            let result = fixture.compare { options in
                options.subdirectories = bits & 1 != 0
                options.byContent = bits & 2 != 0
                options.ignoreDate = bits & 4 != 0
                options.asymmetric = bits & 8 != 0
                options.emptyDirectories = bits & 16 != 0
            }
            let rows = result.rows
            #expect(rows.allSatisfy { $0.accepts($0.action) && $0.action == $0.defaultAction }, "options \(bits)")
            #expect(rows.allSatisfy { $0.state != .pending }, "options \(bits)")
            #expect((bits & 1 != 0) || rows.allSatisfy { $0.directory.isEmpty && !$0.isDirectory }, "options \(bits)")
            #expect(
                (bits & 4 == 0) || !rows.contains { $0.state == .leftNewer || $0.state == .rightNewer },
                "options \(bits)"
            )
            #expect((bits & 8 == 0) || !rows.contains { $0.action == .copyToLeft }, "options \(bits)")
            #expect((bits & 8 != 0) || !rows.contains { $0.action == .deleteRight }, "options \(bits)")
            let hasFolders = rows.contains(where: \.isDirectory)
            #expect(hasFolders == (bits & 17 == 17), "options \(bits)")
            let twin = rows.first { $0.name == "twin.txt" }?.state
            #expect(twin == (bits & 2 != 0 ? .different : .equal), "options \(bits)")
            #expect(Set(rows.map(\.relativePath)).count == rows.count, "options \(bits)")
        }
    }

    /// Many pairs are compared by content on all cores, and the rows stay in order.
    @Test
    internal func manyPairsAreComparedOnAllCoresAndStayInOrder() {
        for index in 0..<300 {
            let name = String(format: "d%02d/f%03d.bin", index % 12, index)
            memory.addFile("/L/" + name, String(repeating: "a", count: 2_000) + "\(index)", modified: early)
            memory.addFile(
                "/R/" + name,
                String(repeating: "a", count: 2_000)
                    + (index.isMultiple(of: 7) ? "x" : "\(index)")
                    .padding(
                        toLength: "\(index)".count,
                        withPad: "x",
                        startingAt: 0
                    ),
                modified: early
            )
        }
        var options = SyncOptions()
        options.byContent = true
        let comparison = SyncComparison(options: options, fileSystems: fileSystems)
        let lock = NSLock()
        // Guarded by `lock`.
        nonisolated(unsafe) var last = SyncProgress()
        let result = comparison.run(left: memory.url("/L"), right: memory.url("/R")) { progress in
            lock.lock()
            last = progress
            lock.unlock()
        }
        #expect(result.rows.count == 300)
        #expect(result.rows.map(\.relativePath) == result.rows.map(\.relativePath).sorted())
        for row in result.rows {
            let index = Int(row.name.dropFirst().prefix(3)) ?? -1
            #expect(row.state == (index.isMultiple(of: 7) ? .different : .equal), "\(row.name)")
        }
        #expect(
            last.filesCompared == 300 && last.filesToCompare == 300 && last.bytesCompared > 0
                && last.leftDirectories == 13
        )
    }

    /// A folder on disk is compared with one in memory, and links are left out.
    @Test
    internal func comparesAcrossFileSystemsAndIgnoresLinks() throws {
        let box = try Sandbox()
        try box.file("L/same.txt", "identical bytes", modified: early)
        try box.file("L/changed.txt", "left bytes!", modified: early)
        try box.file("L/target.txt", "x", modified: early)
        try FileManager.default.createSymbolicLink(
            at: box.url("L/link.txt"),
            withDestinationURL: box.url("L/target.txt")
        )
        try FileManager.default.createSymbolicLink(at: box.url("L/loop"), withDestinationURL: box.url("L"))
        memory.addFile("/R/same.txt", "identical bytes", modified: early)
        memory.addFile("/R/changed.txt", "right bytes", modified: early)
        var options = SyncOptions()
        options.byContent = true
        let result = SyncComparison(options: options, fileSystems: fileSystems)
            .run(
                left: box.url("L"),
                right: memory.url("/R")
            )
        #expect(
            SyncTreeFixture.describe(result.rows) == [
                "changed.txt different nothing", "same.txt equal nothing", "target.txt leftOnly copyToRight"
            ]
        )
    }

    /// Files read in blocks of uneven sizes compare correctly, and a missing one throws.
    @Test
    internal func streamsOfUnevenBlocksCompareCorrectly() throws {
        let big = String(repeating: "0123456789", count: 70_000)
        memory.addFile("/a", big)
        memory.addFile("/b", big)
        memory.addFile("/c", big.dropLast() + "!")
        memory.addFile("/d", big + "tail")
        let flag = CancellationFlag()
        var bytes = 0
        func uncounted(_: Int) {
            // Only the first comparison counts its bytes.
        }
        #expect(
            try SyncComparison.sameContent(
                memory.url("/a"),
                memory.url("/b"),
                fileSystems: fileSystems,
                cancellation: flag
            ) { bytes += $0 } == true
        )
        #expect(bytes == 700_000)
        #expect(
            try SyncComparison.sameContent(
                memory.url("/a"),
                memory.url("/c"),
                fileSystems: fileSystems,
                cancellation: flag,
                progress: uncounted
            ) == false
        )
        #expect(
            try SyncComparison.sameContent(
                memory.url("/a"),
                memory.url("/d"),
                fileSystems: fileSystems,
                cancellation: flag,
                progress: uncounted
            ) == false
        )
        #expect(throws: (any Error).self) {
            try SyncComparison.sameContent(
                memory.url("/a"),
                memory.url("/missing"),
                fileSystems: fileSystems,
                cancellation: flag,
                progress: uncounted
            )
        }
    }

    /// The Show buttons filter by the direction the comparison computed.
    @Test
    internal func showButtonsFilterByComputedDirection() {
        fixture.makeTree()
        let rows = fixture.compare().rows
        func shown(_ show: SyncShow) -> [String] { rows.filter(show.shows).map(\.name) }
        #expect(shown(.all).count == rows.count)
        #expect(shown([.copyToRight, .duplicates, .singles]) == ["left.txt", "newer-left.txt", "only-left.txt"])
        #expect(shown([.copyToLeft, .duplicates, .singles]) == ["newer-right.txt", "right.txt", "only-right.txt"])
        #expect(shown([.equal, .duplicates, .singles]) == ["equal.txt", "twin.txt", "inner.txt"])
        #expect(shown([.notEqual, .duplicates, .singles]) == ["size.txt"])
        #expect(
            shown(SyncShow.all.subtracting(.singles)).count == 6
                && shown(SyncShow.all.subtracting(.duplicates)).count == 4
        )
        #expect(shown([.duplicates, .singles]).isEmpty)
    }

    /// A row accepts the actions it can carry out; a click cycles through them.
    @Test
    internal func actionsARowAccepts() throws {
        fixture.makeTree()
        let rows = Dictionary(uniqueKeysWithValues: fixture.compare().rows.map { row in (row.name, row) })
        let (left, right, pair) = (
            try #require(rows["left.txt"]), try #require(rows["right.txt"]), try #require(rows["size.txt"])
        )
        #expect(
            left.accepts(.copyToRight) && left.accepts(.deleteLeft) && !left.accepts(.copyToLeft)
                && !left.accepts(.deleteRight) && !left.accepts(.deleteBoth)
        )
        #expect(right.accepts(.copyToLeft) && right.accepts(.deleteRight) && !right.accepts(.copyToRight))
        #expect(pair.accepts(.copyToLeft) && pair.accepts(.copyToRight) && pair.accepts(.deleteBoth))
        // A click goes through what is possible: nothing, right, left for a pair without default.
        var clicked = pair
        var seen: [SyncAction] = []
        for _ in 0..<3 {
            clicked.action = clicked.nextAction
            seen.append(clicked.action)
        }
        #expect(seen == [.copyToRight, .copyToLeft, .nothing])
        #expect(left.nextAction == SyncAction.nothing)
        var reversed = try #require(rows["newer-left.txt"])
        reversed.action = reversed.reversedAction
        #expect(reversed.action == .copyToLeft && left.reversedAction == .copyToRight)
    }
}
