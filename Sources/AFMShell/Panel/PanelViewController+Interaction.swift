import AFMContracts
import AFMKernel
import AppKit

/// The quick filter, the path bar, the menus of tabs and path, and drag and drop: what a
/// panel does the same way in every view.
extension PanelViewController {
    // MARK: Quick filter (spec 03 › Quick filter)

    /// Opens the filter field of the active tab and puts the keyboard into it. A filter that
    /// is already on is shown, ready to be changed.
    func showQuickFilter() {
        let id = ObjectIdentifier(model)
        if quickFilters[id] == nil {
            quickFilters[id] = QuickFilter(text: "", base: model.filter, directory: model.directory)
        }
        showQuickFilterBar()
        quickFilterBar.beginEditing()
    }

    /// Shows the field when the active tab has a quick filter, with its text.
    func showQuickFilterBar() {
        let filter = quickFilters[ObjectIdentifier(model)]
        // A field that goes away while it has the keyboard hands it back to the list.
        if filter == nil, quickFilterBar.isEditing { view.window?.makeFirstResponder(listView) }
        quickFilterBar.isHidden = filter == nil
        // The text in the field is ahead of the filter while typing waits for the list.
        if let filter, pendingQuickFilter == nil, quickFilterBar.text != filter.text {
            quickFilterBar.text = filter.text
        }
    }

    /// The text of the active tab's quick filter; nil when it has none.
    var quickFilterText: String? { quickFilters[ObjectIdentifier(model)]?.text }

    /// How long typing in the field waits for the next key before the list is filtered: the list
    /// is filtered once for a burst of keys, not once per key.
    static let quickFilterDelay: TimeInterval = 0.1

    /// Something was typed into the field: the list follows in a moment.
    func quickFilterEdited(_ text: String) {
        pendingQuickFilter?()
        let tab = model
        pendingQuickFilterTyping = (tab, text)
        pendingQuickFilter = MainLoop.after(Self.quickFilterDelay) { [weak self] in
            guard let self else { return }
            pendingQuickFilter = nil
            pendingQuickFilterTyping = nil
            applyQuickFilter(text, to: tab)
        }
    }

    /// Filters the list now, with what is in the field, if keys are still waiting.
    private func flushQuickFilter() {
        guard let cancel = pendingQuickFilter else { return }
        cancel()
        pendingQuickFilter = nil
        pendingQuickFilterTyping = nil
        quickFilterTyped(quickFilterBar.text)
    }

    /// Applies the text typed a moment ago to the tab it was typed in, which is no longer the active one.
    func flushPendingQuickFilter() {
        guard let typing = pendingQuickFilterTyping else { return }
        dropPendingQuickFilter()
        applyQuickFilter(typing.text, to: typing.tab)
    }

    func dropPendingQuickFilter() {
        pendingQuickFilter?()
        pendingQuickFilter = nil
        pendingQuickFilterTyping = nil
    }

    /// Gives `tab` this filter. A long list is filtered in the background, on all cores, from
    /// the list as it is (`PanelModel.prepare`), and the result taken over when that is done
    /// (`apply`), if no newer filtering of the tab has started since; a short one at once.
    /// Should the list have changed meanwhile (more of the folder arrived, it was read again,
    /// it was put in another order), the model takes nothing and the filtering starts again
    /// from the list as it is now, again in the background: never a pass over the whole list
    /// on the main thread. Returns true when it was done at once.
    @discardableResult
    func setFilter(_ filter: PanelFilter?, of tab: PanelModel, narrowing: Bool = false) -> Bool {
        let id = ObjectIdentifier(tab)
        filterJobs[id] = nil
        guard tab.listedItems.count >= Self.backgroundSortThreshold else {
            tab.setFilter(filter, narrowing: narrowing)
            return true
        }
        filterJobCount += 1
        let job = filterJobCount
        filterJobs[id] = job
        change(
            tab, while: { [weak self] in self?.filterJobs[id] == job }, by: { PanelModel.prepare($0, filter: filter) },
            then: { [weak self] outcome in
                guard let self, outcome != nil, filterJobs[id] == job else { return }
                filterJobs[id] = nil
                // Whoever waited for the filter to be in place (the quick filter's field) looks again.
                if tab === model {
                    _ = dropStaleQuickFilter(of: tab)
                    showQuickFilterBar()
                    updateStatus()
                }
            })
        return false
    }

    /// Filters the list by this text.
    func quickFilterTyped(_ text: String) {
        dropPendingQuickFilter()
        applyQuickFilter(text, to: model)
    }

