import AFMContracts
import AFMKernel
import AppKit

/// Mouse and keyboard in the list, the same in every view (spec 05 › Mouse selection modes),
/// and what the list itself does for the shell's commands.
extension PanelViewController: NSUserInterfaceValidations {
    /// The standard editing actions the lists answer through the responder chain, and the role
    /// each stands for: the panel's command of that role runs.
    internal static let editingActions: [Selector: EditingRole] = [
        #selector(cut(_:)): .cut, #selector(copy(_:)): .copy, #selector(paste(_:)): .paste
    ]

    /// Rows that fit in the list, for Page Up and Page Down.
    internal var pageSize: Int {
        showsGrid ? gridView.geometry.pageSize : max(1, tableView.rows(in: tableView.visibleRect).length - 1)
    }

    /// The command a menu item stands for; nil for an item that is no command's.
    internal static func command(of item: any NSValidatedUserInterfaceItem) -> CommandID? {
        (item as? NSMenuItem).flatMap { MenuBuilder.command(of: $0) }
    }

    /// The characters of a key press that types something; nil for function and control keys.
    internal static func typedText(of event: NSEvent) -> String? {
        guard let characters = event.characters, let scalar = characters.unicodeScalars.first,
            scalar.value >= 0x20, scalar.value != 0x7F, !(0xF700...0xF8FF).contains(scalar.value)
        else {
            return nil
        }
        return characters
    }

    /// Space: toggles the item; on a newly selected folder also calculates its size, on all
    /// cores, in the background.
    internal func toggleSelectionWithSize() {
        guard let item = model.cursorItem else {
            return
        }
        let tab = model
        tab.toggleSelection(row: tab.cursor)
        guard item.isFolder, tab.isSelected(item), item.computedSize == nil,
            let provider = try? kernel.fileSystems.provider(for: item.url)
        else {
            return
        }
        let directory = tab.directory
        let flag = sizeCalculations[ObjectIdentifier(tab)] ?? CancellationFlag()
        sizeCalculations[ObjectIdentifier(tab)] = flag
        // In the lane of the folder that is measured: a server that does not answer holds up
        // the measuring of that folder, and nothing else.
        Background.storage(
            "size",
            at: item.url,
            work: { provider.totalSize(of: item.url, cancellation: flag) },
            then: { [weak self] size in
                guard !flag.isCancelled, tab.directory.isSameLocation(as: directory) else {
                    return
                }
                self?
                    .sizeArrived(
                        size,
                        forName: item.name,
                        in: tab,
                        arrivals: PanelSizeArrivals(directory: directory, flag: flag, sizes: [])
                    )
            }
        )
    }

    /// Insert and Shift+arrows: toggles the item and moves the cursor by `delta`.
    internal func toggleSelectionAndMove(_ delta: Int) {
        model.toggleSelection(row: model.cursor)
        model.moveCursor(to: model.cursor + delta)
    }

    /// A double click in the table opens the item.
    @objc
    internal func rowDoubleClicked() {
        doubleClicked(row: tableView.clickedRow)
    }

    /// A double click on row `row` (-1 beside the rows) opens the item under the cursor.
    internal func doubleClicked(row: Int) {
        if row >= 0 {
            commands.perform(.open, .nothing)
        }
    }

    /// Marking with the mouse: Cmd+click toggles an item, Shift+click selects the range from the
    /// cursor (spec 05 › Mouse selection modes, the Mac's own conventions).
    ///
    /// Returns false for a plain click, which is left to the list.
    internal func handleClick(row: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        // Marking is refused while a job runs, like the other commands that change what a job
        // may be working on; a plain click only moves the cursor, as the keys do.
        if modifiers.contains(.command) {
            guard !commands.isBlocked() else {
                return true
            }
            model.toggleSelection(row: row)
        } else if modifiers.contains(.shift) {
            guard !commands.isBlocked() else {
                return true
            }
            model.setSelected(true, rows: min(row, model.cursor)...max(row, model.cursor))
        } else {
            return false
        }
        model.moveCursor(to: row)
        return true
    }

    /// A list of the panel got the keyboard: the panel is the source.
    internal func didBecomeFirstResponder() {
        host?.panelDidBecomeActive(self)
    }

