import FuzzCore

@testable import AFMKernel

/// The invariants of a `PanelModel` after any operation.
@MainActor
internal enum PanelCheck {
    /// Whether two lists hold the same entries: names as written, kinds, sizes.
    internal static func same(_ lhs: [FileItem], _ rhs: [FileItem]) -> Bool {
        lhs.count == rhs.count
            && zip(lhs, rhs)
                .allSatisfy { left, right in
                    ExactName.areSame(left.name, right.name) && left.isDirectory == right.isDirectory
                        && left.size == right.size && left.computedSize == right.computedSize
                }
    }

    /// Every invariant of `model`; `last` is what it was last given, `ordered` whether its list must be in order.
    internal static func check(_ model: PanelModel, last: ExpectedListing?, what: String, ordered: Bool) {
        checkList(model, last: last, what: what, ordered: ordered)
        let items = model.items
        // A mark belongs to an entry (a place in the list), not to a name: two entries of one name, or of
        // names that read the same, can be marked one without the other.
        let names = items.map { Array($0.name.utf8) }
        let identical = Set(names).count < names.count
        let marked = checkSelection(model, what: what, identical: identical)
        checkOperands(model, what: what, markedRows: marked.rows, markedNames: marked.names)
        checkTotals(model, what: what)
        checkRowsByName(model, what: what, identical: identical)
        fzCheck(model.row(ofName: "\u{1}no such name\u{2}") == nil, "panel-row-of-missing-name", what)
        _ = model.operands()
        _ = model.hasOperands
        _ = model.hasOperandFile
        _ = model.cursorItem
        _ = model.cursorFile
        _ = model.parentTarget
        _ = model.rootTarget
    }

