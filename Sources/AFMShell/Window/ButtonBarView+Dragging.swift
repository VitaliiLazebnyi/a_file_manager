import AFMKernel
import AppKit

/// Arranging the bar by dragging its buttons and groups.
extension ButtonBarView {
    /// The views side by side, as the drag shows them.
    private static func picture(of views: [NSView]) -> NSImage {
        let reps = views.compactMap { view -> NSBitmapImageRep? in
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                return nil
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }
        let size = NSSize(width: views.reduce(0) { $0 + $1.frame.width }, height: views.map(\.frame.height).max() ?? 0)
        return NSImage(size: size, flipped: false) { _ in
            var left: CGFloat = 0
            for (view, rep) in zip(views, reps) {
                rep.draw(in: NSRect(x: left, y: 0, width: view.frame.width, height: view.frame.height))
                left += view.frame.width
            }
            return true
        }
    }

    /// The items of the row nearest to `point`, under it or above or below.
    ///
    /// The flow lays its rows out one after another, so a row is a range of its items.
    /// `frames` is not empty.
    private static func row(nearest point: NSPoint, frames: [NSRect]) -> Range<Int> {
        func distance(to frame: NSRect) -> CGFloat {
            frame.minY > point.y ? frame.minY - point.y : max(point.y - frame.maxY, 0)
        }
        var nearest = 0
        for index in frames.indices where distance(to: frames[index]) < distance(to: frames[nearest]) {
            nearest = index
        }
        let top = frames[nearest].minY
        var start = nearest
        while start > 0, frames[start - 1].minY == top {
            start -= 1
        }
        var end = nearest + 1
        while end < frames.count, frames[end].minY == top {
            end += 1
        }
        return start..<end
    }

    /// Where a drop at `point` (in the bar's coordinates) would put `item`; nil for nowhere.
    internal func dropTarget(for item: Dragged, at location: NSPoint) -> DropTarget? {
        let point = flow.convert(location, from: self)
        let frames = flow.items.map(\.frame)
        guard let bottom = frames.map(\.maxY).max() else {
            return nil
        }
        let lines = ButtonBarArrangement(entries: entries).lines
        // Below the last row: a line of its own.
        if point.y > bottom + 2 {
            let place = ButtonBarArrangement.Place.newLine(beforeLine: lines.count)
            if case .group = item {
                return .group(place)
            }
            return .button(.newGroup(place))
        }
        switch item {
        case .group:
            return groupTarget(at: point, frames: frames, lines: lines).map { .group($0) }

        case .button:
            return .button(buttonTarget(at: point, frames: frames, lines: lines))
        }
    }