    /// Every key is looked up in the key bindings; a key that is bound to nothing goes on to the
    /// list.
    ///
    /// Returns false for such a key.
    ///
    /// Two keys are the list's own. Esc takes a quick filter away (it cannot be bound, and it
    /// means nothing else here). And in the Brief and Thumbnails views ← and →, as long as
    /// they have their usual meaning of first and last entry, step sideways through the grid
    /// instead (spec 03 › Brief).
    internal func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53, quickFilters[ObjectIdentifier(model)] != nil {
            removeQuickFilter()
            return true
        }
        guard var command = kernel.keyBindings.command(for: event) else {
            return false
        }
        if showsGrid, KeyModifiers(event.modifierFlags).isEmpty {
            if event.keyCode == 123, command == .cursorToFirstEntry {
                command = PanelShellCommands.cursorLeft
            }
            if event.keyCode == 124, command == .cursorToLastEntry {
                command = PanelShellCommands.cursorRight
            }
        }
        commands.perform(command, .nothing)
        return true
    }

    /// A key pressed in a list: a bound key runs its command (`handleKey`); in the grid an arrow
    /// key that is bound to nothing moves the cursor (`arrowsMoveCursor`), as it does in the table;
    /// a key that types something finds a file by the start of its name.
    ///
    /// Returns false for a key that is the list's own business.
    internal func handleListKey(_ event: NSEvent, arrowsMoveCursor: Bool) -> Bool {
        if handleKey(event) {
            return true
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let arrows: [UInt16: GridGeometry.Direction] = [
            123: .leftArrow, 124: .rightArrow, 125: .downArrow, 126: .upArrow
        ]
        if arrowsMoveCursor, modifiers.isEmpty, let direction = arrows[event.keyCode] {
            moveCursor(direction)
            return true
        }
        guard modifiers.isDisjoint(with: [.command, .control]), let typed = Self.typedText(of: event) else {
            return false
        }
        typeToFind(typed, at: event.timestamp)
        return true
    }

    /// The context menu of a row (-1: of the list's free space), which gets the cursor first.
    internal func contextMenu(forRow row: Int) -> NSMenu? {
        if row >= 0 {
            model.moveCursor(to: row)
        }
        let onItem = row >= 0 && model.item(atRow: row) != nil
        return MenuBuilder.menu("", kernel.menus.contextMenu(onItem: onItem), commands: commands, keys: nil)
    }

    /// Cmd+X in a list: the panel's command of the Cut role.
    @objc
    internal func cut(_: Any?) {
        perform(.cut)
    }

    /// Cmd+C in a list: the panel's command of the Copy role.
    @objc
    internal func copy(_: Any?) {
        perform(.copy)
    }

    /// Cmd+V in a list: the panel's command of the Paste role.
    @objc
    internal func paste(_: Any?) {
        perform(.paste)
    }

    /// Cut, Copy and Paste can be chosen while the panel's command of their role can run;
    /// whatever else reaches the panel can be chosen.
    @objc
    internal func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard let action = item.action, let role = Self.editingActions[action] else {
            return true
        }
        return commands.command(with: role).map(commands.isEnabled) ?? false
    }

    /// A folder size came in.
    ///
    /// Sizes that come in the same turn of the main loop are taken by the tab together (`arrivals`
    /// says for which folder and calculation).
    private func sizeArrived(_ size: Int64, forName name: String, in tab: PanelModel, arrivals: PanelSizeArrivals) {
        let id = ObjectIdentifier(tab)
        if arrivedSizes[id] != nil {
            arrivedSizes[id]?.sizes.append((name: name, size: size))
            return
        }
        var arrivals = arrivals
        arrivals.sizes = [(name: name, size: size)]
        arrivedSizes[id] = arrivals
        MainLoop.perform { [weak self, weak tab] in
            guard let self, let pending = arrivedSizes.removeValue(forKey: id), let tab else {
                return
            }
            takeSizes(pending, into: tab)
        }
    }

    /// The tab takes the sizes that came in, unless it has moved on meanwhile.
    private func takeSizes(_ pending: PanelSizeArrivals, into tab: PanelModel) {
        guard !pending.flag.isCancelled, tab.directory.isSameLocation(as: pending.directory) else {
            return
        }
        guard tab.listedItems.count >= Self.backgroundSortThreshold else {
            tab.setComputedSizes(pending.sizes)
            return
        }
        // A long list is shared with whoever holds it besides the tab (the listing cache,
        // a snapshot), and writing a size into it copies it once: that copy is made in the
        // background, and the main thread only puts it in the list's place.
        let (sizes, flag, directory) = (pending.sizes, pending.flag, pending.directory)
        let change = PanelListChange(
            of: tab,
            count: 0,
            while: { [weak tab] in !flag.isCancelled && tab?.directory.isSameLocation(as: directory) == true },
            by: { PanelModel.prepare($0, computedSizes: sizes) }
        )
        apply(change) { _ in
            // The model announces the sizes.
        }
    }
}
