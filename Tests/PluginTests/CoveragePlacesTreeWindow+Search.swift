import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import PlacesPlugin

/// Quick search, the keys of the search field, and the buttons that end the tree window.
extension CoveragePlacesTreeWindow {
    /// Typing finds the next folder starting with the text and beeps when there is none; keys
    /// in the list type into the field, step through the matches and go.
    @Test
    internal func typingFindsAFolderAndStepsThroughTheMatches() async throws {
        let tree = await opened("/A/a1")
        defer { tree.controller.close() }
        tree.type("a2")
        #expect(tree.selected == "a2" && tree.path == "tree:/A/a2")
        tree.type("zz")
        #expect(beeps.value == 1 && tree.selected == "a2")
        tree.type("")
        #expect(beeps.value == 1)
        // Typing in the list fills the field.
        try tree.press("h", code: 4, [])
        #expect(tree.searchField?.stringValue == "h" && tree.selected == "Home")
        try tree.press("\u{7F}", code: 51, [])
        #expect(tree.searchField?.stringValue.isEmpty == true && tree.selected == "Home")
        tree.type("a")
        #expect(tree.selected == "A")
        try tree.press("\u{F701}", code: 125, .control)
        #expect(tree.selected == "a1")
        try tree.press("\r", code: 36, .control)
        #expect(tree.selected == "a2")
        try tree.press("\u{F700}", code: 126, .control)
        #expect(tree.selected == "a1")
        // A key that types nothing goes to the list: left goes to the folder above.
        try tree.press("\u{F702}", code: 123, [])
        #expect(tree.searchField?.stringValue == "a" && tree.selected == "A")
        try tree.press("\u{F701}", code: 125, .control)
        try tree.press("\r", code: 36, [])
        #expect(!presenter.isOpen(tree.window) && bench.left.model.directory == folders.url("/A/a1"))
    }

    /// In the search field Control-arrows step through the matches and Enter goes; other keys,
    /// and commands without a key press behind them, are the field's own.
    @Test
    internal func keysInTheSearchFieldStepAndGo() async throws {
        let tree = await opened("/A/a1")
        defer { tree.controller.close() }
        guard let field = tree.searchField else {
            return
        }
        tree.type("a")
        // Without a key press behind it (no event is being handled here) a command is the field's own.
        #expect(
            !tree.controller.control(
                field,
                textView: NSTextView(),
                doCommandBy: #selector(NSResponder.insertNewline(_:))
            )
        )
        let other = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        )
        #expect(!tree.controller.handleFieldKey(other))
        #expect(!tree.controller.handleFieldKey(try key("b", 11, [])))
        #expect(tree.controller.handleFieldKey(try key("\u{F701}", 125, .control)) && tree.selected == "a2")
        #expect(tree.controller.handleFieldKey(try key("\u{F700}", 126, [])) && tree.selected == "a1")
        #expect(tree.controller.handleFieldKey(try key("\u{3}", 76, [])))
        #expect(!presenter.isOpen(tree.window) && bench.left.model.directory == folders.url("/A/a1"))
    }

    /// Go without a folder does nothing, Cancel closes the window, and Go while a job runs is
    /// refused and leaves the panel where it is.
    @Test
    internal func theButtonsGoOrCancelAndAJobKeepsThePanelWhereItIs() async {
        let tree = await opened("/A/a1")
        defer { tree.controller.close() }
        tree.outline?.deselectAll(nil)
        tree.click("Go")
        #expect(presenter.isOpen(tree.window))
        tree.click("Cancel")
        #expect(!presenter.isOpen(tree.window) && bench.left.model.directory == folders.url("/A"))
        tree.controller.show(for: folders.url("/A/a2"), showHidden: false)
        #expect(await spin { tree.selected == "a2" })
        var rejected = 0
        bench.commands.onRejected = { rejected += 1 }
        let parts = Shared(tree)
        bench.jobService.run(
            title: "Busy",
            work: { monitor in monitor.ask { parts.value.click("Go") } },
            completion: { _ in
                // What the job gives back does not matter here.
            }
        )
        // (A window that was closed and is not put on screen again tells of no second close.)
        #expect(rejected == 1 && presenter.presented.count == 2 && bench.left.model.directory == folders.url("/A"))
    }

    /// The search of a huge tree goes on in turns of the main thread, and a new search ends the
    /// one before: only the last one beeps or moves the cursor.
    @Test
    internal func aSearchOfAHugeTreeGoesOnInTurnsAndANewOneEndsIt() async {
        let cache = TreeCache(directory: nil)
        cache.store(["A"] + (0..<200_000).map { "p\($0)" }, for: root)
        let tree = await opened("/A", cache: cache, showHidden: false)
        defer { tree.controller.close() }
        tree.type("zzz")
        tree.type("yyy")
        #expect(await spin { beeps.value == 1 })
        tree.type("p199998")
        #expect(await spin { tree.selected == "p199998" })
        await CoveragePlacesLoop.settle()
        #expect(beeps.value == 1)
    }
}
