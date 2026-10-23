import AFMKernel
import TestSupport
import Testing

@testable import ViewOptionsPlugin

/// What the other Show menu suites leave out: a column dialog that changes nothing, and a long
/// list that changes while its filter is worked out in the background.
@MainActor
@Suite
internal struct CoverageViewOptions {
    /// A folder `/Big` one entry longer than the background threshold, and `/B`.
    private let memory = MemoryFileSystem()
    /// The plugin, with background work and its return run when the test says.
    private let plugin = ViewOptionsPlugin()
    /// What the plugin handed over and has not run yet.
    private let steps = Review2ConfigAViewOptionsTests.Steps()
    /// The kernel with the plugin and two columns to choose from.
    private let bench: TestBench

    /// The left panel's model, on `/Big`.
    private var model: PanelModel { bench.left.model }

    /// The long folder, the kernel and the stepped background.
    internal init() {
        for number in 0..<ViewOptionsPlugin.backgroundFilterThreshold {
            memory.addFile("/Big/f\(number).txt")
        }
        memory.addFile("/Big/tool", permissions: 0o755)
        memory.addDirectory("/B")
        bench = TestBench(
            plugins: [ViewOptionsTests.ColumnsPlugin(), plugin],
            fileSystems: [memory],
            left: memory.url("/Big"),
            right: memory.url("/B")
        )
        plugin.background = { [steps] in steps.background.append($0) }
        plugin.onMain = { [steps] in steps.main.append($0) }
    }

    /// The column dialog confirmed as it was shown leaves the columns and the view alone.
    @Test
    internal func anUnchangedColumnDialogChangesNothing() {
        bench.left.extraColumns = ["upper"]
        bench.left.viewMode = .brief
        bench.interaction.formAnswers = [.accept]
        bench.commands.perform("cm_CustomColumnConfig")
        #expect(bench.interaction.forms.count == 1)
        #expect(bench.left.extraColumns == ["upper"] && bench.left.viewMode == .brief)
    }

    /// A list that became short while it was filtered is filtered again on the spot.
    @Test
    internal func aListThatBecameShortIsFilteredOnTheSpot() {
        bench.commands.perform(ViewOptionsPlugin.programs)
        #expect(steps.background.count == 1 && model.filter == nil)
        memory.removeTree("/Big/f0.txt")
        memory.removeTree("/Big/f1.txt")
        bench.left.reload()
        #expect(model.listedItems.count < ViewOptionsPlugin.backgroundFilterThreshold)
        steps.runBackground()
        steps.runMain()
        #expect(steps.background.isEmpty && steps.main.isEmpty)
        #expect(model.filter?.title == "<programs>" && model.items.map(\.name) == ["tool"])
    }

    /// A long list that keeps changing is filtered in the background a few times, then on the spot.
    @Test
    internal func aListThatKeepsChangingIsFilteredOnTheSpotInTheEnd() {
        bench.commands.perform(ViewOptionsPlugin.programs)
        for round in 0..<ViewOptionsPlugin.staleTries {
            #expect(steps.background.count == 1 && model.filter == nil)
            memory.addFile("/Big/new\(round)", permissions: 0o755)
            bench.left.reload()
            steps.runBackground()
            steps.runMain()
        }
        #expect(steps.background.isEmpty && steps.main.isEmpty)
        #expect(
            model.filter?.title == "<programs>" && model.items.map(\.name).sorted() == ["new0", "new1", "new2", "tool"]
        )
    }
}
