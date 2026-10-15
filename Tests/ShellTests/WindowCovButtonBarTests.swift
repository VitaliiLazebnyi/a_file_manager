import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The button bar as a drop target, where a drop goes, the arrangement's refusals, and how its
/// buttons and handles look and take presses.
@MainActor
@Suite(.serialized)
internal struct WindowCovButtonBarTests {
    /// The window's folders and stand-ins.
    private let fixture: AppFixture

    /// A sandbox with the window's files.
    internal init() throws {
        fixture = try AppFixture(files: AppFixture.windowFiles)
    }

    /// The bar of `app` with two groups and a second line, laid out wide enough for one row:
    /// handle, Copy, Hidden, handle, Command Line, then handle, Drive Buttons on the second line.
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

    /// The frames of the bar's items, in the flow's coordinates (rows run downwards).
    private func frames(_ bar: ButtonBarView) -> [NSRect] {
        bar.flow.items.map(\.frame)
    }

    /// `point` of the flow in the bar's coordinates, where `dropTarget` takes it.
    private func inBar(_ bar: ButtonBarView, _ point: NSPoint) -> NSPoint {
        bar.convert(point, from: bar.flow)
    }

    /// Only the bar's own drags are marked and dropped; a drop rearranges the bar.
    @Test
    internal func onlyTheBarsOwnDragsAreMarkedAndDropped() async {
        let app = await fixture.startWindow(with: WindowTestPlugin())
        defer { app.stop() }
        let bar = arrange(app)
        let handle = frames(bar)[3]
        let onHandle = bar.convert(inBar(bar, NSPoint(x: handle.midX, y: handle.midY)), to: nil)
        // Someone else's drag, or the bar's when it is not dragging anything.
        let foreign = WindowCovDraggingInfo(from: NSView(), at: onHandle)
        #expect(bar.draggingEntered(foreign).isEmpty && !bar.performDragOperation(foreign))
        let ours = WindowCovDraggingInfo(from: bar, at: onHandle)
        #expect(bar.draggingUpdated(ours).isEmpty && bar.indicator.isHidden)
        // Copy dragged over the second group's handle: the mark shows a group of its own there.
        bar.dragged = .button(line: 0, group: 0, index: 0)
        #expect(bar.draggingEntered(ours) == .move && !bar.indicator.isHidden)
        bar.draggingExited(ours)
        #expect(bar.indicator.isHidden)
        #expect(bar.performDragOperation(ours) && bar.dragged == nil)
        #expect(
            bar.entries == [
                .showHidden, nil, .copy, nil, .showCommandLine, ToolbarRegistry.lineBreak, .showDriveButtons
            ]
        )
        // A bar without buttons has no place for the drop.
        app.kernel.toolbar.setLayout([], in: fixture.settings)
        bar.dragged = .button(line: 0, group: 0, index: 0)
        #expect(!bar.performDragOperation(ours) && bar.dragged == nil)
    }

    /// Below the last row a drop starts a new line; a press beside the items of a row goes into
    /// the group next to it; the row is the one nearest the mouse, whichever item is nearest.
    @Test
    internal func dropsBesideTheItemsGoIntoTheNearestGroup() async {
        let app = await fixture.startWindow(with: WindowTestPlugin())
        defer { app.stop() }
        let bar = arrange(app)
        let frames = frames(bar)
        let copy = ButtonBarView.Dragged.button(line: 0, group: 0, index: 0)
        let below = inBar(bar, NSPoint(x: 20, y: frames.map(\.maxY).max().map { $0 + 10 } ?? 0))
        #expect(bar.dropTarget(for: copy, at: below) == .button(.newGroup(.newLine(beforeLine: 2))))
        #expect(bar.dropTarget(for: .group(line: 0, group: 1), at: below) == .group(.newLine(beforeLine: 2)))
        // Just outside the second handle's snap, behind Hidden: the end of the first group.
        let row = frames[0].midY
        #expect(
            bar.dropTarget(for: copy, at: inBar(bar, NSPoint(x: frames[2].maxX, y: row)))
                == .button(.inGroup(line: 0, group: 0, beforeButton: 2))
        )
        // Left of the line's first handle: the start of its first group.
        #expect(
            bar.dropTarget(for: copy, at: inBar(bar, NSPoint(x: 0, y: row)))
                == .button(.inGroup(line: 0, group: 0, beforeButton: 0))
        )
        // Just behind the last button of the second line, not far enough for a group of its own.
        let last = frames[6]
        #expect(
            bar.dropTarget(for: copy, at: inBar(bar, NSPoint(x: last.maxX + 1, y: last.midY)))
                == .button(.inGroup(line: 1, group: 0, beforeButton: 1))
        )
        // The first items of the row are lower than the mouse; the row is still found whole.
        bar.flow.items[0].frame.size.height = 2
        bar.flow.items[1].frame.size.height = 2
        let hidden = frames[2]
        #expect(
            bar.dropTarget(for: copy, at: inBar(bar, NSPoint(x: hidden.midX - 1, y: hidden.maxY - 2)))
                == .button(.inGroup(line: 0, group: 0, beforeButton: 1))
        )
    }

    /// A drop that leaves the bar as it was, or a group dropped where only a button can go,
    /// stores nothing; the arrangement refuses places it does not have.
    @Test
    internal func dropsThatChangeNothingStoreNothing() async {
        let app = await fixture.startWindow(with: WindowTestPlugin())
        defer { app.stop() }
        let bar = arrange(app)
        let before = bar.entries
        var stored = 0
        app.kernel.toolbar.onChange = { stored += 1 }
        bar.apply(.group(line: 0, group: 0), to: .button(.inGroup(line: 0, group: 1, beforeButton: 0)))
        bar.apply(.button(line: 0, group: 0, index: 0), to: .button(.inGroup(line: 0, group: 0, beforeButton: 0)))
        #expect(bar.entries == before && stored == 0)

        let first: CommandID = "a"
        let second: CommandID = "b"
        let start = ButtonBarArrangement(entries: [first, nil, second])
        var arrangement = start
        arrangement.moveButton(line: 3, group: 0, index: 0, to: .inGroup(line: 0, group: 0, beforeButton: 0))
        for target: ButtonBarArrangement.Target in [
            .inGroup(line: 2, group: 0, beforeButton: 0), .inGroup(line: 0, group: 5, beforeButton: 0),
            .inGroup(line: 0, group: 1, beforeButton: 4), .newGroup(.line(2, beforeGroup: 0)),
            .newGroup(.line(0, beforeGroup: 5)), .newGroup(.newLine(beforeLine: 3))
        ] {
            arrangement.moveButton(line: 0, group: 0, index: 0, to: target)
        }
        arrangement.moveGroup(line: 0, group: 4, to: .newLine(beforeLine: 0))
        arrangement.moveGroup(line: 0, group: 0, to: .line(3, beforeGroup: 0))
        arrangement.removeButton(line: 0, group: 0, index: 2)
        #expect(arrangement == start)
    }

    /// Without a command for its context menu the bar has none; a command without a picture on
    /// this system gets a button with its name.
    @Test
    internal func aBarWithoutContextCommandsHasNoMenuAndAMissingPictureGivesAName() async {
        let bare = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
        #expect(ButtonBarView(kernel: bare).menu(for: NSEvent()) == nil)
        let app = await fixture.startWindow(with: WindowTestPlugin())
        defer { app.stop() }
        app.kernel.toolbar.add("cm_TestSecond", symbol: "no.such.picture.anywhere", group: 9)
        app.kernel.toolbar.setLayout(["cm_TestSecond", .copy], in: fixture.settings)
        let bar = app.window.buttonBar
        let named = bar.buttons.first { $0.command == "cm_TestSecond" }
        #expect(named?.title == "Sort ▸ Second" && named?.image == nil)
        #expect(named?.frame.height == bar.buttons.last?.frame.height)
        #expect(bar.buttons.last?.image != nil && bar.buttons.last?.symbolConfiguration != nil)
    }

    /// A press on a button or a handle of a bar that has gone does nothing.
    @Test
    internal func aPressOnAGoneBarDoesNothing() async throws {
        let app = await fixture.startWindow(with: WindowTestPlugin())
        defer { app.stop() }
        app.kernel.toolbar.setLayout([.showHidden], in: fixture.settings)
        var buttonPress: ((NSEvent) -> Void)?
        var handlePress: ((NSEvent) -> Void)?
        weak var gone: ButtonBarView?
        do {
            let bar = ButtonBarView(kernel: app.kernel)
            buttonPress = bar.buttons.first?.onCommandMouseDown
            handlePress = (bar.flow.items.first as? BarSeparatorView)?.onMouseDown
            gone = bar
        }
        #expect(await AppWait.until { gone == nil })
        let event = try PanelDropHelpers.mouse(.leftMouseDown, at: .zero, clicks: 1, flags: .command, in: nil)
        buttonPress?(event)
        handlePress?(event)
        #expect(buttonPress != nil && handlePress != nil && !app.commands.isChecked(.showHidden))
    }

    /// A button's frame shows its state: the accent colour while its command is on (paler
    /// greyed out), grey while pressed, lighter grey under the mouse, nothing otherwise.
    @Test
    internal func aButtonsFrameShowsItsState() throws {
        let button = BarCommandButton(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        button.title = ""
        button.isBordered = false
        func coverage() throws -> CGFloat {
            let bitmap = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: bitmap)
            return bitmap.colorAt(x: 20, y: 20)?.alphaComponent ?? -1
        }
        #expect(try coverage() == 0)
        button.mouseEntered(with: NSEvent())
        #expect(button.isMouseInside)
        let hover = try coverage()
        button.highlight(true)
        let pressed = try coverage()
        button.highlight(false)
        button.mouseExited(with: NSEvent())
        #expect(!button.isMouseInside)
        button.state = .on
        let checked = try coverage()
        button.highlight(true)
        let onPressed = try coverage()
        button.highlight(false)
        button.isEnabled = false
        let onGreyed = try coverage()
        #expect(hover > 0 && pressed > hover && checked > pressed && onGreyed < checked && onPressed < checked)
        #expect(button.contentTintColor == .white)
    }

    /// A handle without anyone to drag its group passes a press on and shows no hand.
    @Test
    internal func aHandleWithoutADragPassesThePressOn() throws {
        let handle = BarSeparatorView(frame: NSRect(x: 0, y: 0, width: BarSeparatorView.width, height: 30))
        handle.mouseDown(with: try PanelDropHelpers.mouse(.leftMouseDown, at: .zero, clicks: 1, flags: [], in: nil))
        handle.resetCursorRects()
        var pressed = 0
        handle.onMouseDown = { _ in pressed += 1 }
        handle.mouseDown(with: try PanelDropHelpers.mouse(.leftMouseDown, at: .zero, clicks: 1, flags: [], in: nil))
        handle.resetCursorRects()
        #expect(pressed == 1)
    }
}
