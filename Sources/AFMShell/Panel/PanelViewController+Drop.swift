import AFMContracts
import AFMKernel
import AppKit

/// Drag and drop (spec 05 › Drag & drop): what a drag that starts in the panel carries, and
/// what dropping something on it does, the same in every view.
extension PanelViewController {
    /// What a drag that starts on a row carries: all marked items when the row is one of them,
    /// otherwise the row's item alone.
    ///
    /// Nothing for `[..]` and while a job runs. Marked items up to the number that are written to
    /// the pasteboard one by one are listed here; more than that are listed in the background, from
    /// a copy of the marks that costs nothing to take, so a drag out of a list with a million marks
    /// starts as fast as any other.
    internal func dragPayload(fromRow row: Int) -> PanelDragPayload? {
        guard !commands.isBlocked(), let item = model.item(atRow: row) else {
            return nil
        }
        guard model.isSelected(row: row) else {
            return PanelDragPayload(items: [item])
        }
        let marks = model.operandsSnapshot()
        if marks.markedCount <= PanelDrop.itemsWrittenSingly {
            return PanelDragPayload(items: marks.markedItems())
        }
        return PanelDragPayload(marked: marks)
    }

    /// Starts a drag from a row: what goes on the pasteboard for it (`PanelDrop.beginDrag`).
    ///
    /// Nothing when the row cannot be dragged.
    internal func draggingItems(forRow row: Int) -> [NSPasteboardItem] {
        dragPayload(fromRow: row).map(PanelDrop.beginDrag) ?? []
    }

    /// Where a drop on a row goes: into the folder of a folder row, up through `[..]`, and
    /// otherwise into the folder the panel shows (spec 05 › Drop targets); with the row to frame
    /// (-1: the list as a whole).
    internal func dropDestination(forRow row: Int) -> (location: URL, row: Int) {
        if let item = model.item(atRow: row), item.isFolder {
            return (item.url, row)
        }
        if row == 0, model.hasParentRow, let parent = model.parentTarget {
            return (parent.location, 0)
        }
        return (model.directory, -1)
    }

    /// Decides what dropping what `session` carries on a row does, with these keys held and
    /// what the source allows; nil when the drop is not taken: while a job runs, onto a file
    /// system that cannot be written, or when it would change nothing.
    internal func dropPlan(
        for session: DropSession,
        row: Int,
        modifiers: NSEvent.ModifierFlags,
        allowed: NSDragOperation
    ) -> PanelDropPlan? {
        guard !commands.isBlocked(), model.isListed, let first = session.sources.first,
            kernel.services.find((any FileTransferService).self) != nil
        else {
            return nil
        }
        let target = dropDestination(forRow: row)
        guard kernel.fileSystems.capabilities(for: target.location).contains(.write) else {
            return nil
        }
        let sameVolume = PanelDrop.areOnSameVolume(first, target.location, mountPoints: session.mountPoints)
        guard let kind = PanelDrop.kind(modifiers: modifiers, sameVolume: sameVolume, allowed: allowed),
            !session.isPointless(kind, into: target.location)
        else {
            return nil
        }
        return PanelDropPlan(kind: kind, sources: session.sources, destination: target.location, row: target.row)
    }

    /// The mouse drags something over a row (-1: over no row).
    ///
    /// Returns what a drop would do and the row to frame.
    internal func validateDrop(_ info: any NSDraggingInfo, row: Int) -> (operation: NSDragOperation, row: Int?) {
        let allowed = info.draggingSourceOperationMask
        let session = PanelDrop.session(for: info)
        guard let plan = dropPlan(for: session, row: row, modifiers: NSEvent.modifierFlags, allowed: allowed) else {
            return ([], nil)
        }
        let operation: NSDragOperation = plan.kind == .copy ? .copy : (allowed.contains(.move) ? .move : .generic)
        return (operation, plan.row)
    }

    /// Something was dropped.
    ///
    /// The drop is carried out after the drag has ended, so the program the files came from is not
    /// kept waiting while a question is on screen.
    internal func acceptDrop(_ info: any NSDraggingInfo, row: Int) -> Bool {
        let session = PanelDrop.session(for: info)
        // Dropped before the drag's items were all put together: they are now.
        session.finishNow()
        PanelDrop.endSession(session.sequence)
        let allowed = info.draggingSourceOperationMask
        guard let plan = dropPlan(for: session, row: row, modifiers: NSEvent.modifierFlags, allowed: allowed) else {
            return false
        }
        // From the run loop, like everything that may ask: the question is a dialog.
        MainLoop.dialog { [weak self] in self?.carryOut(plan) }
        return true
    }

    /// Copies or moves what was dropped, through the file-transfer service, which shows the
    /// progress and asks the usual questions.
    ///
    /// Asks first when the user wants that.
    internal func carryOut(_ plan: PanelDropPlan) {
        guard !commands.isBlocked(), let transfers = kernel.services.find((any FileTransferService).self) else {
            commands.onRejected()
            return
        }
        if settings.confirmsDrops {
            let verb = plan.kind == .move ? "Move" : "Copy"
            let answer = kernel.interaction.choose(
                PanelDrop.question(plan.kind, count: plan.sources.count),
                detail: kernel.fileSystems.displayPath(plan.destination),
                buttons: [verb, "Cancel"],
                style: .information
            )
            guard answer == 0 else {
                return
            }
        }
        // A copy dropped into the folder it came from gets a new name, as a pasted one does.
        transfers.transfer(plan.kind, plan.sources, into: plan.destination, renamingSelfCopies: plan.kind == .copy) {
            _ in
            // The service reports what happened itself.
        }
    }

    // The table of the Full view drags and takes drops through its data source.

    /// The table drags the row that was grabbed; when that row is marked, all marked items go
    /// along: in the program through the drag's ticket, for other programs in `willBeginAt`.
    internal func tableView(_: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        pendingDragItems = draggingItems(forRow: row)
        return pendingDragItems.first
    }

    /// The table's drag begins: the other items join the first on its pasteboard.
    internal func tableView(
        _: NSTableView,
        draggingSession session: NSDraggingSession,
        willBeginAt _: NSPoint,
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

    /// The table's drag is over, wherever it ended.
    internal func tableView(
        _: NSTableView,
        draggingSession _: NSDraggingSession,
        endedAt _: NSPoint,
        operation _: NSDragOperation
    ) {
        pendingDragItems = []
        PanelDrop.endDrag()
        PanelDrop.endSession(nil)
    }

    /// Something is dragged over the table: what a drop on the row under the mouse would do.
    internal func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow _: Int,
        proposedDropOperation _: NSTableView.DropOperation
    ) -> NSDragOperation {
        let (operation, target) = validateDrop(
            info,
            row: tableView.row(at: tableView.convert(info.draggingLocation, from: nil))
        )
        if let target {
            tableView.setDropRow(target, dropOperation: .on)
        }
        return operation
    }

    /// Something was dropped on the table.
    internal func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row _: Int,
        dropOperation _: NSTableView.DropOperation
    ) -> Bool {
        acceptDrop(info, row: tableView.row(at: tableView.convert(info.draggingLocation, from: nil)))
    }
}
