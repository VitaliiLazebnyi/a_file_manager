import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import DirectorySyncPlugin

/// The Synchronize directories window at its edges: a comparison that runs while the user acts,
/// folders and hidden rows, the texts and colours of every state, and a window made from an archive.
@MainActor
@Suite
internal struct CovSyncWindowEdges {
    private let stage: CovSyncStage

    /// A fresh window on two folders, one with an empty folder, for every test.
    internal init() throws {
        stage = try CovSyncStage(empty: ["/A/empty"])
    }

    /// Every button below `view`.
    private static func buttons(in view: NSView?) -> [NSButton] {
        guard let view else {
            return []
        }
        return view.subviews.flatMap { subview in [subview as? NSButton].compactMap(\.self) + buttons(in: subview) }
    }

    /// Esc and Compare interrupt a comparison that runs; when none runs Esc is left to the window.
    @Test
    internal func escapeAndCompareInterruptAComparison() async {
        defer { stage.finish() }
        stage.controller.show()
        #expect(!stage.controller.interruptComparison())
        stage.session.runsInline = false
        stage.memory.stallsListings = true
        stage.press("Compare")
        #expect(stage.session.phase == .comparing)
        stage.controller.window?.cancelOperation(nil)
        #expect(await AppWait.until { stage.session.phase == .compared })
        #expect(stage.session.isPartial)
        stage.press("Compare")
        #expect(stage.session.phase == .comparing && stage.button("Abort") != nil)
        stage.press("Abort")
        // Enter in a field while it runs starts nothing new.
        let field = stage.fields[0]
        field.sendAction(field.action, to: field.target)
        #expect(await AppWait.until { stage.session.phase == .compared })
        stage.memory.releaseStalls()
    }

