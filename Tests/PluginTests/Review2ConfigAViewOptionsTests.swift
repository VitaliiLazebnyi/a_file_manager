import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ViewOptionsPlugin

/// Sorting and filtering of long lists (review 2, C063 and its kin): the work is done away
/// from the main thread, and when the list changed meanwhile it is done again there, never on
/// the main thread.
///
/// The test says when the background work and its return happen.
@MainActor
@Suite
internal struct Review2ConfigAViewOptionsTests {
    /// Holds what the plugin hands to the background and back, until the test runs it.
    ///
    /// Unchecked: used on the main thread only; the plugin hands its steps over there and the test
    /// runs them there.
    internal final class Steps: @unchecked Sendable {
        /// The work handed to the background, not run yet.
        internal var background: [@Sendable () -> Void] = []
        /// The results handed back to the main thread, not run yet.
        internal var main: [@MainActor @Sendable () -> Void] = []

        /// Runs the background work handed over so far (what it hands over meanwhile waits).
        internal func runBackground() {
            let work = background
            background = []
            for step in work {
                step()
            }
        }

        /// Runs the results handed back so far, on the main thread.
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

    /// `/Big`, a folder as long as the background sort threshold plus one program, and an empty `/B`.
    internal let memory = MemoryFileSystem()
    /// The plugin, with the test's steps for its background and main-thread work.
    internal let plugin = ViewOptionsPlugin()
    /// What the plugin handed over and the test has not run yet.
    internal let steps = Steps()
    /// The kernel with the plugin, `/Big` on the left (the source).
    internal let bench: TestBench

    /// The bench's commands.
    internal var commands: CommandRegistry { bench.commands }
    /// The model of the left panel, which lists `/Big`.
    internal var model: PanelModel { bench.left.model }

    /// Builds the long folder and the bench, and takes over the plugin's background and main-thread work.
    internal init() {
        for number in 0..<ViewOptionsPlugin.backgroundSortThreshold {
            memory.addFile("/Big/f\(number).txt", String(repeating: "x", count: number % 7))
        }
        memory.addFile("/Big/tool", permissions: 0o755)
        memory.addDirectory("/B")
        bench = TestBench(plugins: [plugin], fileSystems: [memory], left: memory.url("/Big"), right: memory.url("/B"))
        plugin.background = { [steps] in steps.background.append($0) }
        plugin.onMain = { [steps] in steps.main.append($0) }
    }

    /// A long list that the folder changed under while it was sorted comes in the order asked for,
    /// and nothing is sorted twice.
    ///
    /// (Before the model kept the wish, `PanelModel.requestSort`, the stale result sent the
    /// new list to the background a second time; now the reading brings the order with it.)
    @Test
    internal func aListThatChangedWhileItWasSortedArrivesInTheOrderThatWasAskedFor() {
        #expect(model.sort.key == .name && model.listedItems.count > ViewOptionsPlugin.backgroundSortThreshold)
        commands.perform(.sortBySize)
        #expect(steps.background.count == 1 && model.sort.key == .name)
        // The folder changes while the copy is being sorted: the reading is taken in the order asked for.
        memory.addFile("/Big/new.txt", "12345678901234567890")
        bench.left.reload()
        #expect(model.sort.key == .size)
        steps.runBackground()
        steps.runMain()
        // The stale result was not used, and nothing was sorted a second time, here or in the background.
        #expect(model.sort.key == .size && steps.background.isEmpty && steps.main.isEmpty)
        #expect(model.listedItems.count == ViewOptionsPlugin.backgroundSortThreshold + 2)
        #expect(model.listedItems.first?.name == "new.txt" || model.listedItems.last?.name == "new.txt")
        #expect(commands.isChecked(.sortBySize))
    }

    /// An order set another way while a long list was sorted is kept, and the next command starts from it.
    @Test
    internal func anOrderSetByAnotherRouteMeanwhileIsNotOverwritten() {
        commands.perform(.sortBySize)
        // A click on a column sets the order directly.
        model.setSort(ListOrder(key: .ext, descending: false))
        steps.runBackground()
        steps.runMain()
        #expect(model.sort.key == .ext && steps.background.isEmpty)
        // The next command starts from the order the panel has.
        commands.perform(.reversedOrder)
        steps.runBackground()
        steps.runMain()
        #expect(model.sort == ListOrder(key: .ext, descending: true))
    }

    /// Of two sort commands in a row, the later one's order is the one the list gets.
    @Test
    internal func aLaterSortCommandTakesOver() {
        commands.perform(.sortBySize)
        commands.perform(.sortByTime)
        #expect(steps.background.count == 2)
        steps.runBackground()
        steps.runMain()
        #expect(model.sort.key == .date && steps.background.isEmpty)
    }

    /// A long list is filtered in the background, again when it changed meanwhile, and a later filter wins.
    @Test
    internal func aLongListIsFilteredInTheBackground() {
        let all = model.items.count
        commands.perform(ViewOptionsPlugin.programs)
        #expect(steps.background.count == 1 && model.filter == nil && model.items.count == all)
        memory.addFile("/Big/another", permissions: 0o755)
        bench.left.reload()
        steps.runBackground()
        steps.runMain()
        // The list changed: it is filtered again, in the background.
        #expect(model.filter == nil && steps.background.count == 1)
        steps.runBackground()
        steps.runMain()
        #expect(model.filter?.title == "<programs>" && model.items.map(\.name).sorted() == ["another", "tool"])
        #expect(commands.isChecked(ViewOptionsPlugin.programs))
        // A filter chosen later is the one that counts when the earlier result comes back.
        commands.perform(ViewOptionsPlugin.customFilter, .text("*.txt"))
        commands.perform(ViewOptionsPlugin.allFiles)
        #expect(model.filter == nil)
        steps.runBackground()
        steps.runMain()
        #expect(model.filter == nil && model.items.count == all + 1)
    }

    /// Only Selected Files is offered when files are marked; Last Custom Filter when a mask is stored.
    @Test
    internal func onlySelectedIsOfferedByTheNumberOfMarks() {
        #expect(!commands.isEnabled(ViewOptionsPlugin.onlySelected))
        model.setSelected(true, names: ["tool", "f1.txt"])
        #expect(commands.isEnabled(ViewOptionsPlugin.onlySelected))
        commands.perform(ViewOptionsPlugin.onlySelected)
        steps.runBackground()
        steps.runMain()
        #expect(
            model.items.map(\.name).sorted() == ["f1.txt", "tool"] && commands.isChecked(ViewOptionsPlugin.onlySelected)
        )
        // The last custom filter is offered when one is stored, whatever it holds.
        #expect(!commands.isEnabled(ViewOptionsPlugin.lastCustomFilter))
        bench.kernel.settings.set("*.md", forKey: ViewOptionsPlugin.lastMaskKey)
        #expect(commands.isEnabled(ViewOptionsPlugin.lastCustomFilter))
    }
}