    /// Rows, cursor, and the list: what was listed, filtered, in order.
    private static func checkList(_ model: PanelModel, last: ExpectedListing?, what: String, ordered: Bool) {
        let items = model.items
        let listed = model.listedItems
        let rows = model.rowCount
        let offset = model.hasParentRow ? 1 : 0
        fzCheck(rows == items.count + offset, "panel-rowcount", what)
        fzCheck(
            model.cursor >= 0 && model.cursor <= max(rows - 1, 0),
            "panel-cursor-out-of-range",
            "\(what): cursor \(model.cursor) of \(rows) rows"
        )
        // What is shown is what was listed, filtered.
        let shown = model.filter.map { filter in listed.filter(filter.matches) } ?? listed
        if !same(items, shown) {
            failNotFiltered(model, what: what, items: items, shown: shown)
        }
        if ordered, let index = SortReference.firstOutOfOrder(listed, model.sort) {
            fzFail("panel-list-out-of-order", "\(what) \(model.sort) at \(index): \(describe(listed))")
        }
        if let last {
            let given = last.items.map { Array($0.name.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
            let have = listed.map { Array($0.name.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
            fzCheck(
                given == have,
                "panel-list-not-the-listing",
                "\(what): \(describe(listed)) vs \(describe(last.items))"
            )
        }
    }

    /// Reports where the shown items and the filtered list part.
    private static func failNotFiltered(
        _ model: PanelModel,
        what: String,
        items: [FileItem],
        shown: [FileItem]
    ) -> Never {
        let index =
            zip(items, shown).enumerated().first { !same([$0.element.0], [$0.element.1]) }?.offset
            ?? min(items.count, shown.count)
        let shownText =
            items.indices.contains(index)
            ? describe([items[index]]) + " computed \(String(describing: items[index].computedSize))" : "-"
        let listedText =
            shown.indices.contains(index)
            ? describe([shown[index]]) + " computed \(String(describing: shown[index].computedSize))" : "-"
        fzFail(
            "panel-items-not-filtered-list" + (FuzzState.uniqueNames ? "" : "-identical-names"),
            "\(what): \(items.count) shown, \(shown.count) pass the filter; first difference at \(index): "
                + "shown \(shownText) listed \(listedText)\nall listed: \(describe(model.listedItems))"
        )
    }

    /// Marks, counts, names and the selection set.
    ///
    /// Returns the number of marked rows and the marked names (UTF-16) in list order.
    private static func checkSelection(
        _ model: PanelModel,
        what: String,
        identical: Bool
    ) -> (rows: Int, names: [[UInt16]]) {
        let items = model.items
        let offset = model.hasParentRow ? 1 : 0
        var markedRows = 0
        var markedNames: [[UInt16]] = []
        for row in 0..<model.rowCount where model.isSelected(row: row) {
            markedRows += 1
            if let item = model.item(atRow: row) {
                markedNames.append(Array(item.name.utf16))
            }
        }
        fzCheck(model.isSelected(row: 0) == false || !model.hasParentRow, "panel-parent-row-marked", what)
        fzCheck(
            model.selectionCount == markedRows,
            "panel-selectioncount-vs-marked-rows",
            "\(what): count \(model.selectionCount), \(markedRows) rows"
        )
        fzCheck(model.hasSelection == (markedRows > 0), "panel-hasselection", what)
        // `selectedNames`: one per marked entry, as written, in the order of the list.
        fzCheck(
            model.selectedNames.map { Array($0.utf16) } == markedNames,
            "panel-selectednames-vs-marked-rows",
            "\(what): \(model.selectedNames.count) names, \(markedRows) rows"
        )
        // `selection` is a set of names: one member for names that read the same (documented), never more
        // members than marks, and exactly the marked names.
        let selection = model.selection
        fzCheck(
            selection.count <= model.selectionCount && selection.isEmpty == (markedRows == 0),
            "panel-selection-set-size",
            "\(what): \(selection.count) vs \(model.selectionCount)"
        )
        fzCheck(selection == Set(model.selectedNames), "panel-selection-set-vs-selectednames", what)
        for (index, item) in items.enumerated() where !identical {
            fzCheck(
                model.isSelected(item) == model.isSelected(row: index + offset),
                "panel-isselected-item-vs-row",
                "\(what): row \(index + offset) \(describe([item]))"
            )
        }
        return (markedRows, markedNames)
    }

    /// The operands are the marked entries; without marks, the entry under the cursor.
    private static func checkOperands(_ model: PanelModel, what: String, markedRows: Int, markedNames: [[UInt16]]) {
        let operands = model.operands()
        if markedRows > 0 {
            fzCheck(
                operands.map { Array($0.name.utf16) } == markedNames,
                "panel-operands-vs-marked-rows",
                "\(what): \(operands.count) operands, \(markedRows) marked rows"
            )
        } else {
            fzCheck(operands.count <= 1, "panel-operands-without-marks", "\(what): \(operands.count)")
        }
        fzCheck(model.hasOperands == !operands.isEmpty, "panel-hasoperands", what)
        fzCheck(model.hasOperandFile == operands.contains { !$0.isDirectory }, "panel-hasoperandfile", what)
    }

    /// The totals, added up from the shown items and the marks.
    private static func checkTotals(_ model: PanelModel, what: String) {
        let items = model.items
        let offset = model.hasParentRow ? 1 : 0
        var want = PanelModel.Totals()
        for (index, item) in items.enumerated() {
            let size = item.isFolder ? (item.computedSize ?? 0) : item.size
            want.totalBytes = want.totalBytes.addingSaturated(size)
            if item.isFolder {
                want.totalFolders += 1
            } else {
                want.totalFiles += 1
            }
            if model.isSelected(row: index + offset) {
                want.selectedBytes = want.selectedBytes.addingSaturated(size)
                if item.isFolder {
                    want.selectedFolders += 1
                } else {
                    want.selectedFiles += 1
                }
            }
        }
        let have = model.totals
        fzCheck(have == want, "panel-totals", "\(what): have \(have) want \(want) of \(describe(items))")
    }

    /// Every shown item is found by its name, in its row.
    private static func checkRowsByName(_ model: PanelModel, what: String, identical: Bool) {
        let items = model.items
        let offset = model.hasParentRow ? 1 : 0
        for (index, item) in items.enumerated() {
            guard let row = model.row(ofName: item.name) else {
                fzFail("panel-row-of-name-nil", "\(what): \(describe([item])) at \(index) of \(describe(items))")
            }
            guard let found = model.item(atRow: row) else {
                fzFail("panel-row-of-name-out-of-range", "\(what): row \(row)")
            }
            fzCheck(
                ExactName.areSame(found.name, item.name),
                "panel-row-of-name-other-item",
                "\(what): asked \(describe([item])) got \(describe([found]))"
            )
            if !identical {
                fzCheck(row == index + offset, "panel-row-of-name-wrong-row", "\(what): \(row) vs \(index + offset)")
            }
        }
    }
}
