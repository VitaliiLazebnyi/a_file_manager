import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Corners of the kernel no other suite reaches: a kernel asked for its panels without a shell,
/// a long history, sums that leave the range of a number, and lists with a filter or with
/// several entries of one name.
@MainActor
@Suite
internal struct CoverageKernelTests {
    private static let folder = URL(fileURLWithPath: "/coverage/kernel")

    /// Asking for the panels before a shell is attached is a mistake of the plugin, and ends the program.
    @Test
    internal func askingForThePanelsWithoutAShellEndsTheProgram() async {
        await #expect(processExitsWith: .exitCode(1)) {
            CoverageCoreTrap.exitOnTrap()
            await MainActor.run {
                let kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
                _ = kernel.panels
            }
        }
    }

    /// The history keeps the newest visits up to its limit; the oldest go.
    @Test
    internal func theHistoryForgetsItsOldestVisitsBeyondItsLimit() {
        var history = PanelHistory(Self.folder.appending(name: "0"))
        for index in 1...(PanelModel.historyLimit + 5) {
            history.record(Self.folder.appending(name: "\(index)"), .record)
        }
        #expect(history.locations.count == PanelModel.historyLimit)
        #expect(history.locations.first?.lastPathComponent == "6")
        #expect(history.locations.last?.lastPathComponent == "\(PanelModel.historyLimit + 5)")
        #expect(history.index == PanelModel.historyLimit - 1)
    }

    /// A remembered listing shown after another order was asked for comes in that order.
    @Test
    internal func aRememberedListingIsShownInTheRequestedOrder() {
        let items = [Fixture.file("a", in: Self.folder, size: 3), Fixture.file("b", in: Self.folder, size: 1)]
        let panel = Fixture.panel(items, at: Self.folder)
        let bySize = ListOrder(key: .size)
        panel.requestSort(bySize)
        panel.showRemembered(Fixture.listing(items, at: Self.folder))
        #expect(panel.sort == bySize)
        #expect(panel.wantedSort == bySize)
        #expect(panel.items.map(\.name) == ["b", "a"])
    }

    /// Of several entries of one name that are all filtered out, the likeliest of them answers
    /// whether the item is marked.
    @Test
    internal func anItemOfSeveralHiddenEntriesOfItsNameIsAskedOfTheLikeliestOfThem() throws {
        let items = [
            Fixture.file("twin", in: Self.folder, size: 1), Fixture.file("twin", in: Self.folder, size: 2),
            Fixture.file("other", in: Self.folder)
        ]
        let panel = Fixture.panel(items, at: Self.folder)
        panel.setFilter(PanelFilter(title: "no twins") { $0.name != "twin" })
        panel.toggleSelection(row: try #require(panel.row(ofName: "other")))
        #expect(panel.selection == ["other"])
        // An older reading of the entry: equal to neither of the two.
        #expect(!panel.isSelected(Fixture.file("twin", in: Self.folder, size: 9)))
        #expect(panel.isSelected(items[2]))
    }

    /// With a filter on, marking by a test marks only what is shown.
    @Test
    internal func markingByATestWithAFilterMarksOnlyTheShownEntries() {
        let items = ["a.txt", "b.txt", "c.md"].map { Fixture.file($0, in: Self.folder) }
        let panel = Fixture.panel(items, at: Self.folder)
        panel.setFilter(.mask("*.txt"))
        panel.select { _ in true }
        #expect(panel.selection == ["a.txt", "b.txt"])
        panel.select(where: { $0.name == "a.txt" }, select: false)
        #expect(panel.selection == ["b.txt"])
    }

    /// Marking an entry with a size below zero has the totals of the selection counted afresh.
    @Test
    internal func markingAnEntryOfANegativeSizeCountsTheSelectionAfresh() throws {
        let items = [Fixture.file("plain", in: Self.folder, size: 10), Fixture.file("odd", in: Self.folder, size: -5)]
        let panel = Fixture.panel(items, at: Self.folder)
        panel.toggleSelection(row: try #require(panel.row(ofName: "plain")))
        #expect(panel.totals.selectedBytes == 10 && panel.totals.selectedFiles == 1)
        panel.toggleSelection(row: try #require(panel.row(ofName: "odd")))
        #expect(panel.totals.selectedBytes == 5 && panel.totals.selectedFiles == 2)
    }

    /// A sum beyond the range of a number stops at its end, in the direction it went, and is not plain.
    @Test
    internal func aTallyBeyondTheRangeOfANumberStopsAtItsEnd() {
        var low = Tally()
        low.add(Fixture.file("a", in: Self.folder, size: -Int64.max))
        low.add(Fixture.file("b", in: Self.folder, size: -10))
        #expect(low.bytes == .min && !low.isPlain && low.files == 2)
        var high = Tally()
        high.add(Fixture.file("c", in: Self.folder, size: .max))
        let joined = high.joined(with: high)
        #expect(joined.bytes == .max && !joined.isPlain && joined.files == 2)
    }

    /// A job with nothing to do has made no progress.
    @Test
    internal func aJobWithNothingToDoHasNoProgress() {
        let progress = JobProgress(lines: ["nothing"], itemsDone: 0, itemsTotal: 0)
        #expect(progress.fraction == 0)
        #expect(JobProgress(lines: [], itemsDone: 3, itemsTotal: 2).fraction == 1)
    }
}
