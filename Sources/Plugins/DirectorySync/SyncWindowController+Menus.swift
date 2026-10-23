import AFMContracts
import AFMKernel
import AppKit

/// Menus: the context menu of the rows and the menu of the saved sets.
extension SyncWindowController {
    /// What a menu item of the window runs.
    internal final class MenuAction: NSObject {
        /// The work of the item.
        private let run: () -> Void

        /// An action that runs `run`.
        internal init(_ run: @escaping () -> Void) {
            self.run = run
        }

        /// Called by the menu item.
        @objc
        internal func runAction() { run() }
    }

    /// Fills a menu as it opens: the rows' context menu, or the saved sets.
    internal func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === rowMenu {
            buildRowMenu()
        } else {
            buildSetsMenu(menu)
        }
    }

    /// A menu item that runs `action`; `key` with Control is its shortcut, shown in the menu.
    private func item(_ title: String, _ key: String, enabled: Bool, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.runAction), keyEquivalent: key)
        let target = MenuAction(action)
        // The item holds its target weakly; the represented object keeps it.
        item.target = target
        item.representedObject = target
        item.keyEquivalentModifierMask = .control
        item.isEnabled = enabled
        return item
    }

    /// The context menu of the rows (spec 09 › Result list); it acts on the selected rows.
    private func buildRowMenu() {
        let rows = selectedRows
        rowMenu.autoenablesItems = false
        rowMenu.items = rows.isEmpty ? [] : markItems(rows) + [.separator()] + fileItems(rows.first) + deleteItems(rows)
    }

    /// The items that mark the rows for copying in a direction, or for none.
    private func markItems(_ rows: [Int]) -> [NSMenuItem] {
        [
            item("Mark for copying (default direction)", "d", enabled: true) { [session] in
                session.markDefault(rows: rows)
            },
            item("Unmark for copying (skip)", "m", enabled: true) { [session] in
                session.setAction(.nothing, rows: rows)
            },
            item("Mark for copying -> (left to right)", "l", enabled: true) { [session] in
                session.setAction(.copyToRight, rows: rows)
            },
            item("Mark for copying <- (right to left)", "r", enabled: true) { [session] in
                session.setAction(.copyToLeft, rows: rows)
            },
            item("Mark for copying in reverse direction", "w", enabled: true) { [session] in
                session.reverse(rows: rows)
            }
        ]
    }

    /// The items that pick, compare, view and edit the files of the first selected row.
    private func fileItems(_ first: Int?) -> [NSMenuItem] {
        let hasLeft = first.flatMap { row in session.url(.left, row: row) } != nil
        let hasRight = first.flatMap { row in session.url(.right, row: row) } != nil
        let canCompare = hasLeft || hasRight || (session.picked.left != nil && session.picked.right != nil)
        func open(_ title: String, _ side: SyncSide, _ command: CommandID, enabled: Bool) -> NSMenuItem {
            item(title, "", enabled: enabled) { [session] in
                if let first {
                    session.view(side, row: first, command: command)
                }
            }
        }
        return [
            item("Select left file for comparison", "", enabled: hasLeft) { [session] in
                if let first {
                    session.pick(.left, row: first)
                }
            },
            item("Select right file for comparison", "", enabled: hasRight) { [session] in
                if let first {
                    session.pick(.right, row: first)
                }
            },
            item("Compare left & right", "", enabled: canCompare) { [session] in session.compareContents(row: first) },
            .separator(),
            open("View left", .left, .view, enabled: hasLeft),
            open("View right", .right, .view, enabled: hasRight),
            open("Edit left", .left, .edit, enabled: hasLeft),
            open("Edit right", .right, .edit, enabled: hasRight)
        ]
    }

    /// The items that mark the rows for deletion.
    private func deleteItems(_ rows: [Int]) -> [NSMenuItem] {
        [
            .separator(),
            item("<- Delete left", "", enabled: true) { [session] in session.setAction(.deleteLeft, rows: rows) },
            item("-> Delete right", "", enabled: true) { [session] in session.setAction(.deleteRight, rows: rows) },
            item("Delete on both sides", "", enabled: true) { [session] in session.setAction(.deleteBoth, rows: rows) }
        ]
    }

    /// The menu of the saved sets: adding the current one, loading one, removing one.
    private func buildSetsMenu(_ menu: NSMenu) {
        let sets = session.savedSets
        var items = [
            NSMenuItem(title: "★", action: nil, keyEquivalent: ""),
            item("Add current directories and settings to list…", "", enabled: true) { [weak self] in
                self?.saveSet()
            }
        ]
        if !sets.isEmpty {
            items.append(.separator())
            items += sets.map { set in
                item(set.name, "", enabled: true) { [weak self] in
                    self?.session.loadSet(named: set.name)
                    self?.pullControls()
                }
            }
            let remove = NSMenuItem(title: "Remove", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.items = sets.map { set in
                item(set.name, "", enabled: true) { [session] in session.removeSet(named: set.name) }
            }
            remove.submenu = submenu
            items += [.separator(), remove]
        }
        menu.items = items
    }

    /// Asks for a name and saves the directories and settings under it.
    private func saveSet() {
        pushControls()
        guard
            let name = kernel.interaction.prompt("Name under which the directories and settings are saved:", value: "")?
                .trimmingCharacters(in: .whitespaces), !name.isEmpty
        else {
            return
        }
        session.saveSet(named: name)
    }
}
