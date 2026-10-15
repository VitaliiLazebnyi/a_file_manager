import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import SelectionPlugin

/// The Mark menu's commands beyond the other suites: the scopes of every variant, steps,
/// arguments out of range, and the selection types dialog in all its answers.
@MainActor
@Suite
internal struct CoverageSelectionCommands {
    /// The commands of this plugin.
    private typealias Ids = SelectionCommands

    /// The files: `/A` with a folder and files, `/B` like it.
    private let memory = MemoryFileSystem()
    /// The settings, for the options of the Mark menu.
    private let settings = MemorySettings()
    /// The clipboard the plugin reads.
    private let scratch = ScratchPasteboard()
    /// The kernel with the plugin, working on the calling thread.
    private let bench: TestBench

    /// The kernel's commands.
    private var commands: CommandRegistry { bench.commands }
    /// The panel on `/A`, the source.
    private var left: FakePanel { bench.left }
    /// The dialogs, answered by script.
    private var dialogs: ScriptedInteraction { bench.interaction }
    /// The saved types and masks.
    private var store: SelectionStore { SelectionStore(settings: settings) }
    /// The selected names of the left panel, sorted.
    private var selected: [String] { left.model.selection.sorted() }

    /// The files and the kernel.
    internal init() {
        memory.addFile("/A/docs/in.txt")
        let time = Date(timeIntervalSince1970: 1_000_000)
        memory.addFile("/A/one.txt", "1", modified: time)
        memory.addFile("/A/two.md", "22")
        memory.addFile("/A/three.md", "333")
        memory.addFile("/B/one.txt", "1", modified: time)
        bench = TestBench(
            plugins: [SelectionPlugin(pasteboard: scratch.pasteboard, background: false)],
            fileSystems: [memory],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: settings
        )
    }

    /// Every variant applies its own scope: both kinds, files only and as configured.
    @Test
    internal func everyVariantHasItsScope() {
        commands.perform(Ids.selectBoth, .text("*"))
        #expect(selected == ["docs", "one.txt", "three.md", "two.md"])
        commands.perform(Ids.clearAsConfigured, .text("*.md"))
        #expect(selected == ["docs", "one.txt"])
        commands.perform(Ids.clearAllAsConfigured)
        #expect(selected.isEmpty)
        commands.perform(Ids.invertBoth)
        #expect(selected == ["docs", "one.txt", "three.md", "two.md"])
        // Without Num + for folders, the other choice is both.
        commands.perform(.unselectAll)
        settings.set(false, forKey: SelectionStore.marksFoldersKey)
        commands.perform(Ids.selectGroupOtherChoice, .text("*"))
        #expect(selected == ["docs", "one.txt", "three.md", "two.md"])
    }

    /// On a folder, Select Group with Current Extension proposes every file.
    @Test
    internal func theCurrentExtensionOfAFolderIsEveryFile() {
        left.moveCursor(toName: "docs")
        commands.perform(Ids.selectGroupCurrentExtension)
        #expect(dialogs.log == ["prompt: Expand selection [*.*]"])
    }

    /// A blank mask changes nothing and is not remembered.
    @Test
    internal func aBlankMaskChangesNothing() {
        commands.perform(.selectGroup, .text("   "))
        #expect(selected.isEmpty && store.history.isEmpty)
    }

    /// Unselect and Go to Next takes one item without a count; a count of 0 does nothing.
    @Test
    internal func stepsWithoutACountAndWithZero() {
        commands.perform(.selectAll)
        left.moveCursor(toName: "one.txt")
        commands.perform(Ids.unselect)
        #expect(!selected.contains("one.txt") && left.model.cursorItem?.name == "three.md")
        commands.perform(Ids.select, .index(0))
        #expect(left.model.cursorItem?.name == "three.md" && selected.contains("three.md"))
    }

    /// In a folder without a `[..]` row, every n-th line is counted from the first.
    @Test
    internal func everyNthLineAtTheRoot() {
        left.show(memory.url("/"))
        commands.perform(.selectAll, .index(1))
        #expect(selected == ["A", "B"])
    }

    /// A comparison mode that does not exist is the default one; without an argument the
    /// comparison with folders takes it too.
    @Test
    internal func unknownComparisonModesAreTheDefault() {
        commands.perform(Ids.compareDirectories, .index(9))
        #expect(selected == ["three.md", "two.md"])
        commands.perform(Ids.compareDirectoriesWithSubdirectories)
        #expect(selected == ["docs", "three.md", "two.md"])
        commands.perform(.unselectAll)
        commands.perform(Ids.compareDirectoriesWithSubdirectories, .index(9))
        #expect(selected == ["docs", "three.md", "two.md"])
    }

