import AFMKernel
import Foundation
import TestSupport
import Testing

/// The panel model, fed with listings from a file system that is not the local disk: what it
/// lists, its targets, its operands, marks and totals, history, updates and announcements.
@MainActor
@Suite
internal struct PanelTests {
    /// The panel showing `/work`.
    private let work: WorkPanel

    /// The panel model under test.
    private var panel: PanelModel { work.panel }

    /// Shows `/work` of a fresh memory file system.
    internal init() throws {
        work = try WorkPanel()
    }

    /// Checks that a new model has no list until it is given one, and is complete after.
    @Test
    internal func startsUnlistedAndTakesAListing() throws {
        let fresh = PanelModel(directory: work.memory.url("/work"))
        #expect(!fresh.isListed && fresh.items.isEmpty && fresh.rowCount == 0)
        fresh.show(try work.listing("/work"))
        #expect(fresh.isListed && fresh.isComplete && fresh.volume?.name == "Memory")
    }

    /// Checks that row 0 is `[..]`, folders come before files, and dot files show only when
    /// hidden files are shown.
    @Test
    internal func listsWithParentRowAndHidesDotFiles() throws {
        #expect(panel.hasParentRow)
        #expect(panel.item(atRow: 0) == nil)
        #expect(panel.items.map(\.name) == ["bin", "docs", "a.txt", "b.md"])
        panel.setShowHidden(true)
        panel.update(with: try work.listing("/work"))
        #expect(panel.items.map(\.name).contains(".hidden"))
    }

    /// Going up and going to the top lead to the folder above and to `/`, with the cursor on
    /// the folder that was left; at the top there is neither, and no `[..]`.
    @Test
    internal func parentAndRootTargets() throws {
        #expect(panel.parentTarget?.location.path == "/" && panel.parentTarget?.focus == "work")
        try work.show("/work/docs")
        #expect(panel.rootTarget?.location.path == "/" && panel.rootTarget?.focus == "work")
        try work.show("/")
        #expect(!panel.hasParentRow && panel.parentTarget == nil && panel.rootTarget == nil)
        #expect(panel.item(atRow: 0)?.name == "work")
    }

    /// The operands are the marked entries, or else the entry under the cursor, never `[..]`;
    /// `[..]` cannot be marked, and the cursor stays inside the rows.
    @Test
    internal func operandRule() throws {
        panel.moveCursor(to: 0)
        #expect(panel.cursorIsOnParentRow && !panel.hasOperands)
        #expect(panel.operands().isEmpty && panel.cursorFile == nil)
        panel.moveCursor(to: try row("a.txt"))
        #expect(panel.operands().map(\.name) == ["a.txt"] && panel.cursorFile?.name == "a.txt")
        panel.toggleSelection(row: try row("b.md"))
        panel.toggleSelection(row: try row("bin"))
        #expect(panel.operands().map(\.name) == ["bin", "b.md"])
        panel.toggleSelection(row: 0)
        #expect(panel.selection.count == 2)
        panel.moveCursor(to: try row("docs"))
        #expect(panel.cursorFile == nil)
        panel.moveCursor(to: 99)
        #expect(panel.cursor == panel.rowCount - 1)
    }

    /// Checks the totals, and marking everything, by mask, the opposite, a saved selection, a
    /// range of rows and a calculated folder size.
    @Test
    internal func selectionCommandsAndTotals() {
        let expected = PanelModel.Totals(
            selectedBytes: 0,
            totalBytes: 3_072,
            selectedFiles: 0,
            totalFiles: 2,
            selectedFolders: 0,
            totalFolders: 2
        )
        #expect(panel.totals == expected)
        panel.selectAll()
        #expect(panel.totals.selectedBytes == 3_072 && panel.totals.selectedFiles == 2)
        #expect(panel.totals.selectedFolders == 2)
        panel.select(mask: "*.txt", select: false)
        #expect(panel.selection == ["bin", "docs", "b.md"])
        panel.invertSelection()
        #expect(panel.selection == ["a.txt"])
        panel.saveSelection()
        panel.clearSelection()
        panel.restoreSelection()
        #expect(panel.selection == ["a.txt"])
        panel.setSelected(true, rows: 1...2)
        #expect(panel.selection == ["a.txt", "bin", "docs"])
        panel.setComputedSize(4_096, forName: "docs")
        #expect(panel.totals.totalBytes == 3_072 + 4_096 && panel.totals.selectedBytes == 2_048 + 4_096)
    }

    /// Checks going back and forward, that a new place drops what lay ahead, and that a reload
    /// leaves the history alone.
    @Test
    internal func historyGoesBackAndForward() throws {
        try work.show("/work/docs")
        #expect(panel.items.isEmpty)
        let parent = try #require(panel.parentTarget)
        panel.show(try work.listing("/work"), focus: parent.focus)
        #expect(panel.cursorItem?.name == "docs")
        #expect(panel.backLocation?.lastPathComponent == "docs" && panel.forwardLocation == nil)
        try work.show("/work/docs", history: .step(-1))
        #expect(panel.backLocation?.lastPathComponent == "work" && panel.forwardLocation?.lastPathComponent == "work")
        try work.show("/work", history: .step(-1))
        #expect(panel.backLocation == nil && panel.forwardLocation?.lastPathComponent == "docs")
        try work.show("/work/bin")
        #expect(panel.forwardLocation == nil && panel.backLocation?.lastPathComponent == "work")
        try work.show("/work/bin", history: .keep)
        #expect(panel.backLocation?.lastPathComponent == "work")
    }

    /// An update that finds nothing new says so; one that does keeps the cursor, the marks and
    /// the calculated folder sizes, or moves the cursor to the entry asked for.
    @Test
    internal func updateKeepsCursorSelectionAndFolderSizes() throws {
        panel.moveCursor(to: try row("b.md"))
        panel.toggleSelection(row: try row("a.txt"))
        panel.setComputedSize(4_096, forName: "docs")
        #expect(!panel.update(with: try work.listing("/work")))
        work.memory.addFile("/work/0-new.txt")
        #expect(panel.update(with: try work.listing("/work")))
        #expect(panel.cursorItem?.name == "b.md")
        #expect(panel.selection == ["a.txt"])
        #expect(panel.items.first { $0.name == "docs" }?.computedSize == 4_096)
        #expect(panel.update(with: try work.listing("/work"), focus: "0-new.txt"))
        #expect(panel.cursorItem?.name == "0-new.txt")
    }

    /// Checks that the cursor stays on its row, now the next entry, when its entry is gone.
    @Test
    internal func aVanishedCursorItemLeavesTheCursorInPlace() throws {
        panel.moveCursor(to: try row("a.txt"))
        work.memory.removeTree("/work/a.txt")
        panel.update(with: try work.listing("/work"))
        #expect(panel.cursorItem?.name == "b.md")
    }

    /// Checks which kind of change is announced for the cursor, the marks, another order and
    /// another folder, and that setting the cursor to where it is announces nothing.
    @Test
    internal func everyChangeIsAnnounced() throws {
        var changes: [PanelModel.Change] = []
        panel.onChange = { changes.append($0) }
        panel.moveCursor(to: 2)
        panel.toggleSelection(row: 2)
        panel.selectAll()
        panel.setSort(ListOrder(key: .size))
        try work.show("/work/docs")
        panel.cursor = 0
        #expect(changes == [.cursor, .selection, .selection, .contents, .contents])
    }

    /// The row of the entry called `name`.
    private func row(_ name: String) throws -> Int {
        try #require(panel.row(ofName: name))
    }
}
