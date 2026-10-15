import AFMKernel
import Foundation
import TestSupport
import Testing

/// The panel model while a folder is entered and while its entries arrive: before the folder
/// is read, when it cannot be read, at the location of a file, and piece by piece.
@MainActor
@Suite
internal struct PanelArrivalTests {
    /// The panel showing `/work`.
    private let work: WorkPanel

    /// The panel model under test.
    private var panel: PanelModel { work.panel }

    /// Shows `/work` of a fresh memory file system.
    internal init() throws {
        work = try WorkPanel()
    }

    /// The panel is in the folder at once (its path, no entries yet, the way back); when the
    /// entries arrive, the visit is in the history once, not twice.
    @Test
    internal func aFolderIsEnteredBeforeItHasBeenRead() throws {
        panel.moveCursor(to: try row("a.txt"))
        panel.toggleSelection(row: panel.cursor)
        // Taking a snapshot first, as the shell does, changes nothing.
        _ = panel.snapshot()
        panel.open(work.memory.url("/work/docs"), parent: work.memory.url("/work"), root: work.memory.url("/"))
        #expect(panel.directory.path == "/work/docs" && panel.isOpening && !panel.isComplete && !panel.isListed)
        #expect(panel.items.isEmpty && panel.rowCount == 1 && panel.cursorIsOnParentRow && panel.selection.isEmpty)
        #expect(panel.parentTarget?.location.path == "/work" && panel.parentTarget?.focus == "docs")
        #expect(panel.backLocation?.path == "/work" && !panel.hasOperands)
        work.memory.addFile("/work/docs/in.txt")
        panel.show(try work.listing("/work/docs"), history: .record, complete: false)
        #expect(!panel.isOpening && panel.isListed && panel.items.map(\.name) == ["in.txt"])
        panel.finishLoading()
        #expect(panel.isComplete && panel.backLocation?.path == "/work" && panel.forwardLocation == nil)
        try work.show("/work", history: .step(-1))
        #expect(panel.backLocation == nil && panel.forwardLocation?.path == "/work/docs")
    }

    /// Back from a folder that cannot be read, everything is as it was: folder, entries,
    /// cursor, marks and the history on both sides.
    @Test
    internal func aFolderThatCannotBeReadIsLeftAgain() throws {
        try work.show("/work/bin")
        try work.show("/work", history: .step(-1))
        panel.moveCursor(to: try row("a.txt"))
        panel.toggleSelection(row: panel.cursor)
        let before = panel.snapshot()
        panel.open(work.memory.url("/work/locked"), parent: work.memory.url("/work"), root: work.memory.url("/"))
        #expect(panel.forwardLocation == nil)
        panel.restore(before)
        #expect(panel.directory.path == "/work" && panel.isListed && panel.isComplete && !panel.isOpening)
        #expect(panel.items.map(\.name) == ["bin", "docs", "a.txt", "b.md"])
        #expect(panel.cursorItem?.name == "a.txt" && panel.selection == ["a.txt"])
        #expect(panel.forwardLocation?.path == "/work/bin" && panel.backLocation == nil)
    }

    /// Opening the location of a file ends in its folder with the cursor on the file; the
    /// history holds the folder, not the file.
    @Test
    internal func openingTheLocationOfAFileEndsInItsFolder() throws {
        let file = work.memory.url("/work/a.txt")
        panel.open(file, parent: work.memory.url("/work"), root: work.memory.url("/"))
        let result = try PanelLoader.load(file, showHidden: false, fileSystems: work.fileSystems)
        try work.show("/work/bin")
        panel.open(file, parent: work.memory.url("/work"), root: work.memory.url("/"))
        panel.show(result.listing, focus: result.focus)
        #expect(panel.directory.path == "/work" && panel.cursorItem?.name == "a.txt")
        #expect(panel.backLocation?.path == "/work/bin")
        try work.show("/work/bin", history: .step(-1))
        #expect(panel.forwardLocation?.path == "/work")
    }

    /// The list grows in sorted order, keeping marks and cursor, and the entry that was asked
    /// for gets the cursor when it arrives.
    @Test
    internal func aDirectoryCanArriveInPieces() throws {
        var soFar = SortedFileList(order: panel.sort)
        soFar.add([try entry("docs"), try entry("b.md")])
        panel.show(piece(soFar.items), focus: "a.txt", complete: false, presorted: soFar.order)
        #expect(!panel.isComplete && panel.items.map(\.name) == ["docs", "b.md"])
        panel.toggleSelection(row: try row("b.md"))
        panel.moveCursor(to: try row("b.md"))
        soFar.add([try entry("bin")])
        panel.extend(to: soFar.items, sortedBy: soFar.order)
        #expect(panel.items.map(\.name) == ["bin", "docs", "b.md"] && panel.cursorItem?.name == "b.md")
        soFar.add([try entry("a.txt")])
        panel.extend(to: soFar.items, sortedBy: soFar.order)
        #expect(panel.items.map(\.name) == ["bin", "docs", "a.txt", "b.md"])
        #expect(panel.cursorItem?.name == "a.txt")
        #expect(panel.selection == ["b.md"])
        panel.finishLoading()
        #expect(panel.isComplete)
    }

    /// Checks that the cursor stays on its entry while the list grows, and on `[..]` when it is there.
    @Test
    internal func theCursorStaysOnItsItemWhileADirectoryGrows() throws {
        let all = Array(try entries().values)
        panel.show(piece([try entry("b.md")]), complete: false)
        panel.moveCursor(to: try row("b.md"))
        panel.extend(to: Sorter.sort(all, by: panel.sort), sortedBy: panel.sort)
        #expect(panel.cursorItem?.name == "b.md" && panel.cursor == 4)
        panel.moveCursor(to: 0)
        let more = all + [FileItem(url: work.memory.url("/work/0.txt"), name: "0.txt")]
        panel.extend(to: Sorter.sort(more, by: panel.sort), sortedBy: panel.sort)
        #expect(panel.cursorIsOnParentRow && panel.items.count == 5)
    }

    /// The background still delivers by name after the order was changed; the panel puts what
    /// arrives into its own order.
    @Test
    internal func aChangedSortOrderIsRespectedWhileADirectoryGrows() throws {
        let byName = ListOrder()
        panel.show(piece([try entry("a.txt")]), complete: false, presorted: byName)
        panel.setSort(ListOrder(key: .size, descending: true))
        panel.extend(
            to: Sorter.sort([try entry("a.txt"), try entry("b.md"), try entry("docs")], by: byName),
            sortedBy: byName
        )
        #expect(panel.items.map(\.name) == ["docs", "a.txt", "b.md"])
    }

    /// The entries of `/work` by name, to hand over in a chosen order.
    private func entries() throws -> [String: FileItem] {
        Dictionary(uniqueKeysWithValues: try work.listing("/work").items.map { ($0.name, $0) })
    }

    /// The entry of `/work` called `name`.
    private func entry(_ name: String) throws -> FileItem {
        try #require(try entries()[name])
    }

    /// A listing of `/work` holding only `items`, as a piece of the whole.
    private func piece(_ items: [FileItem]) -> Listing {
        Listing(
            directory: work.memory.url("/work"),
            items: items,
            parent: work.memory.url("/"),
            root: work.memory.url("/")
        )
    }

    /// The row of the entry called `name`.
    private func row(_ name: String) throws -> Int {
        try #require(panel.row(ofName: name))
    }
}
