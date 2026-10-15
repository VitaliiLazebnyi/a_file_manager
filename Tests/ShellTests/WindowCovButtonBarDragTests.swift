import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// Dragging on the button bar: a ⌘-press that moves starts a drag, one that does not is a press;
/// the bar marks where a drop would go and takes a button off that is let go of beside it.
///
/// The mouse is scripted (`nextMouseEvent`) and the system's drag is recorded (`startDragging`),
/// so no event loop runs and nothing is dragged on the screen.
@MainActor
@Suite(.serialized)
internal struct WindowCovButtonBarDragTests {
    /// A drag the bar asked the system for.
    private struct Started {
        /// The dragged items.
        let items: [NSDraggingItem]
        /// Whether they fly back when the drag fails.
        let fliesBack: Bool
    }

    /// The window's folders and stand-ins.
    private let fixture: AppFixture

    /// A sandbox with the window's files.
    internal init() throws {
        fixture = try AppFixture(files: AppFixture.windowFiles)
    }

    /// A mouse event of `type` at `point` of the bar's window, with ⌘ held.
    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in bar: NSView) throws -> NSEvent {
        try PanelDropHelpers.mouse(type, at: point, clicks: 1, flags: .command, in: bar.window)
    }

    /// The bar of `app` with two groups and a second line, laid out wide enough for one row.
    private func arrange(_ app: AppRun) -> ButtonBarView {
        let bar = app.window.buttonBar
        app.kernel.toolbar.setLayout(
            [.copy, .showHidden, nil, .showCommandLine, ToolbarRegistry.lineBreak, .showDriveButtons],
            in: fixture.settings
        )
        bar.frame.size = NSSize(width: 2_000, height: 80)
        bar.flow.frame.size.width = 2_000
        bar.flow.layout()
        return bar
    }

    /// Hands the bar `events` one after the other, then none; records the drags it starts.
    private func script(_ bar: ButtonBarView, _ events: [NSEvent]) -> () -> [Started] {
        var queue = events
        var started: [Started] = []
        bar.nextMouseEvent = { _ in queue.isEmpty ? nil : queue.removeFirst() }
        bar.startDragging = { _, items, _, back in started.append(Started(items: items, fliesBack: back)) }
        return { started }
    }

    /// A ⌘-press that does not move, or whose mouse events run out, presses the button; the
    /// handle's press is no drag either.
    @Test
    internal func aCommandPressThatDoesNotMoveIsAPress() async throws {
        let app = await fixture.startWindow(with: WindowTestPlugin())
        defer { app.stop() }
        let bar = arrange(app)
        let button = try #require(bar.buttons.first { $0.command == .showHidden })
        let start = NSPoint(x: 10, y: 10)
        let drags = script(
            bar,
            [
                try Self.mouse(.leftMouseDragged, at: NSPoint(x: 12, y: 11), in: bar),
                try Self.mouse(.leftMouseUp, at: start, in: bar)
            ]
        )
        #expect(!app.commands.isChecked(.showHidden))
        button.mouseDown(with: try Self.mouse(.leftMouseDown, at: start, in: bar))
        await app.settle()
        #expect(app.commands.isChecked(.showHidden) && drags().isEmpty && bar.dragged == nil)
        // The events end without a release (the window went): still a press, nothing dragged.
        _ = script(bar, [])
        button.mouseDown(with: try Self.mouse(.leftMouseDown, at: start, in: bar))
        await app.settle()
        #expect(!app.commands.isChecked(.showHidden) && bar.dragged == nil)
        // A press on a handle that does not move drags nothing.
        let handle = try #require(bar.flow.items.first as? BarSeparatorView)
        _ = script(bar, [try Self.mouse(.leftMouseUp, at: start, in: bar)])
        handle.mouseDown(with: try Self.mouse(.leftMouseDown, at: start, in: bar))
        #expect(bar.dragged == nil)
        // A bar outside a window tracks nothing.
        let alone = ButtonBarView(kernel: app.kernel)
        #expect(
            !alone.trackDrag(
                .button(line: 0, group: 0, index: 0),
                of: alone,
                from: try Self.mouse(.leftMouseDown, at: start, in: bar)
            )
        )
    }

    /// Moving more than a few points starts the drag: of a button, which does not fly back, or of
    /// a group with its handle, which does; what is dragged fades and the bar makes room below.
    @Test
    internal func aPressThatMovesStartsTheDragOfAButtonOrAGroup() async throws {
        let app = await fixture.startWindow(with: WindowTestPlugin())
        defer { app.stop() }
        let bar = arrange(app)
        let button = try #require(bar.buttons.first)
        let start = NSPoint(x: 10, y: 10)
        let drags = script(bar, [try Self.mouse(.leftMouseDragged, at: NSPoint(x: 20, y: 10), in: bar)])
        button.mouseDown(with: try Self.mouse(.leftMouseDown, at: start, in: bar))
        #expect(bar.dragged == .button(line: 0, group: 0, index: 0) && button.alphaValue < 1)
        #expect(drags().count == 1 && drags().first?.fliesBack == false && bar.flow.extraHeight > 0)
        // The picture of the drag is the button as it looks.
        let item = try #require(drags().first?.items.first)
        let picture = try #require(item.imageComponents?.first?.contents as? NSImage)
        #expect(picture.size == button.frame.size)
        #expect(picture.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
        // Let go of on the bar, nothing is taken off; the bar looks as before.
        let session = PanelDragSession(NSPasteboard.withUniqueName())
        bar.dragWasCancelled = { false }
        let inside = try #require(bar.window)
            .convertToScreen(bar.convert(NSRect(x: 30, y: 10, width: 1, height: 1), to: nil))
        bar.draggingSession(session, endedAt: inside.origin, operation: [])
        #expect(bar.dragged == nil && bar.flow.extraHeight == 0 && button.alphaValue == 1)
        #expect(bar.entries.contains(.copy))

        // The handle of the second group drags the group with its buttons; they fly back. A part
        // without a size has no picture: the drag shows the rest.
        let handle = try #require(bar.flow.items[3] as? BarSeparatorView)
        bar.flow.items[4].frame.size.width = 0
        let groupDrags = script(bar, [try Self.mouse(.leftMouseDragged, at: NSPoint(x: 10, y: 20), in: bar)])
        handle.mouseDown(with: try Self.mouse(.leftMouseDown, at: start, in: bar))
        #expect(bar.dragged == .group(line: 0, group: 1) && groupDrags().first?.fliesBack == true)
        let groupPicture = try #require(groupDrags().first?.items.first?.imageComponents?.first?.contents as? NSImage)
        #expect(groupPicture.size.width == handle.frame.width)
        // A group let go of beside the bar stays.
        bar.draggingSession(session, endedAt: NSPoint(x: -50_000, y: -50_000), operation: [])
        #expect(bar.entries.contains(.showCommandLine) && bar.dragged == nil)
        // Something that is no longer on the bar has nothing to drag.
        bar.dragged = nil
        _ = script(bar, [try Self.mouse(.leftMouseDragged, at: NSPoint(x: 30, y: 10), in: bar)])
        bar.trackDrag(
            .button(line: 5, group: 0, index: 0),
            of: bar,
            from: try Self.mouse(.leftMouseDown, at: start, in: bar)
        )
        #expect(bar.dragged == nil)
    }

    /// A button let go of beside the bar is taken off it; Escape, a drop that was taken, or a bar
    /// that is no longer in a window take nothing off.
    @Test
    internal func aButtonLetGoOfBesideTheBarIsTakenOff() async {
        let app = await fixture.startWindow(with: WindowTestPlugin())
        defer { app.stop() }
        let bar = arrange(app)
        let session = PanelDragSession(NSPasteboard.withUniqueName())
        let outside = NSPoint(x: -50_000, y: -50_000)
        let copy = ButtonBarView.Dragged.button(line: 0, group: 0, index: 0)
        // Nothing of the bar's dragged: only the marks go.
        bar.indicator.isHidden = false
        bar.draggingSession(session, endedAt: outside, operation: [])
        #expect(bar.indicator.isHidden && bar.entries.first == .copy)
        // Escape.
        bar.dragged = copy
        bar.dragWasCancelled = { true }
        bar.draggingSession(session, endedAt: outside, operation: [])
        #expect(bar.entries.first == .copy && bar.dragged == nil)
        // Taken by someone (the operation is not empty).
        bar.dragWasCancelled = { false }
        bar.dragged = copy
        bar.draggingSession(session, endedAt: outside, operation: .move)
        #expect(bar.entries.first == .copy)
        // A bar outside a window.
        let alone = ButtonBarView(kernel: app.kernel)
        alone.dragged = copy
        alone.draggingSession(session, endedAt: outside, operation: [])
        #expect(app.kernel.toolbar.layout(from: fixture.settings).first??.command == .copy)
        // Let go of beside the bar: off it.
        bar.dragged = copy
        bar.draggingSession(session, endedAt: outside, operation: [])
        #expect(bar.entries.first == .showHidden && !bar.entries.contains(.copy))
        // The bar's items move within the program only.
        #expect(bar.draggingSession(session, sourceOperationMaskFor: .withinApplication) == .move)
        #expect(bar.draggingSession(session, sourceOperationMaskFor: .outsideApplication).isEmpty)
    }

    /// The mark shows where a drop would go: a thin line between buttons, a wider one for a new
    /// group, a pale band for a new line; nowhere hides it.
    @Test
    internal func theMarkShowsWhereADropWouldGo() async {
        let app = await fixture.startWindow(with: WindowTestPlugin())
        defer { app.stop() }
        let bar = arrange(app)
        func alpha() -> CGFloat {
            bar.indicator.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.alphaComponent } ?? -1
        }
        bar.showIndicator(for: .button(.inGroup(line: 0, group: 0, beforeButton: 1)))
        let between = bar.indicator.frame
        #expect(!bar.indicator.isHidden && between.width == 2 && abs(alpha() - 1) < 0.01)
        // Behind the last button of a group.
        bar.showIndicator(for: .button(.inGroup(line: 0, group: 0, beforeButton: 2)))
        #expect(bar.indicator.frame.minX > between.minX && bar.indicator.frame.width == 2)
        bar.showIndicator(for: .button(.newGroup(.line(0, beforeGroup: 1))))
        #expect(bar.indicator.frame.width == 7 && abs(alpha() - 0.45) < 0.01)
        // At the end of a line, where there is no handle.
        bar.showIndicator(for: .group(.line(0, beforeGroup: 2)))
        #expect(bar.indicator.frame.width == 3 && abs(alpha() - 1) < 0.01)
        bar.showIndicator(for: .group(.newLine(beforeLine: 2)))
        #expect(!bar.indicator.isHidden && abs(alpha() - 0.25) < 0.01)
        bar.showIndicator(for: .button(.newGroup(.newLine(beforeLine: 2))))
        #expect(abs(alpha() - 0.25) < 0.01)
        // Places the bar does not have hide the mark.
        for target: ButtonBarView.DropTarget? in [
            nil, .button(.inGroup(line: 4, group: 0, beforeButton: 0)), .group(.line(4, beforeGroup: 0))
        ] {
            bar.indicator.isHidden = false
            bar.showIndicator(for: target)
            #expect(bar.indicator.isHidden)
        }
        // A bar without buttons has no band for a new line, and no place for a drop.
        app.kernel.toolbar.setLayout([], in: fixture.settings)
        bar.indicator.isHidden = false
        bar.showIndicator(for: .group(.newLine(beforeLine: 0)))
        #expect(bar.indicator.isHidden && bar.dropTarget(for: .group(line: 0, group: 0), at: .zero) == nil)
    }
}