    /// With Num + for folders (the default), the other choice is files only.
    @Test
    internal func theOtherChoiceIsFilesOnly() {
        commands.perform(Ids.selectGroupOtherChoice, .text("*"))
        #expect(selected == ["one.txt", "three.md", "two.md"])
    }

    /// A comparison view whose filter another one replaced is left alone when the panel goes
    /// elsewhere: the other filter is not taken away.
    @Test
    internal func aReplacedComparisonViewIsLeftAlone() {
        commands.perform(Ids.markNewerHideSame)
        #expect(commands.isChecked(Ids.markNewerHideSame))
        left.model.setFilter(PanelFilter.mask("*.md"))
        #expect(!commands.isChecked(Ids.markNewerHideSame))
        left.show(memory.url("/A/docs"))
        #expect(left.model.filter?.title == "*.md")
    }

    /// The list of types and masks: a row that is not there does nothing, Remove on a type
    /// removes the type.
    @Test
    internal func theListOfTypesAndMasks() {
        store.save(SelectionType(name: "Texts", mask: "*.txt"))
        store.remember("*.md")
        dialogs.formAnswers = [.values(["row": .index(9)]), .values(["row": .index(0)], button: 2)]
        commands.perform(Ids.selectFromList)
        #expect(selected.isEmpty && store.types.count == 1)
        commands.perform(Ids.selectFromList)
        #expect(store.types.isEmpty && store.history == ["*.md"])
    }

    /// Defining a type: the choice of type and the form can be cancelled; Delete without a name
    /// removes the type chosen; a type needs a name.
    @Test
    internal func definingATypeIsCancelledDeletedOrRefused() {
        store.save(SelectionType(name: "Texts", mask: "*.txt"))
        dialogs.formAnswers = [.cancel, .values(["row": .index(1)]), .cancel]
        commands.perform(Ids.defineSelectionType)
        commands.perform(Ids.defineSelectionType)
        #expect(
            store.types.count == 1
                && dialogs.log == ["form: Define selection", "form: Define selection", "form: Define selection"]
        )
        dialogs.formAnswers = [.values(["row": .index(1)]), .values(["name": .text("")], button: 1)]
        commands.perform(Ids.defineSelectionType)
        #expect(store.types.isEmpty)
        dialogs.formAnswers = [.values(["name": .text("  ")])]
        commands.perform(Ids.defineSelectionType)
        #expect(dialogs.log.last == "inform: A selection type needs a name." && store.types.isEmpty)
    }

    /// Every field of a type is read; choices out of range are "any", an empty mask is every
    /// file, and an existing type shows its age limit.
    @Test
    internal func everyFieldOfATypeIsRead() throws {
        dialogs.formAnswers = [
            .values([
                "name": .text("Recent"), "mask": .text(""), "kind": .index(9), "to": .text("2026-10-11"),
                "days": .text("5"), "hidden": .index(9), "links": .index(9)
            ])
        ]
        commands.perform(Ids.defineSelectionType)
        let saved = try #require(store.type(named: "Recent"))
        #expect(saved.mask == "*.*" && saved.kind == .any && saved.hidden == .any && saved.links == .any)
        #expect(saved.notOlderThanDays == 5 && SelectionType.text(ofDate: saved.modifiedTo) == "2026-10-11 23:59")
        dialogs.formAnswers = [.values(["row": .index(1)]), .cancel]
        commands.perform(Ids.defineSelectionType)
        #expect(dialogs.forms.last?.first { $0.key == "days" }?.initialValue == .text("5"))
    }

    /// Fields that cannot be read, and a regular expression that cannot, stop the saving.
    @Test
    internal func unreadableFieldsStopTheSaving() {
        dialogs.formAnswers = [
            .values(["name": .text("Bad"), "days": .text("-1")]),
            .values(["name": .text("Bad"), "days": .text("x")]),
            .values(["name": .text("Bad"), "mask": .text("<(")])
        ]
        for _ in 0..<3 { commands.perform(Ids.defineSelectionType) }
        #expect(dialogs.log.filter { $0 == "inform: The selection type was not saved." }.count == 3)
        #expect(store.types.isEmpty)
    }
}
