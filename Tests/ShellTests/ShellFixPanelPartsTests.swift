import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// Parts of a panel meeting a change that came from elsewhere: a quick filter whose folder or
/// display filter was changed behind the panel's back, a closed tab that was still entering a
/// folder, a restored tab on a file system that is its own parent, the name editor in another
/// view, folder sizes that come together or after their calculation was stopped, and plugin
/// columns of rows that went out of sight.
@MainActor
@Suite(.serialized)
internal struct ShellFixPanelPartsTests {
    private let fixture = ShellFixPanel()
    private var panel: PanelViewController { fixture.panel }
    private var model: PanelModel { fixture.panel.model }
    private var id: ObjectIdentifier { ObjectIdentifier(fixture.panel.model) }

    /// Leaves the folder for `/a` the way a model does without the panel (a plugin's doing).
    private func leaveBehindThePanelsBack() {
        let memory = fixture.memory
        model.open(memory.url("/a"), parent: memory.url("/"), root: memory.url("/"))
    }

    /// A quick filter with text whose folder was left behind the panel's back goes, and the list
    /// shows again what the display filter lets through.
    @Test
    internal func aQuickFilterWhoseFolderWasLeftGoesWithItsText() async {
        await fixture.show("/b")
        panel.showQuickFilter()
        panel.quickFilterTyped("y")
        #expect(model.filter?.title == panel.quickFilters[id]?.title && model.filter != nil)
        leaveBehindThePanelsBack()
        #expect(panel.quickFilters[id] == nil && model.filter == nil && panel.quickFilterBar.isHidden)
    }

    /// A quick filter without text whose folder was left goes; the display filter stays as it was.
    @Test
    internal func anEmptyQuickFilterWhoseFolderWasLeftGoes() async {
        await fixture.show("/b")
        let shown = PanelFilter(title: "Text files") { $0.name.hasSuffix(".txt") }
        model.setFilter(shown)
        panel.showQuickFilter()
        leaveBehindThePanelsBack()
        #expect(panel.quickFilters[id] == nil && model.filter?.title == "Text files")
    }

    /// A display filter chosen while the quick filter is open with nothing typed becomes the one
    /// the quick filter lies over.
    @Test
    internal func aDisplayFilterChosenBeforeAnythingIsTypedBecomesTheBase() async {
        await fixture.show("/b")
        panel.showQuickFilter()
        model.setFilter(PanelFilter(title: "Text files") { $0.name.hasSuffix(".txt") })
        #expect(panel.quickFilters[id]?.base?.title == "Text files" && panel.quickFilters[id]?.text.isEmpty == true)
        panel.quickFilterTyped("y")
        #expect(model.filter?.title == "Text files  ⏷ y" && fixture.names == ["y.txt"])
    }

    /// Typing what the field holds already changes nothing, and nothing is applied when no
    /// typing waits.
    @Test
    internal func typingWhatTheFieldHoldsChangesNothing() async {
        await fixture.show("/b")
        panel.showQuickFilter()
        panel.quickFilterTyped("")
        panel.flushPendingQuickFilter()
        #expect(model.filter == nil && panel.quickFilterText?.isEmpty == true && fixture.names == ["y.txt"])
        panel.removeQuickFilter()
    }

    /// A closed tab that was entering a folder takes what it showed before with it.
    @Test
    internal func aClosedTabTakesWhatItShowedBeforeWithIt() async {
        await fixture.show("/b")
        let closing = panel.tabs.insertTab(showing: fixture.memory.url("/a"), at: 1, activate: false)
        let closingID = ObjectIdentifier(closing)
        panel.openedFrom[closingID] = closing.snapshot()
        panel.openedFromFilter[closingID] = QuickFilter(text: "x", base: nil, directory: closing.directory)
        #expect(panel.tabs.closeTab(at: 1))
        #expect(panel.openedFrom[closingID] == nil && panel.openedFromFilter[closingID] == nil)
    }

    /// A restored tab on a file system that says a folder is its own parent is not taken to that
    /// "parent" when the folder cannot be read: the user hears of it once.
    @Test
    internal func aRestoredTabWhoseFolderIsItsOwnParentIsReportedOnce() async {
        await fixture.show("/b")
        let script = fixture.script
        script.inner.addDirectory("/top")
        script.ownParents = ["/top"]
        script.batches = [[]]
        script.holdBefore = 0
        script.failure = CocoaError(.fileReadNoPermission)
        script.open()
        _ = panel.tabs.insertTab(showing: script.url("/top"), at: 1, activate: false)
        panel.tabs.activate(1)
        #expect(await PanelWait.until { !panel.isLoading && !fixture.interaction.log.isEmpty })
        await PanelWait.drainMainQueue()
        #expect(script.listingsBegun == 1 && !model.isListed && fixture.interaction.log.count == 1)
    }