    /// Options that are on show as ticked boxes; a tolerance the pop-up does not have shows its last item.
    @Test
    internal func theControlsShowTheOptions() throws {
        defer { stage.finish() }
        var options = stage.session.options
        options.subdirectories = true
        options.byContent = true
        options.ignoreDate = true
        options.asymmetric = true
        options.emptyDirectories = true
        options.ignoreOneHourDifference = true
        options.toleranceSeconds = 7
        stage.session.options = options
        stage.session.onlySelected = true
        stage.controller.show()
        let titles = [
            "Subdirs", "by content", "ignore date", "Asymmetric", "Empty directories", "ignore 1 h difference",
            "Only selected (in main window)"
        ]
        for title in titles { #expect(stage.button(title)?.state == .on, "\(title)") }
        let tolerance = try #require(stage.views(NSPopUpButton.self).first { !$0.pullsDown })
        #expect(tolerance.indexOfSelectedItem == 2)
        options.subdirectories = false
        stage.session.options = options
        stage.controller.show()
        #expect(stage.button("Subdirs")?.state == .off)
    }

    /// Folders show as `[name]` with `<DIR>`; actions on hidden rows redraw nothing; a caption
    /// that is selected is no row to act on; Ctrl+PgDn after the last folder stays.
    @Test
    internal func foldersHiddenRowsAndCaptions() throws {
        defer { stage.finish() }
        var options = stage.session.options
        options.emptyDirectories = true
        stage.session.options = options
        stage.controller.show()
        stage.press("Compare")
        let table = try #require(stage.table)
        let folder = try #require(stage.row("empty"))
        let item = stage.session.rows[folder]
        #expect(SyncWindowController.text(of: item, column: "leftName") == "[empty]")
        #expect(SyncWindowController.text(of: item, column: "leftSize") == "<DIR>")
        #expect(SyncWindowController.text(of: item, column: "rightName").isEmpty)
        let equal = try #require(stage.button("="))
        equal.state = .off
        equal.sendAction(equal.action, to: equal.target)
        stage.session.setAction(.copyToLeft, rows: Array(stage.session.rows.indices))
        let caption = try #require(stage.session.entries.firstIndex { if case .header = $0 { true } else { false } })
        table.selectRowIndexes([caption], byExtendingSelection: false)
        try stage.type("l", code: 37, .control)
        table.selectRowIndexes([stage.session.entries.count - 1], byExtendingSelection: false)
        let last = table.selectedRow
        try stage.type("\u{F72D}", code: 121, .control)
        #expect(table.selectedRow == last)
    }

    /// The row menu of a folder: nothing to view or compare, unless a file of each side was picked.
    @Test
    internal func theRowMenuOfAFolder() throws {
        defer { stage.finish() }
        var options = stage.session.options
        options.emptyDirectories = true
        stage.session.options = options
        stage.controller.show()
        stage.press("Compare")
        let table = try #require(stage.table)
        let menu = try #require(table.menu)
        let empty = try #require(stage.position("empty"))
        table.selectRowIndexes([empty], byExtendingSelection: false)
        stage.controller.menuNeedsUpdate(menu)
        let compare = { menu.items.first { $0.title == "Compare left & right" }?.isEnabled }
        #expect(compare() == false)
        let odd = try #require(stage.row("odd.txt"))
        stage.session.pick(.left, row: odd)
        stage.controller.menuNeedsUpdate(menu)
        #expect(compare() == false)
        stage.session.pick(.right, row: odd)
        stage.controller.menuNeedsUpdate(menu)
        #expect(compare() == true)
    }

    /// A right click on a row outside the selection selects it first.
    @Test
    internal func aRightClickSelectsTheRow() throws {
        defer { stage.finish() }
        stage.controller.show()
        stage.press("Compare")
        let table = try #require(stage.table)
        stage.controller.window?.contentView?.layoutSubtreeIfNeeded()
        let odd = try #require(stage.position("odd.txt"))
        let frame = table.rect(ofRow: odd)
        let point = table.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        let click = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: stage.controller.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        table.deselectAll(nil)
        #expect(table.menu(for: try #require(click)) === table.menu)
        #expect(table.selectedRow == odd)
    }

    /// Every state has its symbol and colour, and an action replaces the symbol.
    @Test
    internal func everyStateHasItsSymbolAndColour() {
        let folder = URL(fileURLWithPath: "/")
        let file = FileItem(url: URL(fileURLWithPath: "/x"), name: "x")
        func row(_ state: SyncState) -> SyncRow {
            SyncRow(
                directory: "",
                isDirectory: false,
                left: file,
                right: file,
                leftDirectory: folder,
                rightDirectory: folder,
                state: state,
                asymmetric: true
            )
        }
        #expect(SyncWindowController.text(of: row(.pending), column: "action") == "?")
        #expect(SyncWindowController.text(of: row(.excluded), column: "action") == "⊘")
        #expect(SyncWindowController.text(of: row(.equal), column: "action") == "=")
        #expect(SyncWindowController.color(of: row(.pending)) == .secondaryLabelColor)
        #expect(SyncWindowController.color(of: row(.excluded)) == .secondaryLabelColor)
        #expect(SyncWindowController.color(of: row(.rightOnly)) == .systemBlue)
        var marked = row(.equal)
        marked.action = .copyToRight
        #expect(SyncWindowController.text(of: marked, column: "action") == SyncAction.copyToRight.symbol)
    }

    /// A window is never made from an archive; a controller without a window asks for no folder.
    @Test
    internal func noArchiveAndNoWindow() throws {
        defer { stage.finish() }
        #expect(SyncWindowController(coder: NSCoder()) == nil)
        let other = SyncWindowController(session: stage.session, effects: stage.answers.effects)
        let picker = try #require(
            CovSyncWindowEdges.buttons(in: other.window?.contentView).first { $0.title == ">>" }
        )
        other.window?.close()
        other.window = nil
        picker.sendAction(picker.action, to: picker.target)
        #expect(stage.answers.folderRequests == 0)
    }
}
