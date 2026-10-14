import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing
@testable import ViewOptionsPlugin

/// Sorting and filtering of long lists (review 2, C063 and its kin): the work is done away
/// from the main thread, and when the list changed meanwhile it is done again there, never on
/// the main thread. The test says when the background work and its return happen.
@MainActor @Suite struct Review2ConfigAViewOptions {
    /// Holds what the plugin hands to the background and back, until the test runs it.
    final class Steps {
        var background: [() -> Void] = []
        var main: [() -> Void] = []

        func runBackground() {
            let work = background
            background = []
            work.forEach { $0() }
        }

        func runMain() {
            let work = main
            main = []
            work.forEach { $0() }
        }
    }

    let memory = MemoryFileSystem()
    let plugin = ViewOptionsPlugin()
    let steps = Steps()
    let bench: TestBench

    var commands: CommandRegistry { bench.commands }
    var model: PanelModel { bench.left.model }

    init() {
        for number in 0..<ViewOptionsPlugin.backgroundSortThreshold { memory.addFile("/Big/f\(number).txt", String(repeating: "x", count: number % 7)) }
        memory.addFile("/Big/tool", permissions: 0o755)
        memory.addDirectory("/B")
        bench = TestBench(plugins: [plugin], fileSystems: [memory], left: memory.url("/Big"), right: memory.url("/B"))
        plugin.background = { [steps] in steps.background.append($0) }
        plugin.onMain = { [steps] in steps.main.append($0) }
    }

    /// (Before the model kept the wish, `PanelModel.requestSort`, the stale result sent the
    /// new list to the background a second time; now the reading brings the order with it.)
    @Test func aListThatChangedWhileItWasSortedArrivesInTheOrderThatWasAskedFor() {
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

    @Test func anOrderSetByAnotherRouteMeanwhileIsNotOverwritten() {
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

    @Test func aLaterSortCommandTakesOver() {
        commands.perform(.sortBySize)
        commands.perform(.sortByTime)
        #expect(steps.background.count == 2)
        steps.runBackground()
        steps.runMain()
        #expect(model.sort.key == .date && steps.background.isEmpty)
    }

    @Test func aLongListIsFilteredInTheBackground() {
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

    @Test func onlySelectedIsOfferedByTheNumberOfMarks() {
        #expect(!commands.isEnabled(ViewOptionsPlugin.onlySelected))
        model.setSelected(true, names: ["tool", "f1.txt"])
        #expect(commands.isEnabled(ViewOptionsPlugin.onlySelected))
        commands.perform(ViewOptionsPlugin.onlySelected)
        steps.runBackground()
        steps.runMain()
        #expect(model.items.map(\.name).sorted() == ["f1.txt", "tool"] && commands.isChecked(ViewOptionsPlugin.onlySelected))
        // The last custom filter is offered when one is stored, whatever it holds.
        #expect(!commands.isEnabled(ViewOptionsPlugin.lastCustomFilter))
        bench.kernel.settings.set("*.md", forKey: ViewOptionsPlugin.lastMaskKey)
        #expect(commands.isEnabled(ViewOptionsPlugin.lastCustomFilter))
    }
}
