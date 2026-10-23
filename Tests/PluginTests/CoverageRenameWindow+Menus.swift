import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// The placeholders, the menus and the buttons of the window.
extension CoverageRenameWindow {
    // MARK: Placeholders

    /// The insert buttons put placeholders into the masks, in place of what is selected.
    @Test
    internal func buttonsPutPlaceholdersIntoTheMasks() {
        session.settings.nameMask = ""
        session.settings.extensionMask = ""
        for title in ["[N] Name", "[C] Counter", "[YMD] Date", "[hms] Time"] {
            press(title)
        }
        #expect(nameMask.stringValue == "[N][C][YMD][hms]")
        press("[E] Ext.")
        #expect(fields[0].stringValue == "[E]")
        // A field that is being edited gets the placeholder in place of what is selected.
        #expect(window.makeFirstResponder(fields[0]))
        fields[0].currentEditor()?.selectedRange = NSRange(location: 0, length: 3)
        let counters = Controls.all(NSButton.self, in: content).filter { $0.title == "[C] Counter" }
        if let last = counters.last {
            Controls.send(last)
        }
        #expect(session.settings.extensionMask == "[C]")
    }

    /// More fields and the ranges of other fields come from menus under their buttons.
    @Test
    internal func moreFieldsComeFromMenus() throws {
        session.settings.nameMask = ""
        var menus: [(NSMenu, NSView)] = []
        controller.popUpMenu = { menus.append(($0, $1)) }
        press("+")
        let menu = try #require(menus.first?.0)
        #expect((menus.first?.1 as? NSButton)?.title == "+")
        #expect(menu.items.first?.title == "[P]  Parent folder")
        menu.performActionForItem(at: 0)
        #expect(nameMask.stringValue == "[P]")
        interaction.formAnswers = [.values(["first": .text("2"), "last": .text("3")])]
        press("#")
        let rangeMenu = try #require(menus.last?.0)
        #expect(rangeMenu.items.map(\.title).last == "[X#-#]  Clipboard text")
        rangeMenu.performActionForItem(at: 3)
        #expect(nameMask.stringValue == "[P][A2-3]")
    }

    /// The range picker asks for the positions and writes the range they make.
    @Test
    internal func theRangePickerAsksForPositions() {
        session.settings.nameMask = ""
        session.settings.extensionMask = ""
        interaction.formAnswers = [
            .cancel,
            .values(["first": .text("x")]),
            .values(["first": .text("2"), "last": .text("")]),
            .values(["first": .text("2"), "last": .text("3"), "length": .flag(true)]),
            .values(["first": .text("2"), "last": .text("3"), "firstFromEnd": .flag(true), "lastFromEnd": .flag(true)])
        ]
        for _ in 0..<5 {
            press("[N#-#] Range")
        }
        #expect(nameMask.stringValue == "[N2-][N2,3][N-2--3]")
        #expect(interaction.forms.first?.isEmpty == false)
        interaction.formAnswers = [.values(["first": .text("1")])]
        press("[E#-#] Range")
        #expect(fields[0].stringValue == "[E1-]")
    }

    /// The range picker shows the name of the first row, and nothing when the list is empty.
    @Test
    internal func theRangePickerShowsTheFirstName() {
        let folder = session.rows.firstIndex { $0.entry.item.isFolder } ?? 0
        session.move(IndexSet(integer: folder), to: 0)
        session.settings.nameMask = ""
        interaction.formAnswers = [.cancel, .cancel]
        press("[N#-#] Range")
        var menus: [NSMenu] = []
        controller.popUpMenu = { menu, _ in menus.append(menu) }
        press("#")
        menus.first?.performActionForItem(at: 0)
        #expect(interaction.log == ["form: Select the characters to insert:", "form: Select the characters to insert:"])
        session.remove(IndexSet(0..<session.rowCount))
        interaction.formAnswers = [.cancel]
        press("[N#-#] Range")
        #expect(interaction.log.count == 3)
    }

    // MARK: Menus

    /// Settings are saved, loaded and deleted through the settings menu.
    @Test
    internal func savedSettingsAreSavedLoadedAndDeleted() {
        session.settings.nameMask = "s[C]"
        interaction.promptAnswers = [.text(" Mine "), .cancel]
        choose("Save settings…", in: "F2 Load/save settings")
        #expect(session.store.savedNames == ["Mine"])
        choose("Save settings…", in: "F2 Load/save settings")
        choose("<default>", in: "F2 Load/save settings")
        #expect(session.settings == .unchanged)
        choose("Mine", in: "F2 Load/save settings")
        #expect(session.settings.nameMask == "s[C]")
        interaction.formAnswers = [.cancel, .values(["row": .index(0)])]
        choose("Delete entry…", in: "F2 Load/save settings")
        #expect(session.store.savedNames == ["Mine"])
        choose("Delete entry…", in: "F2 Load/save settings")
        #expect(session.store.savedNames.isEmpty)
        // The title of the menu does nothing.
        choose("F2 Load/save settings", in: "F2 Load/save settings")
        #expect(session.settings.nameMask == "s[C]")
    }