    private func applyQuickFilter(_ text: String, to tab: PanelModel) {
        let id = ObjectIdentifier(tab)
        guard var filter = quickFilters[id], filter.text != text else { return }
        // Typing on narrows the list that the filter has left; anything else starts from all of it.
        let narrows = tab.filter?.title == filter.title && QuickFilter.narrows(from: filter.text, to: text)
        filter.text = text
        quickFilters[id] = filter
        setFilter(filter.combined, of: tab, narrowing: narrows)
    }

    /// Enter or an arrow key in the field: back to the list. The filter stays on, and so does
    /// the field as long as it holds one.
    func leaveQuickFilterField() {
        flushQuickFilter()
        let id = ObjectIdentifier(model)
        if quickFilters[id]?.text.isEmpty == true { quickFilters[id] = nil }
        showQuickFilterBar()
        view.window?.makeFirstResponder(listView)
        updateStatus()
    }

    /// Esc: the filter and the field go away, and the list shows again what the display
    /// filter lets through.
    func removeQuickFilter() {
        dropPendingQuickFilter()
        let tab = model
        filterJobs[ObjectIdentifier(tab)] = nil
        if let filter = quickFilters.removeValue(forKey: ObjectIdentifier(tab)), !filter.text.isEmpty {
            setFilter(filter.base, of: tab)
        }
        showQuickFilterBar()
        updateStatus()
    }

    /// Takes the quick filter of a tab away before the tab shows another folder
    /// (the filter belongs to one folder).
    func dropQuickFilter(of tab: PanelModel, unlessIn directory: URL) {
        let id = ObjectIdentifier(tab)
        guard let filter = quickFilters[id], !filter.directory.isSameLocation(as: directory) else { return }
        quickFilters[id] = nil
        let pending = filterJobs[id] != nil
        filterJobs[id] = nil
        if !filter.text.isEmpty, pending || tab.filter?.title == filter.title { setFilter(filter.base, of: tab) }
    }

    /// Notices that a tab's quick filter is no longer what its model filters by: the folder was
    /// changed behind the panel's back, or a display filter was chosen, which replaces it
    /// (All Files removes a quick filter, spec 03 › Show files of type). Returns true when
    /// this changed the model, which then reports another change.
    func dropStaleQuickFilter(of tab: PanelModel) -> Bool {
        let id = ObjectIdentifier(tab)
        guard let filter = quickFilters[id] else { return false }
        if !filter.directory.isSameLocation(as: tab.directory) {
            quickFilters[id] = nil
            // A filtering of the quick text that is still under way counts as in effect.
            let pending = filterJobs[id] != nil
            guard !filter.text.isEmpty, pending || tab.filter?.title == filter.title else { return false }
            return setFilter(filter.base, of: tab)
        }
        // A filtering under way will bring the filter the quick text stands for.
        if filterJobs[id] != nil { return false }
        if !filter.text.isEmpty, tab.filter?.title != filter.title {
            quickFilters[id] = nil
        } else if filter.text.isEmpty, tab.filter?.title != filter.base?.title {
            // Nothing typed yet, and the display filter below was changed: that one is the base now.
            quickFilters[id] = QuickFilter(text: "", base: tab.filter, directory: filter.directory)
        }
        return false
    }

    // MARK: Path bar (spec 03 › Current-directory bar)

    /// The mask the path bar shows: the display filter, without what the quick filter adds.
    private var displayMask: String {
        let title = quickFilters[ObjectIdentifier(model)].map { $0.base?.title ?? "" } ?? model.filter?.title ?? ""
        return title.isEmpty ? "*.*" : title
    }

    /// What the path bar says, e.g. `/Users/me/*.*`.
    var pathBarText: String { pathBar.text }

    /// Writes the path with the display mask into the bar, with every folder on the way as a
    /// part that can be clicked. The folders above come from the file system's arithmetic on
    /// the location, which reads nothing.
    func updatePathBar() {
        let directory = model.directory
        let path = kernel.fileSystems.displayPath(directory)
        var ancestors: [(location: URL, path: String)] = []
        if let provider = try? kernel.fileSystems.provider(for: directory) {
            var current: URL? = directory
            while let location = current, ancestors.count < 200 {
                ancestors.append((location, provider.displayPath(location)))
                current = provider.parent(of: location)
            }
        }
        // The parts are cut from the path as it is; what is shown has every character that
        // could mislead replaced by one that can be seen, one for one, so the parts stay where they are.
        pathBar.update(
            text: DisplayText.clean((path.hasSuffix("/") ? path : path + "/") + displayMask),
            segments: PathBarView.segments(of: path, ancestors: ancestors.reversed()))
        pathBar.toolTip = DisplayText.clean(path)
        updateEjectButton()
    }