    /// The name editor follows the list into another view, and goes on Esc where nothing types.
    @Test
    internal func theNameEditorFollowsTheListIntoAnotherView() async throws {
        await fixture.show("/b")
        model.moveCursor(to: try #require(model.row(ofName: "y.txt")))
        panel.beginRename()
        let field = try #require(panel.renameField)
        #expect(field.superview === panel.tableView)
        panel.viewMode = .brief
        #expect(panel.isRenaming && field.superview === panel.gridView)
        #expect(panel.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!panel.isRenaming && field.superview == nil)
    }

    /// The folders `d1` (2 bytes) and `d2` (3 bytes) in `/b`, shown.
    private func showFoldersToSize() async {
        fixture.memory.addFile("/b/d1/a.txt", "aa")
        fixture.memory.addFile("/b/d2/b.txt", "bbb")
        await fixture.show("/b")
    }

    /// Marks the folder `name` with Space, which calculates its size.
    private func markWithSize(_ name: String) throws {
        model.moveCursor(to: try #require(model.row(ofName: name)))
        panel.toggleSelectionWithSize()
    }

    /// The size of the entry `name`, once calculated.
    private func size(_ name: String) -> Int64? {
        model.row(ofName: name).flatMap { model.item(atRow: $0)?.computedSize }
    }

    /// Folder sizes that come in during the same turn of the main thread are taken together.
    @Test
    internal func sizesThatComeTogetherAreTakenTogether() async throws {
        await showFoldersToSize()
        try markWithSize("d1")
        try markWithSize("d2")
        // Both answers are sent before the main thread takes the first.
        let first = ShellFixTurns.afterWorkHeld(inLane: "size", at: fixture.memory.url("/b/d1")) {
            // Only the turn counts.
        }
        let second = ShellFixTurns.afterWorkHeld(inLane: "size", at: fixture.memory.url("/b/d2")) {
            // Only the turn counts.
        }
        #expect(first && second)
        #expect(await PanelWait.until { size("d1") != nil && size("d2") != nil })
        #expect(size("d1") == 2 && size("d2") == 3 && panel.arrivedSizes.isEmpty)
    }

    /// A folder size whose calculation is stopped after it came in, before the tab took it, is dropped.
    @Test
    internal func aSizeWhoseCalculationStoppedBeforeItWasTakenIsDropped() async throws {
        await showFoldersToSize()
        try markWithSize("d1")
        let sent = ShellFixTurns.afterWorkHeld(inLane: "size", at: fixture.memory.url("/b/d1")) { [panel, model] in
            panel.cancelSizeCalculations(of: model)
        }
        #expect(sent)
        await PanelWait.drainMainQueue()
        let marked = model.row(ofName: "d1").flatMap { model.item(atRow: $0) }.map(model.isSelected)
        #expect(panel.arrivedSizes.isEmpty && size("d1") == nil && marked == true)
    }

    /// A folder size of a tab that was closed before it took the size is dropped with the tab.
    @Test
    internal func aSizeOfATabClosedBeforeItWasTakenIsDropped() async throws {
        await showFoldersToSize()
        _ = panel.tabs.insertTab(showing: fixture.memory.url("/a"), at: 1, activate: false)
        try markWithSize("d1")
        weak var closed: PanelModel?
        closed = model
        let sent = ShellFixTurns.afterWorkHeld(inLane: "size", at: fixture.memory.url("/b/d1")) { [panel] in
            _ = panel.tabs.closeTab(at: 0)
        }
        #expect(sent)
        #expect(await PanelWait.until { closed == nil })
        await PanelWait.drainMainQueue()
        #expect(panel.tabs.tabs.count == 1 && model.directory.path == "/a")
    }

    /// Plugin columns: the rows that scrolled out of sight are not computed any more, and a value
    /// is drawn in the colour of its row.
    @Test
    internal func pluginColumnsLeaveRowsOutOfSightAndTakeTheirRowsColour() async throws {
        // The values wait until the test lets them go; the names computed are noted.
        let gate = Signal<Bool>()
        let computed = Shared<Set<String>>([])
        defer { gate.set(true) }
        fixture.kernel.columns.register(
            ContentColumn(id: "slow", title: "Slow") { item in
                _ = gate.wait()
                computed.modify { $0.insert(item.name) }
                return item.name
            }
        )
        for index in 0..<300 {
            fixture.memory.addFile(String(format: "/many/f%03d.txt", index))
        }
        await fixture.show("/many")
        panel.extraColumns = ["slow"]
        let table = panel.tableView
        let column = try #require(table.tableColumns.last)
        panel.view.layoutSubtreeIfNeeded()
        // A marked row's value is drawn in the marked colour, as its name is (row 0 is `[..]`).
        model.toggleSelection(row: 1)
        let name = try #require(panel.tableView(table, viewFor: table.tableColumns[0], row: 1) as? NSTableCellView)
        let value = try #require(panel.tableView(table, viewFor: column, row: 1) as? NSTableCellView)
        #expect(model.isSelected(row: 1) && value.textField?.textColor == name.textField?.textColor)
        // Rows far below the ones on screen ask for their values while the first is being worked out.
        let below = (200..<300).compactMap { model.item(atRow: $0)?.name }
        for row in 200..<300 {
            _ = panel.tableView(table, viewFor: column, row: row)
        }
        let visible = table.rows(in: table.visibleRect)
        #expect(panel.columnValues.hasWaiting && visible.length > 0 && visible.location + visible.length < 200)
        // The list scrolled: what waits for rows out of sight is dropped.
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: panel.tableScroll.contentView)
        gate.set(true)
        #expect(
            await PanelWait.until { panel.columnValues.working.isEmpty && !panel.columnValues.hasWaiting }
        )
        #expect(computed.value.isDisjoint(with: below) && computed.value.contains(model.item(atRow: 1)?.name ?? ""))
    }
}
