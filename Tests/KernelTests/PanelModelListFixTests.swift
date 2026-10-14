import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// The panel model with lists that are unusual: sizes beyond the range of a number, a list that
/// comes sorted already, a refresh that brings nothing new, and a long list that did not change.
@MainActor
@Suite
internal struct PanelModelListFixTests {
    /// The folder every model here shows.
    private static let directory = URL(fileURLWithPath: "/work", isDirectory: true)

    /// A file in `/tmp` of `size` bytes.
    private static func entry(_ name: String, size: Int64) -> FileItem {
        TmpEntries.make(name, folder: false, size: size, time: 0)
    }

    /// Checks that sums of sizes that leave the range of a number stop at its end, in the
    /// totals, in a saturating addition and in the size of a tree claimed by a file system.
    @Test
    internal func sumsThatLeaveTheRangeOfANumberStopAtItsEnd() throws {
        let huge = [
            Self.entry("a.bin", size: .max - 10), Self.entry("b.bin", size: .max - 10), Self.entry("c.bin", size: 100),
            TmpEntries.make("d", folder: true, size: 0, time: 0)
        ]
        let model = Fixture.panel(huge, at: Self.directory)
        #expect(model.totals.totalBytes == .max)
        model.selectAll()
        #expect(model.totals.selectedBytes == .max)
        let (first, second) = (try #require(model.row(ofName: "a.bin")), try #require(model.row(ofName: "b.bin")))
        model.toggleSelection(row: first)
        model.toggleSelection(row: second)
        #expect(model.totals.selectedBytes == 100)
        model.toggleSelection(row: first)
        model.toggleSelection(row: second)
        #expect(model.totals.selectedBytes == .max)
        model.setComputedSize(.max, forName: "d")
        #expect(model.totals.selectedBytes == .max && model.totals.totalBytes == .max)
        #expect(Int64.max.addingSaturated(1) == .max && Int64.min.addingSaturated(-1) == .min)
        #expect(Int64(2).addingSaturated(3) == 5)
        let memory = MemoryFileSystem()
        memory.addFile("/big/a/one.bin", "x")
        memory.addFile("/big/b/two.bin", "x")
        #expect(HugeSizes(memory).totalSize(of: memory.url("/big")) == .max)
    }

    /// Checks that a list handed in sorted is taken as it is, keeping the cursor, and that a
    /// list of another length is sorted instead.
    @Test
    internal func aPresortedListIsTakenAsItIs() throws {
        let sample = TmpEntries.numbered
        let model = Fixture.panel(sample, at: Self.directory)
        model.moveCursor(to: try #require(model.row(ofName: "file7.txt")))
        let order = ListOrder(key: .size, descending: true)
        let version = model.listVersion
        let sorted = Sorter.resort(model.listedItems, from: model.sort, to: order)
        #expect(model.listVersion == version)
        model.setSort(order, presorted: sorted)
        #expect(model.sort == order && model.items == Sorter.sort(sample, by: order))
        #expect(model.cursorItem?.name == "file7.txt" && model.listVersion != version)
        // A list of another length cannot be this list in another order.
        model.setSort(ListOrder(key: .name), presorted: Array(sorted.dropLast()))
        #expect(model.items == Sorter.sort(sample, by: ListOrder(key: .name)))
        // Turning the direction round is the same as sorting.
        model.setSort(ListOrder(key: .name, descending: true))
        #expect(model.items == Sorter.sort(sample, by: ListOrder(key: .name, descending: true)))
    }

    /// A remembered list replaced by a fresh reading that holds the same entries: nothing in
    /// the list changes, the state does, and that is announced once.
    @Test
    internal func aRefreshThatOnlyEndsTheWaitingIsAnnounced() {
        let listing = Fixture.listing(TmpEntries.numbered, at: Self.directory)
        let model = PanelModel(directory: Self.directory)
        model.showRemembered(listing)
        #expect(model.isRefreshing && !model.isComplete)
        var changes = 0
        model.onChange = { _ in changes += 1 }
        #expect(model.update(with: listing))
        #expect(changes == 1 && !model.isRefreshing && model.isComplete)
        #expect(!model.update(with: listing))
        #expect(changes == 1)
    }

    /// Checks that a long sorted list read again unchanged is seen as the same, and that one
    /// changed entry near its end is seen, the cursor staying where it was.
    @Test
    internal func aLongListThatDidNotChangeIsSeenAsTheSame() {
        let long = (0..<70_000).map { Self.entry("file\($0).txt", size: Int64($0)) }
        let sorted = Sorter.sort(long, by: ListOrder())
        let model = PanelModel(directory: Self.directory)
        model.show(Fixture.listing(sorted, at: Self.directory), presorted: ListOrder())
        model.moveCursor(to: 40_000)
        #expect(!model.update(with: Fixture.listing(sorted, at: Self.directory), presorted: ListOrder()))
        #expect(model.cursor == 40_000)
        var changed = sorted
        changed[69_000] = Self.entry(changed[69_000].name, size: 1)
        #expect(model.update(with: Fixture.listing(changed, at: Self.directory), presorted: ListOrder()))
        #expect(model.cursor == 40_000 && model.items[69_000].size == 1)
    }
}