    /// The menu of the path bar: copying the path, and the commands about places that are there.
    func pathMenu() -> NSMenu {
        focus()
        let menu = MenuBuilder.menu(
            "", [.editPath, .directoryHotlist, .directoryHistory, nil, .newTab, .reread], commands: commands,
            keys: kernel.keyBindings)
        let copy = NSMenuItem(title: "Copy Path", action: #selector(copyPathChosen), keyEquivalent: "")
        copy.target = self
        menu.insertItem(copy, at: 0)
        if menu.items.count > 1 { menu.insertItem(.separator(), at: 1) }
        return menu
    }

    @objc private func copyPathChosen() { copyPath(to: .general) }

    /// Puts the path of the folder on a pasteboard, as it is written in the bar.
    func copyPath(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(kernel.fileSystems.displayPath(model.directory), forType: .string)
    }

    // MARK: Folder tabs (spec 05 › Folder tabs)

    /// The commands a tab's menu offers when a plugin provides them: those of the shared
    /// vocabulary and the ones the folder-tab plugin may add under these names.
    static let tabMenuCommands: [CommandID?] = [
        .newTab, "cm_RenameTab", "cm_ToggleLockCurrentTab", nil,
        .closeTab, "cm_CloseOtherTabs", "cm_CloseAllTabs", nil,
        .nextTab, .previousTab
    ]

    /// The menu of a tab. The commands act on the active tab of the source panel, so the tab
    /// that was clicked is shown first.
    func tabMenu(forTab index: Int) -> NSMenu? {
        guard !commands.isBlocked() else { return nil }
        focus()
        if index != tabs.activeIndex { commands.perform(.activateTab, .index(index)) }
        return MenuBuilder.menu("", Self.tabMenuCommands, commands: commands, keys: kernel.keyBindings)
    }

    /// A tab was dragged to another place in the strip.
    func moveTab(from index: Int, to destination: Int) {
        guard !commands.isBlocked() else {
            commands.onRejected()
            return
        }
        tabs.moveTab(from: index, to: destination)
    }

    // MARK: Drag and drop (spec 05 › Drag & drop)

    /// What a drop would do.
    struct DropPlan {
        let kind: TransferKind
        let sources: [URL]
        let destination: URL
        /// The row to frame while the mouse is over it; -1 is the list as a whole.
        let row: Int
    }

    /// What a drag that starts on a row carries: all marked items when the row is one of
    /// them, otherwise the row's item alone. Nothing for `[..]` and while a job runs.
    func draggedItems(fromRow row: Int) -> [FileItem] {
        dragPayload(fromRow: row)?.items ?? []
    }

    /// The same as what the drag keeps (`PanelDrop.Payload`). Marked items up to the number
    /// that are written to the pasteboard one by one are listed here; more than that are
    /// listed in the background, from a copy of the marks that costs nothing to take, so a
    /// drag out of a list with a million marks starts as fast as any other.
    func dragPayload(fromRow row: Int) -> PanelDrop.Payload? {
        guard !commands.isBlocked(), let item = model.item(atRow: row) else { return nil }
        guard model.isSelected(row: row) else { return PanelDrop.Payload(items: [item]) }
        let marks = model.operandsSnapshot()
        if marks.markedCount <= PanelDrop.itemsWrittenSingly { return PanelDrop.Payload(items: marks.markedItems()) }
        return PanelDrop.Payload(marked: marks)
    }

    /// Starts a drag from a row: what goes on the pasteboard for it (`PanelDrop.beginDrag`).
    /// Nothing when the row cannot be dragged.
    func draggingItems(forRow row: Int) -> [NSPasteboardItem] {
        dragPayload(fromRow: row).map(PanelDrop.beginDrag) ?? []
    }

    /// What the drag over this panel carries, read from the pasteboard once per drag and not
    /// on every move of the mouse, nor once for each panel it passes.
    func dropSession(for info: any NSDraggingInfo) -> DropSession {
        PanelDrop.session(for: info)
    }

    /// Where a drop on a row goes: into the folder of a folder row, up through `[..]`, and
    /// otherwise into the folder the panel shows (spec 05 › Drop targets).
    func dropDestination(forRow row: Int) -> (location: URL, row: Int) {
        if let item = model.item(atRow: row), item.isFolder { return (item.url, row) }
        if row == 0, model.hasParentRow, let parent = model.parentTarget { return (parent.location, 0) }
        return (model.directory, -1)
    }

    /// Decides what dropping `sources` on a row does; nil when the drop is not taken: while a
    /// job runs, onto a file system that cannot be written, or when it would change nothing.
    func dropPlan(
        for sources: [URL], row: Int, modifiers: NSEvent.ModifierFlags, allowed: NSDragOperation,
        session: DropSession? = nil
    ) -> DropPlan? {
        guard !commands.isBlocked(), model.isListed, let first = sources.first,
            kernel.services.find((any FileTransferService).self) != nil
        else { return nil }
        let target = dropDestination(forRow: row)
        guard kernel.fileSystems.capabilities(for: target.location).contains(.write) else { return nil }
        let sameVolume = PanelDrop.areOnSameVolume(
            first, target.location, mountPoints: session?.mountPoints ?? PanelDrop.mountPoints())
        guard let kind = PanelDrop.kind(modifiers: modifiers, sameVolume: sameVolume, allowed: allowed),
            !(session?.isPointless(kind, into: target.location)
                ?? PanelDrop.isPointless(kind, sources, into: target.location))
        else { return nil }
        return DropPlan(kind: kind, sources: sources, destination: target.location, row: target.row)
    }

    /// The mouse drags something over a row (-1: over no row). Returns what a drop would do
    /// and the row to frame.
    func validateDrop(_ info: any NSDraggingInfo, row: Int) -> (operation: NSDragOperation, row: Int?) {
        let allowed = info.draggingSourceOperationMask
        let session = dropSession(for: info)
        guard
            let plan = dropPlan(
                for: session.sources, row: row, modifiers: NSEvent.modifierFlags, allowed: allowed,
                session: session)
        else { return ([], nil) }
        let operation: NSDragOperation = plan.kind == .copy ? .copy : (allowed.contains(.move) ? .move : .generic)
        return (operation, plan.row)
    }

    /// Something was dropped. The drop is carried out after the drag has ended, so the program
    /// the files came from is not kept waiting while a question is on screen.
    func acceptDrop(_ info: any NSDraggingInfo, row: Int) -> Bool {
        let session = dropSession(for: info)
        // Dropped before the drag's items were all put together: they are now.
        session.finishNow()
        PanelDrop.endSession(session.sequence)
        guard
            let plan = dropPlan(
                for: session.sources, row: row, modifiers: NSEvent.modifierFlags,
                allowed: info.draggingSourceOperationMask, session: session)
        else { return false }
        // From the run loop, like everything that may ask: the question is a dialog.
        MainLoop.dialog { [weak self] in self?.carryOut(plan) }
        return true
    }

    /// Copies or moves what was dropped, through the file-transfer service, which shows the
    /// progress and asks the usual questions. Asks first when the user wants that.
    func carryOut(_ plan: DropPlan) {
        guard !commands.isBlocked(), let transfers = kernel.services.find((any FileTransferService).self) else {
            commands.onRejected()
            return
        }
        if settings.confirmsDrops {
            let verb = plan.kind == .move ? "Move" : "Copy"
            guard
                kernel.ui.choose(
                    PanelDrop.question(plan.kind, count: plan.sources.count),
                    detail: kernel.fileSystems.displayPath(plan.destination), buttons: [verb, "Cancel"],
                    style: .information) == 0
            else { return }
        }
        // A copy dropped into the folder it came from gets a new name, as a pasted one does.
        transfers.transfer(plan.kind, plan.sources, into: plan.destination, renamingSelfCopies: plan.kind == .copy) {
            _ in
        }
    }

    // The table of the Full view drags and takes drops through its data source.

    func tableView(_: NSTableView, pasteboardWriterForRow row: Int) -> any NSPasteboardWriting? {
        // The table drags the row that was grabbed; when that row is marked, all marked items
        // go along: in the program through the drag's ticket, for other programs in `willBeginAt`.
        pendingDragItems = draggingItems(forRow: row)
        return pendingDragItems.first
    }

    func tableView(
        _: NSTableView, draggingSession session: NSDraggingSession, willBeginAt _: NSPoint,
        forRowIndexes _: IndexSet
    ) {
        let items = pendingDragItems
        pendingDragItems = []
        if items.count > 1 {
            session.draggingPasteboard.clearContents()
            session.draggingPasteboard.writeObjects(items)
        }
        PanelDrop.offerFileNames(on: session.draggingPasteboard)
    }

    func tableView(
        _: NSTableView, draggingSession _: NSDraggingSession, endedAt _: NSPoint,
        operation _: NSDragOperation
    ) {
        pendingDragItems = []
        PanelDrop.endDrag()
        PanelDrop.endSession()
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow _: Int,
        proposedDropOperation _: NSTableView.DropOperation
    ) -> NSDragOperation {
        let (operation, target) = validateDrop(
            info, row: tableView.row(at: tableView.convert(info.draggingLocation, from: nil)))
        if let target { tableView.setDropRow(target, dropOperation: .on) }
        return operation
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row _: Int,
        dropOperation _: NSTableView.DropOperation
    ) -> Bool {
        acceptDrop(info, row: tableView.row(at: tableView.convert(info.draggingLocation, from: nil)))
    }
}