    /// Deleting other saved settings keeps the name of the loaded ones for the next save.
    @Test
    internal func deletingOtherSavedSettingsKeepsTheLoadedName() {
        session.save(as: "One")
        session.save(as: "Two")
        // Nothing loaded yet: the first entry is proposed.
        interaction.formAnswers = [.cancel]
        choose("Delete entry…", in: "F2 Load/save settings")
        if case .list(_, let selected)? = interaction.forms.last?.first?.kind {
            #expect(selected == 0)
        }
        choose("Two", in: "F2 Load/save settings")
        interaction.formAnswers = [.values(["row": .index(0)])]
        choose("Delete entry…", in: "F2 Load/save settings")
        #expect(session.store.savedNames == ["Two"])
        interaction.promptAnswers = [.accept]
        choose("Save settings…", in: "F2 Load/save settings")
        #expect(interaction.log.last == "prompt: Save settings [Two]")
    }

    /// Names are edited or loaded from a file through the names menu, and the masks come back.
    @Test
    internal func namesComeFromTheNamesMenu() {
        interaction.formAnswers = [.values(["names": .text("x\ny")])]
        choose("Edit names…", in: "F10 Names")
        #expect(session.givenNames == ["x", "y"])
        #expect(popup("F10 Names")?.item(withTitle: "Use the rename masks again")?.isEnabled == true)
        choose("Use the rename masks again", in: "F10 Names")
        #expect(session.givenNames.isEmpty)
        choose("F10 Names", in: "F10 Names")
        // A list loaded from a file: the open panel is answered in the user's place.
        memory.addFile("/lists/names.txt", "x1\nx2")
        var answers: [(NSApplication.ModalResponse, [URL])] = [(.cancel, [memory.url("/lists/names.txt")])]
        var shown: [NSOpenPanel] = []
        controller.presentOpenPanel = { panel, sheetOf, done in
            #expect(sheetOf === self.window && !panel.allowsMultipleSelection)
            shown.append(panel)
            let (response, urls) = answers.removeFirst()
            done(response, urls)
        }
        choose("Load names from file…", in: "F10 Names")
        #expect(shown.count == 1 && session.givenNames.isEmpty)
        answers = [(.OK, [memory.url("/lists/names.txt")])]
        choose("Load names from file…", in: "F10 Names")
        #expect(session.givenNames == ["x1", "x2"])
        // A file that cannot be read is reported.
        controller.namesFileChosen(memory.url("/lists/gone.txt"))
        #expect(interaction.log.contains { $0.hasPrefix("inform: The names cannot be loaded!") })
        controller.namesFileChosen(nil)
        #expect(session.givenNames == ["x1", "x2"])
    }

    // MARK: Buttons

    /// Start!, Result list, Undo and Close do what they say.
    @Test
    internal func startUndoResultListAndClose() {
        session.settings.nameMask = "r[C]"
        press("Start!")
        #expect(session.rowCount == 0 && memory.allPaths.contains("/w/r1.txt"))
        bench.kernel.commands.register(Command(.view, "View")) { _ in
            // A viewer that shows nothing: the result list only has to be handed to it.
        }
        press("Result list")
        interaction.choiceAnswers = [0]
        press("Undo")
        #expect(memory.allPaths.contains("/w/a.txt"))
        var closed = false
        controller.onClose = { closed = true }
        press("Close")
        #expect(closed && !window.isVisible)
    }

    /// A field that does not let go of the keyboard keeps the run from starting.
    @Test
    internal func startWaitsForTheFieldsToLetGo() {
        let stubborn = Stubborn(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        content?.addSubview(stubborn)
        #expect(window.makeFirstResponder(stubborn))
        session.settings.nameMask = "r[C]"
        press("Start!")
        #expect(session.rowCount == 4 && !memory.allPaths.contains("/w/r1.txt"))
        stubborn.letsGo = true
        press("↻ Next step (F5)")
        #expect(session.rows.first?.entry.name == "r1.txt")
    }

    /// The start button is refused while a run is under way.
    @Test
    internal func startIsRefusedWhileARunIsUnderWay() {
        let jobs = CancellingJobService(moment: .held, panels: bench.panelSet)
        bench.kernel.attach(jobs)
        session.settings.nameMask = "r[C]"
        press("Start!")
        press("Start!")
        #expect(jobs.heldCount == 1)
        jobs.runHeld()
        #expect(memory.allPaths.contains("/w/r1.txt"))
    }

    /// The window is never made from an archive.
    @Test
    internal func theWindowIsNeverMadeFromAnArchive() {
        #expect(MultiRenameWindowController(coder: NSCoder()) == nil)
    }
}
