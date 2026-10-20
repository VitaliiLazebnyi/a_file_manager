import AFMKernel
import AppKit
import Testing

@testable import AFMShell

/// What the lists write: the columns of a row, the status line, and names that could mislead
/// (spec 03 › Rows in Full view, 03 › Status line); and what the cells tell the accessibility
/// interface.
@MainActor
@Suite
internal struct PanelTextTests {
    /// An entry at `/x`.
    private func item(_ name: String, kind: FileItem.Kind, size: Int64) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/x/" + name), name: name, kind: kind, stat: .init(size: size))
    }

    /// The Brief view's status line describes the item under the cursor.
    @Test
    internal func theBriefViewsStatusLineDescribesTheItemUnderTheCursor() {
        let file = FileItem(
            url: URL(fileURLWithPath: "/x/win.ini"),
            name: "win.ini",
            stat: .init(size: 1_234, modified: Date(timeIntervalSince1970: 0), permissions: 0o644)
        )
        let text = PanelViewController.detailText(for: file)
        #expect(text.hasPrefix("win  ini  1,234  ") && text.hasSuffix("  rw-r--r--"))
        #expect(
            PanelViewController.detailText(for: item("docs", kind: .directory, size: 0)).hasPrefix("[docs]  <DIR>  ")
        )
    }

    /// The status line counts the marks and the totals; while a folder arrives it says so.
    @Test
    internal func theStatusLineCountsWhatIsMarked() {
        var totals = PanelModel.Totals()
        totals.totalFiles = 14
        totals.selectedFiles = 4
        totals.totalBytes = 8_192
        totals.selectedBytes = 5_120
        #expect(
            PanelViewController.statusText(totals, itemsSoFar: nil, refreshing: false) == "5 k / 8 k in 4 / 14 file(s)"
        )
        totals.totalFolders = 2
        #expect(PanelViewController.statusText(totals, itemsSoFar: nil, refreshing: false).hasSuffix(", 0 / 2 dir(s)"))
        #expect(
            PanelViewController.statusText(totals, itemsSoFar: 1_500, refreshing: false)
                .hasPrefix("Loading… 1,500 items so far   ")
        )
        #expect(PanelViewController.statusText(totals, itemsSoFar: nil, refreshing: true).hasPrefix("Refreshing…   "))
    }

    /// Each column writes its part of a row; `[..]` has a name and `<DIR>` only; a folder
    /// shows its calculated size, or what it is.
    @Test
    internal func eachColumnWritesItsPartOfARow() {
        #expect(FileListColumn.fullView.map(\.title) == ["Name", "Ext", "Size", "Date", "Attr"])
        #expect(FileListColumn.fullView.map { $0.text(for: nil) } == ["[..]", "", "<DIR>", "", ""])
        var folder = item("docs", kind: .directory, size: 0)
        #expect(FileListColumn.size.text(for: folder) == "<DIR>" && FileListColumn.name.text(for: folder) == "[docs]")
        folder.computedSize = 2_048
        #expect(FileListColumn.size.text(for: folder) == "2,048")
        #expect(FileListColumn.size.text(for: item("App.app", kind: [.directory, .package], size: 0)) == "<PKG>")
        #expect(FileListColumn.size.text(for: item("link", kind: [.directory, .symlink], size: 0)) == "<LNK>")
        #expect(FileListColumn.size.text(for: item("a.txt", kind: [], size: 7)) == "7")
        #expect(FileListColumn.fullView.map(\.sortKey) == [.name, .ext, .size, .date, nil])
        #expect(FileListColumn.fullView.map { $0.sortCommand == nil } == [false, false, false, false, true])
        #expect(FileListColumn.size.makeTableColumn().headerCell.alignment == .right)
    }

    /// Names that could mislead are shown with every character visible, one for one.
    @Test
    internal func namesThatCouldMisleadAreShownWithEveryCharacterVisible() {
        let evil = FileItem(url: URL(fileURLWithPath: "/x/evil\u{202E}txt.exe"), name: "evil\u{202E}txt.exe")
        #expect(FileListColumn.name.text(for: evil) == "evil\u{FFFD}txt")
        #expect(
            GridCellPainter.caption(for: evil) == "evil\u{FFFD}txt.exe" && GridCellPainter.caption(for: nil) == "[..]"
        )
        #expect(GridCellPainter.caption(for: item("docs", kind: .directory, size: 0)) == "[docs]")
    }

    /// The cells of the list are static texts called by their column, with what they show as
    /// their value (an empty one says so); the label itself is no element: it would have no role.
    @Test
    internal func theCellsTellTheAccessibilityInterfaceWhatTheyShow() throws {
        let file = item("a.txt", kind: [], size: 7)
        for column in FileListColumn.fullView {
            let cell = column.makeCell()
            let field = try #require(cell.textField)
            let element = try #require(field.cell)
            #expect(element.accessibilityLabel() == column.title && element.accessibilityRole() == .staticText)
            column.fill(cell, with: RowLook(item: nil, color: .labelColor, ownIcons: false))
            #expect(element.accessibilityValue() as? String == column.text(for: nil), "\(column) of [..]")
            column.fill(cell, with: RowLook(item: file, color: .labelColor, ownIcons: false))
            #expect(element.accessibilityValue() as? String == column.text(for: file), "\(column) of a file")
            #expect(element.isAccessibilityElement() && !field.isAccessibilityElement(), "\(column)")
        }
        // The dashes of the permissions are drawn heavier than the digits of the other columns.
        let attr = FileListColumn.attr.makeCell().textField?.font
        #expect(attr == .monospacedDigitSystemFont(ofSize: 12, weight: .medium))
        #expect(
            FileListColumn.date.makeCell().textField?.font == .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        )
        let name = FileListColumn.name.makeCell()
        name.textField?.textColor = .labelColor
        FileListColumn.name.fill(
            name,
            with: RowLook(item: item(".hidden", kind: .hidden, size: 0), color: .systemRed, ownIcons: false)
        )
        #expect(name.textField?.textColor == .systemRed && name.imageView?.alphaValue == 0.5)
        #expect(FileListColumn.makeExtraCell().identifier == FileListColumn.extraCellIdentifier)
    }
}
