import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// What the window shows and how it is arranged: the bars, the panels, the title, the function keys.
@MainActor
@Suite(.serialized)
internal struct WindowLayoutTests {
    /// The window's folders and stand-ins.
    private let fixture: AppFixture
    /// The plugin that brings the test's buttons and commands.
    private let extra = WindowTestPlugin()

    /// A sandbox with the window's files.
    internal init() throws {
        fixture = try AppFixture(files: AppFixture.windowFiles)
    }

    /// The function-key bar shows what the keys do with the modifiers held, greyed out like the menus.
    @Test
    internal func theFunctionKeyBarFollowsTheModifiersAndTheCommands() async {
        let app = await fixture.startWindow(with: extra)
        defer { app.stop() }
        let bar = app.window.functionKeyBar
        func titles() -> [String] {
            bar.entries.map(\.title)
        }
        func button(_ command: CommandID) -> NSButton? {
            bar.buttons.first { $0.identifier?.rawValue == command.rawValue }
        }
        let plain = ["F3 View", "F4 Edit", "F5 Copy", "F6 Move", "F7 NewFolder", "F8 Delete", "⌘Q Exit"]
        #expect(titles() == plain)
        app.window.modifiersChanged(to: .shift)
        #expect(["⇧F4 New Text File", "⇧F5 Copy in Same Folder", "⇧F6 Rename"].allSatisfy(titles().contains))
        #expect(titles().last == "⌘Q Exit")
        app.window.modifiersChanged(to: .control)
        #expect(titles().dropLast().allSatisfy { $0.hasPrefix("⌃F") } && titles().count > 3)
        app.window.modifiersChanged(to: [.option])
        #expect(titles().contains("⌥F7 Find Files"))
        // Cmd shortcuts are not the bar's; letting go brings the plain bar back.
        app.window.modifiersChanged(to: [.command, .shift])
        #expect(titles() == plain)
        // The buttons are greyed out like the menu entries.
        app.left.model.moveCursor(to: 0)
        app.window.validateBars()
        #expect(button(.copy)?.isEnabled == false && button(.makeDirectory)?.isEnabled == true)
        app.cursor(app.left, on: "one.txt")
        app.window.validateBars()
        #expect(button(.copy)?.isEnabled == true)
    }

    /// The bars and the arrangement of the panels are commands, and the next start brings them back.
    @Test
    internal func visibilityAndArrangementAreCommandsAndSurviveARestart() async {
        let frame = NSRect(x: 40, y: 60, width: 900, height: 500)
        await switchEverythingOver(windowFrame: frame)
        let app = await fixture.startWindow(with: WindowTestPlugin())
        defer { app.stop() }
        let again = app.window
        #expect(
            again.buttonBar.isHidden && !again.driveBar.isHidden && again.commandLine.isHidden
                && again.functionKeyBar.isHidden
        )
        #expect(!again.splitView.isVertical && app.shell.layout.divider == 300)
        #expect(app.kernel.panels.source === app.right && app.right.isActive)
        #expect(again.window?.frame.size == frame.size)
        // The 50 % command puts the divider back; a hidden command line returns when asked for.
        app.commands.perform(.panelsEqualWidth)
        #expect(app.shell.layout.divider == 500 && app.commands.isChecked(.panelsEqualWidth))
        app.commands.perform(.focusCommandLine)
        #expect(!again.commandLine.isHidden && app.commands.isChecked(.showCommandLine))
        // They are in the Show menu, and they run while a job does.
        let show = app.kernel.menus.menus.first { $0.title == "Show" }?.items ?? []
        #expect(
            show.contains(.showButtonBar) && show.contains(.showDriveButtons) && show.contains(.panelsStacked)
                && show.contains(.panelsEqualWidth)
        )
        #expect(app.commands[.showButtonBar]?.runsDuringJobs == true)
        #expect(app.kernel.preferences.pages.contains { $0.title == "Layout" })
    }

    /// The title is the program's name and version, with the user's own text where they put it.
    @Test
    internal func windowTitle() async {
        #expect(WindowLayout.title(productName: "A File Manager", version: nil, extra: "") == "A File Manager")
        #expect(WindowLayout.title(productName: "A File Manager", version: "1.2", extra: "") == "A File Manager 1.2")
        #expect(WindowLayout.title(productName: "AFM", version: "1.2", extra: "*work") == "work AFM 1.2")
        #expect(WindowLayout.title(productName: "AFM", version: nil, extra: "-work") == "work AFM")
        #expect(WindowLayout.title(productName: "AFM", version: nil, extra: "$at home") == "AFM at home")
        #expect(
            WindowLayout.title(productName: "AFM", version: nil, extra: "plain") == "AFM"
                && WindowLayout.title(productName: "AFM", version: nil, extra: "$") == "AFM"
        )
        fixture.settings.set("$testing", forKey: WindowLayout.titleExtraKey)
        let app = await fixture.startWindow(with: extra)
        defer { app.stop() }
        #expect(
            app.window.window?.title.hasPrefix("A File Manager") == true
                && app.window.window?.title.hasSuffix(" testing") == true
        )
    }

    /// Starts the window, switches every bar and the arrangement over, makes the right panel
    /// the source, gives the window `windowFrame` and quits.
    private func switchEverythingOver(windowFrame frame: NSRect) async {
        let first = await fixture.startWindow(with: extra)
        let window = first.window
        #expect(
            !window.buttonBar.isHidden && window.driveBar.isHidden && !window.commandLine.isHidden
                && !window.functionKeyBar.isHidden
        )
        #expect(
            first.commands.isChecked(.showButtonBar) && first.commands.isChecked(.showCommandLine)
                && first.commands.isChecked(.showFunctionKeys)
        )
        #expect(
            first.commands.isChecked(.panelsEqualWidth) && !first.commands.isChecked(.panelsStacked)
                && window.splitView.isVertical
        )
        for command in [
            CommandID.showButtonBar, .showCommandLine, .showFunctionKeys, .showDriveButtons, .panelsStacked
        ] {
            #expect(first.commands.perform(command))
        }
        #expect(
            window.buttonBar.isHidden && !window.driveBar.isHidden && window.commandLine.isHidden
                && window.functionKeyBar.isHidden
        )
        #expect(
            !window.splitView.isVertical && first.commands.isChecked(.panelsStacked)
                && !first.commands.isChecked(.showButtonBar)
        )
        first.shell.layout.divider = 300
        #expect(!first.commands.isChecked(.panelsEqualWidth))
        // The right panel becomes the source.
        first.commands.perform(.focusTarget)
        #expect(first.kernel.panels.source === first.right)
        window.window?.setFrame(frame, display: false)
        first.shell.saveState()
        first.stop()
    }
}
