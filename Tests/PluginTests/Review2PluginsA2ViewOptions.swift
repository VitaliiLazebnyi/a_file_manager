import AFMContracts
import AFMKernel
import TestSupport
import Testing

@testable import ViewOptionsPlugin

/// Round 2 of the review, second pass, View Options: an order that keeps being asked for while a large folder is
/// sorted in the background, and the filter of the selected files.
@MainActor
@Suite
internal struct Review2PluginsA2ViewOptions {
    /// The steps the plugin hands over to the background and back to the main thread, kept until the test runs them.
    ///
    /// Unchecked: used on the main thread only; the plugin hands its steps over there and the test runs them there.
    internal final class Steps: @unchecked Sendable {
        /// The steps meant for a background thread, in the order they came.
        internal var background: [@Sendable () -> Void] = []
        /// The steps meant for the main thread, in the order they came.
        internal var main: [@MainActor @Sendable () -> Void] = []

        /// Runs the background steps that are waiting, here and now.
        internal func runBackground() {
            let work = background
            background = []
            for step in work {
                step()
            }
        }

        /// Runs the main-thread steps that are waiting.
        @MainActor
        internal func runMain() {
            let work = main
            main = []
            for step in work {
                step()
            }
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The file system with the large folder `/Big` and the empty `/B`.
    internal let memory = MemoryFileSystem()
    /// The plugin under test, its background and main-thread steps caught by `steps`.
    internal let plugin = ViewOptionsPlugin()
    /// The steps the plugin handed over and the test has not run yet.
    internal let steps = Steps()
    /// The kernel with the plugin, the left panel on `/Big`.
    internal let bench: TestBench

    /// The model of the left panel.
    internal var model: PanelModel { bench.left.model }

    /// A folder just large enough to be sorted in the background, and the plugin's steps caught.
    internal init() {
        for number in 0..<ViewOptionsPlugin.backgroundSortThreshold {
            memory.addFile("/Big/f\(number).txt", String(repeating: "x", count: number % 7))
        }
        memory.addDirectory("/B")
        bench = TestBench(plugins: [plugin], fileSystems: [memory], left: memory.url("/Big"), right: memory.url("/B"))
        plugin.background = { [steps] in steps.background.append($0) }
        plugin.onMain = { [steps] in steps.main.append($0) }
    }

    /// A folder that changes while it is sorted is read in the order asked for, and the stale sort is dropped.
    @Test
    internal func aFolderThatChangesWhileItIsSortedGetsTheOrderWithItsReading() {
        bench.commands.perform(.sortBySize)
        // The wish is the model's; the list is sorted in the background.
        #expect(steps.background.count == 1 && model.sort.key == .name && model.requestedSort?.key == .size)
        // The folder changes before the sort is ready: the reading that arrives is taken in
        // the order that was asked for.
        memory.addFile("/Big/new.txt", "12345678901234567890")
        bench.left.reload()
        #expect(model.sort.key == .size && model.requestedSort == nil)
        steps.runBackground()
        steps.runMain()
        // The sort that was made meanwhile is of no use, and nothing is sorted a second time.
        #expect(model.sort.key == .size && steps.background.isEmpty && steps.main.isEmpty)
        #expect(isInSizeOrder())
        #expect(model.items.contains { $0.name == "new.txt" })
    }

    /// A change that brings no new list makes the sort stale, and the sort is started in the background again.
    @Test
    internal func aChangeThatBringsNoListLeavesTheSortToTheBackgroundAgain() {
        bench.commands.perform(.sortBySize)
        // Another filter while the list is sorted: the result is stale, and no reading brought the order.
        model.setFilter(.mask("*.txt"))
        steps.runBackground()
        steps.runMain()
        #expect(model.sort.key == .name && model.requestedSort?.key == .size && steps.background.count == 1)
        steps.runBackground()
        steps.runMain()
        #expect(model.sort.key == .size && model.requestedSort == nil && steps.background.isEmpty && steps.main.isEmpty)
        #expect(isInSizeOrder())
    }

    /// A second order command starts from the order asked for, not from the one the panel still shows.
    @Test
    internal func aWishForAnOrderSurvivesAListThatArrivesBeforeItIsMet() {
        bench.commands.perform(.sortByTime)
        bench.commands.perform(.reversedOrder)
        // The second command starts from the order that was asked for, not from the one the panel has.
        steps.runBackground()
        steps.runMain()
        #expect(
            model.sort
                == ListOrder(
                    key: .date,
                    descending: !ListOrder(key: .date, descending: SortKey.date.startsDescending).descending
                )
        )
    }

    /// Unsorted after another order shows the folder in the order the file system gives.
    @Test
    internal func unsortedAfterAnotherKeyReadsTheFolderAgain() {
        let small = MemoryFileSystem()
        small.addFile("/S/zebra.txt")
        small.addFile("/S/apple.txt")
        small.addFile("/S/mango.txt")
        let smallBench = TestBench(
            plugins: [ViewOptionsPlugin()],
            fileSystems: [small],
            left: small.url("/S"),
            right: small.url("/S")
        )
        smallBench.commands.perform(.sortByName)
        #expect(smallBench.left.names == smallBench.left.names.sorted())
        smallBench.commands.perform(.unsorted)
        // The order the file system gives them in is back.
        let arrival = ((try? small.list(small.url("/S"), showHidden: true)) ?? []).map(\.name)
        #expect(smallBench.left.model.sort.key == .unsorted && smallBench.left.names == arrival)
    }

    /// Only Selected Files takes the marked names in the background and then shows only them.
    @Test
    internal func onlySelectedFilesTakesTheNamesInTheBackground() {
        model.setSelected(true, names: ["f1.txt", "f3.txt"])
        bench.commands.perform(ViewOptionsPlugin.onlySelected)
        #expect(steps.background.count == 1 && model.filter == nil)
        steps.runBackground()
        steps.runMain()
        #expect(model.items.map(\.name) == ["f1.txt", "f3.txt"])
    }

    /// Whether the left panel's list is in the order of size its sort names, up or down.
    private func isInSizeOrder() -> Bool {
        let descending = model.sort.descending
        return zip(model.items, model.items.dropFirst())
            .allSatisfy { earlier, later in
                descending ? earlier.size >= later.size : earlier.size <= later.size
            }
    }
}
