import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The button bar at the top of the window: what it shows, how it follows its commands, and
/// how it is rearranged by dragging.
@MainActor
@Suite(.serialized)
internal struct WindowButtonBarTests {
    /// The window's folders and stand-ins.
    private let fixture: AppFixture
    /// The plugin that brings the test's buttons and commands.
    private let extra = WindowTestPlugin()

    /// A sandbox with the window's files.
    internal init() throws {
        fixture = try AppFixture(files: AppFixture.windowFiles)
    }

    /// The bar shows the registered commands of the plugins' proposal, with their tips, and runs them.
    @Test
    internal func theButtonBarShowsWhatPluginsRegistered() async {
        let app = await fixture.startWindow(with: extra)
        defer { app.stop() }
        let bar = app.window.buttonBar
        // Commands nobody registered are left out, with the separators they would leave behind.
        let commands = bar.entries.compactMap(\.self)
        #expect(
            commands.contains(.copy) && commands.contains(.showHidden)
                && commands.allSatisfy { app.commands[$0] != nil }
        )
        #expect(
            bar.entries.first != nil && bar.entries.last != nil
                && !zip(bar.entries, bar.entries.dropFirst()).contains { $0 == nil && $1 == nil }
        )
        // The name and key of each button, and below them what it does where its plugin says.
        let tips = bar.buttons.map { $0.toolTip ?? "" }
        #expect(
            tips.contains("Copy… (F5)\nCopy the selected files to the folder of the other panel.")
                && tips.contains("Hidden Files (⇧⌘.)")
        )
        #expect(tips.count == commands.count)
        #expect(!bar.isHidden && bar.buttons.allSatisfy { $0.image != nil })
        // The buttons follow their commands: Copy needs something under the cursor.
        let copy = bar.buttons[commands.firstIndex(of: .copy) ?? 0]
        let hidden = bar.buttons[commands.firstIndex(of: .showHidden) ?? 0]
        #expect(copy.isEnabled == app.commands.isEnabled(.copy) && hidden.state == .off)
        app.cursor(app.left, on: "one.txt")
        app.commands.perform(.showHidden)
        await app.settle()
        app.window.validateBars()
        #expect(copy.isEnabled && hidden.state == .on)
        // A click runs the command.
        Controls.send(hidden)
        await app.settle()
        #expect(!app.commands.isChecked(.showHidden) && hidden.state == .off)
        // The user's own layout replaces the proposal at once.
        app.kernel.toolbar.setLayout([.showHidden, nil, .showCommandLine], in: fixture.settings)
        #expect(bar.entries == [.showHidden, nil, .showCommandLine] && bar.buttons[1].state == .on)
        // The context menu offers the configuration and the switches of the window.
        let titles = bar.menu(for: NSEvent())?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
        #expect(
            titles == [
                "Options…", "Reset Button Bar to Default", "Button Bar", "Drive Buttons", "Command Line",
                "Function Key Buttons"
            ]
        )
    }

    /// A button or a group dropped on the bar goes where the mouse is: between buttons, into a
    /// group of its own on a handle, at the end of a line.
    @Test
    internal func dropsOnTheButtonBarGoWhereTheMouseIs() async {
        let app = await fixture.startWindow(with: extra)
        defer { app.stop() }
        let bar = arrangeTwoLines(app)
        // Every group has a handle in front of it, the first one of a line too.
        #expect(
            bar.slots == [
                .handle(line: 0, group: 0), .button(line: 0, group: 0, index: 0), .button(line: 0, group: 0, index: 1),
                .handle(line: 0, group: 1), .button(line: 0, group: 1, index: 0), .button(line: 0, group: 1, index: 1),
                .handle(line: 1, group: 0), .button(line: 1, group: 0, index: 0)
            ]
        )
        // The buttons are square, so the frame under the mouse is one too.
        #expect(bar.buttons.allSatisfy { $0.frame.width == $0.frame.height })
        let frames = bar.flow.items.map { bar.convert($0.frame, from: bar.flow) }
        #expect(frames.count == 8 && Set(frames.map(\.minY)).count == 2 && frames[6].minX == frames[0].minX)
        func middle(_ index: Int) -> NSPoint {
            NSPoint(x: frames[index].midX, y: frames[index].midY)
        }
        // A button dropped on the left half of another goes before it; on a handle, into a group of its own.
        let copy = ButtonBarView.Dragged.button(line: 0, group: 0, index: 0)
        #expect(
            bar.dropTarget(for: copy, at: NSPoint(x: frames[4].minX + 2, y: frames[4].midY))
                == .button(.inGroup(line: 0, group: 1, beforeButton: 0))
        )
        #expect(
            bar.dropTarget(for: copy, at: NSPoint(x: frames[5].maxX - 2, y: frames[5].midY))
                == .button(.inGroup(line: 0, group: 1, beforeButton: 2))
        )
        #expect(bar.dropTarget(for: copy, at: middle(3)) == .button(.newGroup(.line(0, beforeGroup: 1))))
        #expect(bar.dropTarget(for: copy, at: middle(6)) == .button(.newGroup(.line(1, beforeGroup: 0))))
        // Past the end of the first line: a new group there, though the line has room left.
        #expect(
            bar.dropTarget(for: copy, at: NSPoint(x: frames[5].maxX + 200, y: frames[5].midY))
                == .button(.newGroup(.line(0, beforeGroup: 2)))
        )
        // A group goes to the nearest handle or line end.
        #expect(bar.dropTarget(for: .group(line: 1, group: 0), at: middle(3)) == .group(.line(0, beforeGroup: 1)))
        #expect(
            bar.dropTarget(for: .group(line: 0, group: 0), at: NSPoint(x: frames[7].maxX + 50, y: frames[7].midY))
                == .group(.line(1, beforeGroup: 1))
        )
    }

    /// Moving buttons and groups rearranges the bar for good; a button dropped off it is removed;
    /// reset brings back what the plugins proposed.
    @Test
    internal func theButtonBarIsRearrangedByDragging() async {
        let app = await fixture.startWindow(with: extra)
        defer { app.stop() }
        let bar = arrangeTwoLines(app)
        let lineBreak = ToolbarRegistry.lineBreak
        bar.apply(.group(line: 1, group: 0), to: .group(.line(0, beforeGroup: 0)))
        // The line it leaves empty disappears.
        #expect(bar.entries == [.showDriveButtons, nil, .copy, .showHidden, nil, .showCommandLine, .showFunctionKeys])
        // A group dropped below the bar starts a new line.
        bar.apply(.group(line: 0, group: 1), to: .group(.newLine(beforeLine: 1)))
        #expect(
            bar.entries == [.showDriveButtons, nil, .showCommandLine, .showFunctionKeys, lineBreak, .copy, .showHidden]
        )
        bar.apply(.button(line: 0, group: 1, index: 1), to: .button(.inGroup(line: 1, group: 0, beforeButton: 1)))
        #expect(
            bar.entries == [.showDriveButtons, nil, .showCommandLine, lineBreak, .copy, .showFunctionKeys, .showHidden]
        )
        // A button dragged off the bar is removed, and so is the group it leaves empty.
        bar.apply(.button(line: 0, group: 0, index: 0), to: nil)
        #expect(bar.entries == [.showCommandLine, lineBreak, .copy, .showFunctionKeys, .showHidden])
        #expect(app.kernel.toolbar.layout(from: fixture.settings).map { $0?.command } == bar.entries)
        // Reset puts back what the plugins proposed.
        #expect(app.commands.isEnabled(.resetButtonBar))
        app.commands.perform(.resetButtonBar)
        #expect(!app.kernel.toolbar.hasUserLayout(in: fixture.settings) && !app.commands.isEnabled(.resetButtonBar))
        let proposed = ButtonBarView.entries(of: app.kernel.toolbar.defaultLayout, commands: app.commands)
        #expect(bar.entries == proposed.map { $0?.command })
    }

    /// The hover frame of a button has a tracking area of its own; the tool tip's survives it.
    @Test
    internal func barButtonsKeepTheirToolTips() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let button = BarCommandButton(frame: NSRect(x: 10, y: 10, width: 40, height: 40))
        let path = PathBarView(frame: NSRect(x: 0, y: 60, width: 200, height: 22))
        for view in [button, path] as [NSView] {
            window.contentView?.addSubview(view)
            view.toolTip = "Copy… (F5)"
            view.updateTrackingAreas()
            view.updateTrackingAreas()
            let owners = view.trackingAreas.map { "\(type(of: $0.owner as AnyObject))" }
            #expect(
                owners.contains("NSToolTipManager") && owners.filter { $0 != "NSToolTipManager" }.count == 1,
                "\(owners)"
            )
        }
    }

    /// Moving and removing buttons and groups never leaves an empty group or line behind.
    @Test
    internal func buttonBarArrangementLeavesNoEmptyGroupOrLine() {
        let first: CommandID = "a"
        let second: CommandID = "b"
        let third: CommandID = "c"
        let fourth: CommandID = "d"
        let lineBreak = ToolbarRegistry.lineBreak
        var bar = ButtonBarArrangement(entries: [first, second, nil, third, lineBreak, fourth])
        #expect(bar.lines == [[[first, second], [third]], [[fourth]]])
        // Within its own group, after itself: the original place is accounted for.
        bar.moveButton(line: 0, group: 0, index: 0, to: .inGroup(line: 0, group: 0, beforeButton: 2))
        #expect(bar.entries == [second, first, nil, third, lineBreak, fourth])
        // The last button of a line takes the line with it.
        bar.moveButton(line: 1, group: 0, index: 0, to: .inGroup(line: 0, group: 1, beforeButton: 0))
        #expect(bar.entries == [second, first, nil, fourth, third])
        bar.moveButton(line: 0, group: 0, index: 1, to: .newGroup(.newLine(beforeLine: 1)))
        #expect(bar.entries == [second, nil, fourth, third, lineBreak, first])
        bar.moveButton(line: 0, group: 0, index: 0, to: .newGroup(.newLine(beforeLine: 0)))
        #expect(bar.entries == [second, lineBreak, fourth, third, lineBreak, first])
        bar.moveGroup(line: 2, group: 0, to: .line(0, beforeGroup: 0))
        #expect(bar.entries == [first, nil, second, lineBreak, fourth, third])
        bar.moveGroup(line: 0, group: 0, to: .line(0, beforeGroup: 2))
        #expect(bar.entries == [second, nil, first, lineBreak, fourth, third])
        bar.moveGroup(line: 1, group: 0, to: .newLine(beforeLine: 0))
        #expect(bar.entries == [fourth, third, lineBreak, second, nil, first])
        bar.removeButton(line: 1, group: 0, index: 0)
        #expect(bar.entries == [fourth, third, lineBreak, first])
        // Separators and line breaks at the ends, side by side or around nothing make nothing empty.
        let untidy = ButtonBarArrangement(entries: [lineBreak, nil, first, nil, lineBreak, nil, lineBreak, second, nil])
        #expect(untidy.lines == [[[first]], [[second]]])
    }

    /// Gives the bar of `app` two lines of two groups and one, laid out by hand.
    ///
    /// The window is never shown: the bar is made wide enough for one row, yet the line break
    /// starts a second one.
    private func arrangeTwoLines(_ app: AppRun) -> ButtonBarView {
        let bar = app.window.buttonBar
        app.kernel.toolbar.setLayout(
            [
                .copy, .showHidden, nil, .showCommandLine, .showFunctionKeys, ToolbarRegistry.lineBreak,
                .showDriveButtons
            ],
            in: fixture.settings
        )
        bar.flow.frame.size.width = 2_000
        bar.flow.layout()
        return bar
    }
}
