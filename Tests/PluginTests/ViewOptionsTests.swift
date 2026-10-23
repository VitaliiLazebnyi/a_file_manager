import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ViewOptionsPlugin

/// The Show menu's commands, driven against fake panels: views, plugin columns, display
/// filters, and what the plugin registers.
@MainActor
@Suite
internal struct ViewOptionsTests {
    /// Offers two columns, as a content plugin would.
    internal final class ColumnsPlugin: Plugin {
        /// The plugin's name in the list of plugins.
        internal let name = "Columns"

        /// Registers the two columns: the name in capitals and its length.
        internal func start(in kernel: Kernel) {
            kernel.columns.register(ContentColumn(id: "upper", title: "Upper") { $0.name.uppercased() })
            kernel.columns.register(
                ContentColumn(id: "length", title: "Length", alignsRight: true) { "\($0.name.count)" }
            )
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The files: `/A` with files of several kinds, a folder and a hidden folder, `/B` with one file.
    internal let memory = MemoryFileSystem()
    /// The settings the plugin reads, empty at the start.
    internal let settings = MemorySettings()
    /// The kernel with the two plugins, `/A` on the left (the source) and `/B` on the right.
    internal let bench: TestBench

    /// The bench's commands.
    internal var commands: CommandRegistry { bench.commands }
    /// The left panel, the source.
    internal var left: FakePanel { bench.left }
    /// The right panel.
    internal var right: FakePanel { bench.right }

    /// Builds the files and the bench.
    internal init() {
        memory.addFile("/A/one.txt")
        memory.addFile("/A/two.md")
        memory.addFile("/A/run.sh")
        memory.addFile("/A/tool", permissions: 0o755)
        memory.addFile("/A/docs/in.txt")
        memory.addFile("/A/.cvs/entries")
        memory.addFile("/B/other.txt")
        bench = TestBench(
            plugins: [ColumnsPlugin(), ViewOptionsPlugin()],
            fileSystems: [memory],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: settings
        )
    }

    // MARK: Registration

    /// The commands come with their keys (no clash), the Show menu, the toolbar's view buttons and
    /// the Display page of the preferences.
    @Test
    internal func registersCommandsKeysMenusToolbarAndPreferences() {
        let kernel = bench.kernel
        #expect(kernel.keyClashes.isEmpty)
        #expect(
            kernel.keyBindings.command(for: .f(1, .control)) == .viewBrief
                && kernel.keyBindings.command(for: .f(2, .control)) == .viewFull
        )
        #expect(kernel.keyBindings.command(for: .f(1, [.control, .shift])) == .viewThumbnails)
        #expect(
            kernel.keyBindings.command(for: .f(10, .control)) == "cm_SrcAllFiles"
                && kernel.keyBindings.command(for: .f(11, .control)) == "cm_SrcExecs"
        )
        #expect(
            kernel.keyBindings.command(for: .f(12, .control)) == "cm_SrcUserDef"
                && kernel.keyBindings.command(for: .f(1, .shift)) == "cm_CustomColumnConfig"
        )
        let show = kernel.menus.menus.first { $0.title == "Show" }?.items ?? []
        #expect(show.starts(with: [.viewBrief, .viewFull, .viewThumbnails, "cm_CustomColumnConfig", nil, .sortByName]))
        #expect(
            show.contains("cm_SrcUserDef") && show.contains(.showHidden)
                && show.compactMap(\.self).allSatisfy { commands[$0] != nil }
        )
        #expect(kernel.toolbar.defaultLayout.compactMap { $0?.command } == [.viewBrief, .viewFull, .viewThumbnails])
        #expect(
            kernel.preferences.pages.map(\.title) == ["Display"] && kernel.preferences.pages[0].preferences.count == 3
        )
    }

    // MARK: Views and columns

    /// A view command switches the source panel and is checked for the panel that has that view.
    @Test
    internal func theViewCommandsSwitchTheSourcePanel() {
        #expect(commands.isChecked(.viewFull) && !commands.isChecked(.viewBrief))
        commands.perform(.viewBrief)
        #expect(
            left.viewMode == .brief && right.viewMode == .full && commands.isChecked(.viewBrief)
                && !commands.isChecked(.viewFull)
        )
        right.focus()
        #expect(commands.isChecked(.viewFull))
        commands.perform(.viewThumbnails)
        #expect(right.viewMode == .thumbnails && left.viewMode == .brief && commands.isChecked(.viewThumbnails))
        commands.perform(.viewFull)
        #expect(right.viewMode == .full)
    }

    /// Custom Columns shows one checkbox per offered column and keeps the order of those that stay.
    @Test
    internal func customColumnsAreChosenInAForm() {
        left.viewMode = .brief
        bench.interaction.formAnswers = [.values(["length": .flag(true)])]
        commands.perform("cm_CustomColumnConfig")
        #expect(bench.interaction.forms[0].map(\.key) == ["", "upper", "length"])
        // Columns are seen in the Full view only, so the panel goes there.
        #expect(left.extraColumns == ["length"] && left.viewMode == .full && right.extraColumns.isEmpty)
        // A column that stays keeps its place; a new one goes to the end. The form shows what is on.
        bench.interaction.formAnswers = [.values(["upper": .flag(true)])]
        commands.perform("cm_CustomColumnConfig")
        #expect(bench.interaction.forms[1].map(\.initialValue) == [nil, .flag(false), .flag(true)])
        #expect(left.extraColumns == ["length", "upper"])
        bench.interaction.formAnswers = [.cancel, .values(["length": .flag(false)])]
        commands.perform("cm_CustomColumnConfig")
        #expect(left.extraColumns == ["length", "upper"])
        // A column of a plugin that is not loaded is not in the form and is left alone.
        left.extraColumns = ["gone", "length", "upper"]
        left.viewMode = .brief
        settings.set(false, forKey: "viewOptions.columnsSwitchToFull")
        commands.perform("cm_CustomColumnConfig")
        #expect(left.extraColumns == ["gone", "upper"] && left.viewMode == .brief)
    }

    /// Custom Columns is disabled when no plugin offers a column.
    @Test
    internal func withoutPluginColumnsThereIsNothingToChoose() throws {
        let bare = TestBench(
            plugins: [ViewOptionsPlugin()],
            fileSystems: [MemoryFileSystem()],
            left: try #require(URL(string: "mem:///")),
            right: try #require(URL(string: "mem:///"))
        )
        #expect(!bare.commands.isEnabled("cm_CustomColumnConfig"))
    }

    // MARK: Display filters

    /// Programs lists folders, executable files and the files the user's masks name, in the source tab only.
    @Test
    internal func programsShowsWhatCanBeRun() {
        #expect(left.names == ["docs", "one.txt", "run.sh", "tool", "two.md"] && commands.isChecked("cm_SrcAllFiles"))
        commands.perform("cm_SrcExecs")
        #expect(
            left.names == ["docs", "run.sh", "tool"] && commands.isChecked("cm_SrcExecs")
                && !commands.isChecked("cm_SrcAllFiles")
        )
        #expect(left.model.filter?.title == "<programs>" && right.model.filter == nil)
        // The filter belongs to the tab and stays when the folder changes.
        left.show(memory.url("/B"))
        #expect(left.names.isEmpty && left.model.listedItems.count == 1)
        commands.perform("cm_SrcAllFiles")
        #expect(
            left.names == ["other.txt"] && commands.isChecked("cm_SrcAllFiles") && !commands.isChecked("cm_SrcExecs")
        )
        // The user's masks decide what else counts as a program.
        settings.set("*.md", forKey: "viewOptions.programMasks")
        left.show(memory.url("/A"))
        commands.perform("cm_SrcExecs")
        #expect(left.names == ["docs", "tool", "two.md"])
    }

    /// Custom… asks for a specification, remembers it for Last Custom Filter, and `*.*` takes it away.
    @Test
    internal func aCustomFilterIsAskedForRememberedAndReset() {
        #expect(!commands.isEnabled("cm_SrcUserSpec"))
        bench.interaction.promptAnswers = [.text("*.txt *.md")]
        commands.perform("cm_SrcUserDef")
        #expect(bench.interaction.log == ["prompt: Enter file types (e.g. *.doc *.txt) [*.*]"])
        #expect(
            left.names == ["docs", "one.txt", "two.md"] && commands.isChecked("cm_SrcUserDef")
                && left.model.filter?.title == "*.txt *.md"
        )
        // `*.*` shows everything again; the last real mask is proposed the next time.
        commands.perform("cm_SrcUserDef", .text("*.*"))
        #expect(
            left.model.filter == nil && commands.isChecked("cm_SrcAllFiles") && !commands.isChecked("cm_SrcUserDef")
        )
        bench.interaction.promptAnswers = [.cancel]
        commands.perform("cm_SrcUserDef")
        #expect(
            bench.interaction.log.last == "prompt: Enter file types (e.g. *.doc *.txt) [*.*]"
                && left.model.filter == nil
        )
        commands.perform("cm_SrcUserDef", .text("*.* | *.md docs/"))
        #expect(left.names == ["one.txt", "run.sh", "tool"])
        commands.perform("cm_SrcAllFiles")
        #expect(commands.isEnabled("cm_SrcUserSpec"))
        commands.perform("cm_SrcUserSpec")
        #expect(left.names == ["one.txt", "run.sh", "tool"] && commands.isChecked("cm_SrcUserDef"))
    }

    /// Only Selected Files keeps the files that were marked when it ran, whatever is marked later.
    @Test
    internal func onlySelectedFilesIsASnapshot() {
        #expect(!commands.isEnabled("cm_ShowOnlySelected"))
        left.model.select(mask: "*.txt *.sh")
        commands.perform("cm_ShowOnlySelected")
        #expect(
            left.names == ["one.txt", "run.sh"] && commands.isChecked("cm_ShowOnlySelected")
                && left.model.selection.count == 2
        )
        left.model.clearSelection()
        #expect(left.names == ["one.txt", "run.sh"])
        commands.perform("cm_SrcAllFiles")
        #expect(left.names.count == 5)
    }

    /// A filter whose title starts with the display filter's keeps the command checked; another does not.
    @Test
    internal func aFilterLaidOverADisplayFilterKeepsItChecked() throws {
        commands.perform("cm_SrcUserDef", .text("*.txt"))
        // What the quick filter does: its title starts with the one below.
        let below = try #require(left.model.filter)
        left.model.setFilter(PanelFilter(title: below.title + "  ⏷ on") { below.matches($0) && $0.name.contains("on") })
        #expect(commands.isChecked("cm_SrcUserDef") && left.names == ["one.txt"])
        // A filter someone else put in its place is not this plugin's.
        left.model.setFilter(PanelFilter(title: "comparison") { _ in true })
        #expect(!commands.isChecked("cm_SrcUserDef") && !commands.isChecked("cm_SrcAllFiles"))
    }

    /// Inclusions, exclusions and folder exclusions (with `/` or `\\`) of a display specification.
    @Test
    internal func displayMasks() {
        func item(_ name: String, folder: Bool = false) -> FileItem {
            FileItem(url: URL(fileURLWithPath: "/x/" + name), name: name, kind: .init(isDirectory: folder))
        }
        let images = DisplayMask("*.bmp *.gif;*.JPG")
        #expect(
            images.matches(item("a.jpg")) && !images.matches(item("a.txt"))
                && images.matches(item("pictures", folder: true))
        )
        let noImages = DisplayMask("*.* | *.bmp *.gif")
        #expect(noImages.matches(item("a.txt")) && !noImages.matches(item("a.gif")) && !noImages.showsEverything)
        let noCvs = DisplayMask("*.* | .cvs/")
        #expect(
            noCvs.matches(item("a.txt")) && !noCvs.matches(item(".cvs", folder: true))
                && noCvs.matches(item("src", folder: true))
        )
        #expect(noCvs.matches(item(".cvs")))
        let textOnly = DisplayMask("*.txt | *\\")
        #expect(
            textOnly.matches(item("a.txt")) && !textOnly.matches(item("docs", folder: true))
                && !textOnly.matches(item("a.md"))
        )
        // Only exclusions: everything else is shown.
        #expect(DisplayMask("| *.bak").matches(item("a.txt")) && !DisplayMask("| *.bak").matches(item("a.bak")))
        #expect(
            DisplayMask("*.*").showsEverything && DisplayMask(" * ").showsEverything && DisplayMask("").showsEverything
        )
        #expect(DisplayMask("*.*").filter == nil && DisplayMask("*.txt").filter?.title == "*.txt")
    }

    // MARK: Sorting and hidden files

    /// Hidden Files switches both panels, or only the source when the setting says so; a sort command sorts.
    @Test
    internal func hiddenFilesInBothPanelsOrInOne() {
        memory.addFile("/A/.dot")
        memory.addFile("/B/.dot")
        commands.perform(.showHidden)
        #expect(left.names.contains(".dot") && right.names.contains(".dot") && commands.isChecked(.showHidden))
        commands.perform(.showHidden)
        settings.set(false, forKey: "viewOptions.hiddenInBothPanels")
        commands.perform(.showHidden)
        #expect(left.names.contains(".dot") && !right.names.contains(".dot"))
        commands.perform(.sortByExtension)
        #expect(commands.isChecked(.sortByExtension) && left.model.sort == ListOrder(key: .ext))
    }
}