    /// Waits for the mouse to move a few points before a drag starts.
    ///
    /// So a press that does not move stays a press. Answers whether a drag was started.
    @discardableResult
    internal func trackDrag(_ item: Dragged, of _: NSView, from event: NSEvent) -> Bool {
        guard let window else {
            return false
        }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                return false
            }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 3 {
                beginDrag(item, from: next)
                return true
            }
        }
        return false
    }

    /// Shows the mark for `target`, or hides it for nil.
    internal func showIndicator(for target: DropTarget?) {
        guard let target, let frame = indicatorFrame(for: target) else {
            indicator.isHidden = true
            return
        }
        indicator.frame = convert(frame, from: flow)
        var alpha: CGFloat = 1
        switch target {
        case .group(.newLine), .button(.newGroup(.newLine)):
            alpha = 0.25

        case .button(.newGroup):
            alpha = 0.45

        default:
            break
        }
        indicator.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(alpha).cgColor
        indicator.isHidden = false
    }

    /// The bar's items move within the program only.
    internal func draggingSession(_: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation
    {
        context == .withinApplication ? .move : []
    }

    /// The drag ended: the bar looks as before, and a button let go of away from the bar is
    /// taken off it (Escape takes nothing off).
    internal func draggingSession(_: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        indicator.isHidden = true
        for item in flow.items {
            item.alphaValue = 1
        }
        // The bar as it was during the drag, with the room for a new line.
        let bar = window.map { $0.convertToScreen(convert(bounds, to: nil)) }
        flow.extraHeight = 0
        guard let item = dragged else {
            return
        }
        dragged = nil
        let cancelled = NSApp.currentEvent?.type == .keyDown
        guard case .button = item, operation.isEmpty, !cancelled, let bar else {
            return
        }
        if !bar.insetBy(dx: -4, dy: -4).contains(screenPoint) {
            apply(item, to: nil)
        }
    }

    /// Whether a drag is one this bar started.
    internal func isOurs(_ info: any NSDraggingInfo) -> Bool {
        (info.draggingSource as? ButtonBarView) === self && dragged != nil
    }

    /// Where a group dropped at `point` goes: before the nearest handle, or at the end of a line.
    private func groupTarget(
        at point: NSPoint,
        frames: [NSRect],
        lines: [[[CommandID]]]
    ) -> ButtonBarArrangement.Place? {
        var anchors: [(place: ButtonBarArrangement.Place, point: NSPoint)] = []
        for (index, (slot, frame)) in zip(slots, frames).enumerated() {
            if case .handle(let line, let group) = slot {
                anchors.append((.line(line, beforeGroup: group), NSPoint(x: frame.midX, y: frame.midY)))
            }
            if endsLine(index) {
                anchors.append(
                    (.line(slot.line, beforeGroup: lines[slot.line].count), NSPoint(x: frame.maxX, y: frame.midY))
                )
            }
        }
        func distance(_ anchor: NSPoint) -> CGFloat { hypot(anchor.x - point.x, 3 * (anchor.y - point.y)) }
        return anchors.min { distance($0.point) < distance($1.point) }?.place
    }

    /// Where a button dropped at `point` goes, in the row under the mouse or the nearest one.
    ///
    /// Onto a handle it makes a group of its own, well behind the end of a line one at the end;
    /// otherwise it goes between the two items it is dropped between. `frames` is not empty.
    private func buttonTarget(
        at point: NSPoint,
        frames: [NSRect],
        lines: [[[CommandID]]]
    ) -> ButtonBarArrangement.Target {
        let row = Self.row(nearest: point, frames: frames)
        let handles = row.compactMap { index -> (line: Int, group: Int)? in
            guard case .handle(let line, let group) = slots[index], abs(point.x - frames[index].midX) <= Self.handleSnap
            else {
                return nil
            }
            return (line, group)
        }
        if let handle = handles.first {
            return .newGroup(.line(handle.line, beforeGroup: handle.group))
        }
        let last = row.upperBound - 1
        if endsLine(last), point.x > frames[last].maxX + frames[last].width / 2 {
            return .newGroup(.line(slots[last].line, beforeGroup: lines[slots[last].line].count))
        }
        let index = row.first { frames[$0].maxX > point.x } ?? last
        return insertion(at: index, before: point.x < frames[index].midX, lines: lines)
    }

    /// Where a button goes that is dropped on item `index`, `before` its middle or behind it.
    private func insertion(at index: Int, before: Bool, lines: [[[CommandID]]]) -> ButtonBarArrangement.Target {
        switch slots[index] {
        case .button(let line, let group, let position):
            return .inGroup(line: line, group: group, beforeButton: before ? position : position + 1)

        case .handle(let line, let group):
            if before, group > 0 {
                return .inGroup(line: line, group: group - 1, beforeButton: lines[line][group - 1].count)
            }
            return .inGroup(line: line, group: group, beforeButton: 0)
        }
    }

    /// Whether item `index` is the last of its line.
    private func endsLine(_ index: Int) -> Bool {
        index == slots.count - 1 || slots[index + 1].line != slots[index].line
    }

    /// The views a drag of `item` takes along: the button, or the handle and its group.
    private func views(of item: Dragged) -> [NSView] {
        zip(flow.items, slots)
            .compactMap { view, slot in
                switch (item, slot) {
                case (
                    .button(let draggedLine, let draggedGroup, let draggedIndex),
                    .button(let line, let group, let index)
                ):
                    return (draggedLine, draggedGroup, draggedIndex) == (line, group, index) ? view : nil

                case (.group(let draggedLine, let draggedGroup), .handle(let line, let group)),
                    (.group(let draggedLine, let draggedGroup), .button(let line, let group, _)):
                    return (draggedLine, draggedGroup) == (line, group) ? view : nil

                default:
                    return nil
                }
            }
    }

    /// Starts the drag of `item`: its views fade, the bar makes room for a new line.
    private func beginDrag(_ item: Dragged, from event: NSEvent) {
        let views = views(of: item)
        guard let first = views.first else {
            return
        }
        let image = Self.picture(of: views)
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString("", forType: Self.pasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(
            NSRect(origin: convert(first.frame, from: flow).origin, size: image.size),
            contents: image
        )
        dragged = item
        for view in views {
            view.alphaValue = 0.3
        }
        // Room for a new line below the bar while the drag lasts.
        flow.extraHeight = (flow.items.first?.frame.height ?? BarButton.height) + 2
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        // A button dropped off the bar is removed: it does not fly back.
        if case .button = item {
            session.animatesToStartingPositionsOnCancelOrFail = false
        }
    }

    /// Where the bar shows that a drop would go, in the flow's coordinates.
    ///
    /// A thin line between two buttons, a wider mark where a group would stand, a band below
    /// the bar for a new line.
    private func indicatorFrame(for target: DropTarget) -> NSRect? {
        switch target {
        case .group(let place):
            return frame(of: place, width: 3)

        case .button(.newGroup(let place)):
            return frame(of: place, width: 7)

        case .button(.inGroup(let line, let group, let before)):
            if let next = frame(of: .button(line: line, group: group, index: before)) {
                return mark(atX: next.minX - 1, around: next, width: 2)
            }
            if let previous = frame(of: .button(line: line, group: group, index: before - 1)) {
                return mark(atX: previous.maxX + 1, around: previous, width: 2)
            }
            return nil
        }
    }

    /// The frame of the item that stands for `slot`; nil when there is none.
    private func frame(of slot: Slot) -> NSRect? {
        zip(slots, flow.items).first { $0.0 == slot }?.1.frame
    }

    /// The mark of a group's place, `width` wide: on its handle, or behind the line's end; for a
    /// new line a band below the bar.
    private func frame(of place: ButtonBarArrangement.Place, width: CGFloat) -> NSRect? {
        let frames = flow.items.map(\.frame)
        switch place {
        case .line(let line, let group):
            if let handle = frame(of: .handle(line: line, group: group)) {
                return mark(atX: handle.midX, around: handle, width: width)
            }
            guard let last = slots.lastIndex(where: { $0.line == line }) else {
                return nil
            }
            return mark(atX: frames[last].maxX + 2, around: frames[last], width: width)

        case .newLine:
            guard let first = frames.first, let bottom = frames.map(\.maxY).max() else {
                return nil
            }
            return NSRect(
                x: first.minX,
                y: bottom + 4,
                width: max(flow.bounds.width - 2 * first.minX, 0),
                height: first.height - 4
            )
        }
    }

    /// A vertical mark `width` wide centred at `left`, as high as `frame` less a little.
    private func mark(atX left: CGFloat, around frame: NSRect, width: CGFloat) -> NSRect {
        NSRect(x: left - width / 2, y: frame.minY + 2, width: width, height: frame.height - 4)
    }
}
