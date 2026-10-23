import AFMContracts
import AFMKernel
import Foundation

/// Rows: the actions the user gives them, and their files opened, viewed and compared.
extension SyncSession {
    // MARK: Actions of rows

    /// Sets the action of every given row that can take it.
    internal func setAction(_ action: SyncAction, rows indexes: [Int]) {
        change(indexes) { row in row.accepts(action) ? action : row.action }
    }

    /// "Mark for copying (default direction)".
    internal func markDefault(rows indexes: [Int]) {
        change(indexes) { row in row.defaultAction }
    }

    /// "Reverse copy direction": a copy goes the other way where the other side has the file.
    internal func reverse(rows indexes: [Int]) {
        change(indexes) { row in row.reversedAction }
    }

    /// Space: switches each row between its default action and none.
    internal func toggle(rows indexes: [Int]) {
        change(indexes) { row in row.action == .nothing ? row.defaultAction : .nothing }
    }

    /// A click on the middle column.
    internal func cycle(row index: Int) {
        change([index]) { row in row.nextAction }
    }

    /// Gives each row the action `action` makes of it, and tells the window which rows changed.
    private func change(_ indexes: [Int], _ action: (SyncRow) -> SyncAction) {
        // While the plan is made nothing may change under it.
        guard !isPlanning else {
            return
        }
        var touched: [Int] = []
        for index in indexes where rows.indices.contains(index) {
            let new = action(rows[index])
            guard new != rows[index].action else {
                continue
            }
            let wasActionable = Self.isActionable(rows[index])
            rows[index].action = new
            actionEpoch += 1
            if positions.indices.contains(index), positions[index] >= 0 {
                actionableCount += (Self.isActionable(rows[index]) ? 1 : 0) - (wasActionable ? 1 : 0)
            }
            touched.append(index)
        }
        if let onRowsChange {
            onRowsChange(touched)
        } else {
            changed()
        }
    }

    // MARK: Files of rows

    /// The file of a row on one side; nil for a folder, or where the side has none.
    internal func url(_ side: SyncSide, row index: Int) -> URL? {
        guard rows.indices.contains(index), !rows[index].isDirectory else {
            return nil
        }
        return side == .left ? rows[index].left?.url : rows[index].right?.url
    }

    /// Opens a row's file of one side with `command` (View or Edit).
    internal func view(_ side: SyncSide, row index: Int, command: CommandID) {
        guard let url = url(side, row: index) else {
            return
        }
        kernel.commands.perform(command, .location(url))
    }

    /// "Select for comparison": remembers a file of one side for "Compare left & right".
    internal func pick(_ side: SyncSide, row index: Int) {
        guard let url = url(side, row: index) else {
            return
        }
        if side == .left {
            picked.left = url
        } else {
            picked.right = url
        }
        changed()
    }

    /// "Compare left & right": the two picked files when one was picked on each side, else
    /// the two files of the row.
    ///
    /// The comparison tool is another plugin's command; it is handed the two locations as two lines
    /// of text.
    internal func compareContents(row index: Int?) {
        var files = (left: picked.left, right: picked.right)
        if files.left == nil || files.right == nil {
            guard let index else {
                return
            }
            files = (url(.left, row: index), url(.right, row: index))
        }
        guard files.left != nil || files.right != nil else {
            return
        }
        guard kernel.commands[.compareByContent] != nil else {
            kernel.interaction.inform("Compare by content is not available.")
            return
        }
        picked = (nil, nil)
        kernel.commands.perform(
            .compareByContent,
            .text((files.left?.absoluteString ?? "") + "\n" + (files.right?.absoluteString ?? ""))
        )
        changed()
    }
}
