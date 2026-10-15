import AFMContracts
import AFMKernel
import AppKit
import StandardPlugins
import TestSupport
import Testing

@testable import AFMShell

/// What a test wants from plugins the program does not have yet: buttons for the button bar,
/// someone who runs command lines, a configuration dialog and a Help menu.
private final class WindowTestPlugin: Plugin {
    let name = "WindowTest"
    var ranLines: [String] = []
    var settingsShown = 0
    var parameters: [CommandArgument] = []
    private let runsLines: Bool

    init(runsLines: Bool = true) {
        self.runsLines = runsLines
    }

    func start(in kernel: Kernel) {
        kernel.toolbar.add(.copy, symbol: "doc.on.doc", group: 1)
        kernel.toolbar.add("cm_NobodyRegisteredThis", symbol: "questionmark", group: 1)
        kernel.toolbar.add(.showHidden, symbol: "eye", group: 2)
        kernel.toolbar.add("cm_NobodyRegisteredThisEither", symbol: "questionmark", group: 3)
        kernel.commands.register(Command(.configuration, "Options…")) { [self] in settingsShown += 1 }
        kernel.commands.register(Command("cm_TestHelp", "Help Index", [.f(1)])) {}
        kernel.commands.register(
            Command("cm_TestParameter", "Sort ▸ With Parameter"),
            parameterized: { [self] in parameters.append($0) }
        )
        kernel.commands.register(Command("cm_TestSecond", "Sort ▸ Second")) {}
        kernel.menus.add(["cm_TestHelp"], to: .helpTopics)
        kernel.menus.add(["cm_TestParameter", "cm_TestSecond"], to: .commandsTools)
        if runsLines {
            kernel.commands.register(
                Command(.runCommandLine, "Run Command Line"),
                parameterized: { [self] in ranLines.append($0.text ?? "?") }
            )
        }
    }
}

/// The real kernel, the standard plugins and the real window shell, started without showing
/// anything: the window around the panels, driven through commands.
@MainActor @Suite(.serialized) struct MainWindow {
    let box: Sandbox
    let ui = ScriptedInteraction()
    let settings = MemorySettings()
    let scratch = ScratchPasteboard()
    fileprivate let extra = WindowTestPlugin()

    init() throws {
        _ = NSApplication.shared
        box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.file("A/two words.txt", "2")
        try box.file("A/docs/in.txt", "inside")
        try box.file("B/other.txt", "o")
        try box.file("home/welcome.txt")
        func state(_ folder: String) -> PanelTabs.State {
            PanelTabs.State(tabs: [.init(location: box.url(folder))], active: 0)
        }
        settings.set(state("A"), forKey: "left.tabs")
        settings.set(state("B"), forKey: "right.tabs")
    }

    @discardableResult
    func wait(upTo seconds: TimeInterval = 60, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    @MainActor final class Running {
        let kernel: Kernel
        let shell: Shell
        var left: PanelViewController { shell.panelCoordinator.leftPanel }
        var right: PanelViewController { shell.panelCoordinator.rightPanel }
        var commands: CommandRegistry { kernel.commands }
        var window: MainWindowController { shell.mainWindow }
        var line: CommandLineView { shell.mainWindow.commandLine }

        init(kernel: Kernel, shell: Shell) {
            self.kernel = kernel
            self.shell = shell
        }

        func stop() {
            shell.shutDown()
            kernel.shutdown()
        }
    }

    fileprivate func start(with plugin: WindowTestPlugin? = nil) async -> Running {
        let kernel = Kernel(productName: StandardPlugins.productName, settings: settings, interaction: ui)
        kernel.load(CorePlugins.make(pasteboard: scratch.pasteboard) + [plugin ?? extra])
        let running = Running(kernel: kernel, shell: Shell(kernel: kernel, home: box.url("home")))
        await settle(running)
        return running
    }

    func settle(_ app: Running) async {
        await wait { !app.shell.panelCoordinator.isLoading && !app.kernel.jobs.isBusy }
    }

    // MARK: Bars

    @Test func theButtonBarShowsWhatPluginsRegistered() async {
        let app = await start()
        defer { app.stop() }
        let bar = app.window.buttonBar
        // Commands nobody registered are left out, with the separators they would leave behind.
        let commands = bar.entries.compactMap { $0 }
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
        let (copy, hidden) = (
            bar.buttons[commands.firstIndex(of: .copy) ?? 0], bar.buttons[commands.firstIndex(of: .showHidden) ?? 0]
        )
        #expect(copy.isEnabled == app.commands.isEnabled(.copy) && hidden.state == .off)
        app.left.model.row(ofName: "one.txt").map(app.left.model.moveCursor(to:))
        app.commands.perform(.showHidden)
        await settle(app)
        app.window.validateBars()
        #expect(copy.isEnabled && hidden.state == .on)
        // A click runs the command.
        hidden.performClick(nil)
        await settle(app)
        #expect(!app.commands.isChecked(.showHidden) && hidden.state == .off)
        // The user's own layout replaces the proposal at once.
        app.kernel.toolbar.setLayout([.showHidden, nil, .showCommandLine], in: settings)
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

    @Test func theButtonBarIsRearrangedByDragging() async {
        let app = await start()
        defer { app.stop() }
        let bar = app.window.buttonBar
        let br = ToolbarRegistry.lineBreak
        app.kernel.toolbar.setLayout(
            [.copy, .showHidden, nil, .showCommandLine, .showFunctionKeys, br, .showDriveButtons],
            in: settings
        )
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
        // Laid out by hand (the window is never shown): wide enough for one row, yet the
        // line break starts a second one.
        guard let flow = bar.subviews.compactMap({ $0 as? FlowView }).first else {
            Issue.record("no flow")
            return
        }
        flow.frame.size.width = 2_000
        flow.layout()
        let frames = flow.items.map { bar.convert($0.frame, from: flow) }
        #expect(frames.count == 8 && Set(frames.map(\.minY)).count == 2 && frames[6].minX == frames[0].minX)
        func middle(_ index: Int) -> NSPoint { NSPoint(x: frames[index].midX, y: frames[index].midY) }
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
        bar.apply(.group(line: 1, group: 0), to: .group(.line(0, beforeGroup: 0)))
        // The line it leaves empty disappears.
        #expect(bar.entries == [.showDriveButtons, nil, .copy, .showHidden, nil, .showCommandLine, .showFunctionKeys])
        // A group dropped below the bar starts a new line.
        bar.apply(.group(line: 0, group: 1), to: .group(.newLine(beforeLine: 1)))
        #expect(bar.entries == [.showDriveButtons, nil, .showCommandLine, .showFunctionKeys, br, .copy, .showHidden])
        bar.apply(.button(line: 0, group: 1, index: 1), to: .button(.inGroup(line: 1, group: 0, beforeButton: 1)))
        #expect(bar.entries == [.showDriveButtons, nil, .showCommandLine, br, .copy, .showFunctionKeys, .showHidden])
        // A button dragged off the bar is removed, and so is the group it leaves empty.
        bar.apply(.button(line: 0, group: 0, index: 0), to: nil)
        #expect(bar.entries == [.showCommandLine, br, .copy, .showFunctionKeys, .showHidden])
        #expect(app.kernel.toolbar.layout(from: settings).map { $0?.command } == bar.entries)
        // Reset puts back what the plugins proposed.
        #expect(app.commands.isEnabled(.resetButtonBar))
        app.commands.perform(.resetButtonBar)
        #expect(!app.kernel.toolbar.hasUserLayout(in: settings) && !app.commands.isEnabled(.resetButtonBar))
        #expect(
            bar.entries
                == ButtonBarView.entries(of: app.kernel.toolbar.defaultLayout, commands: app.commands)
                .map {
                    $0?.command
                }
        )
    }

    @Test func barButtonsKeepTheirToolTips() {
        // The hover frame has a tracking area of its own; the tool tip's must survive it.
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

    @Test func thePathBarOffersToEjectTheDriveItIsOn() {
        let bar = PathBarView(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        bar.update(text: "/Volumes/STICK/photos/*.*", segments: [])
        #expect(bar.ejectButton.isHidden)
        var ejected = 0
        bar.onEject = { ejected += 1 }
        bar.ejectableVolumeName = "STICK"
        bar.layout()
        #expect(
            !bar.ejectButton.isHidden && bar.ejectButton.toolTip == "Eject “STICK”" && bar.ejectButton.frame.maxX == 300
        )
        bar.ejectButton.performClick(nil)
        #expect(ejected == 1)
        bar.ejectableVolumeName = nil
        #expect(bar.ejectButton.isHidden)
    }

    @Test func buttonBarArrangementLeavesNoEmptyGroupOrLine() {
        let (a, b, c, d, br): (CommandID, CommandID, CommandID, CommandID, CommandID) = (
            "a", "b", "c", "d", ToolbarRegistry.lineBreak
        )
        var bar = ButtonBarArrangement(entries: [a, b, nil, c, br, d])
        #expect(bar.lines == [[[a, b], [c]], [[d]]])
        // Within its own group, after itself: the original place is accounted for.
        bar.moveButton(line: 0, group: 0, index: 0, to: .inGroup(line: 0, group: 0, beforeButton: 2))
        #expect(bar.entries == [b, a, nil, c, br, d])
        // The last button of a line takes the line with it.
        bar.moveButton(line: 1, group: 0, index: 0, to: .inGroup(line: 0, group: 1, beforeButton: 0))
        #expect(bar.entries == [b, a, nil, d, c])
        bar.moveButton(line: 0, group: 0, index: 1, to: .newGroup(.newLine(beforeLine: 1)))
        #expect(bar.entries == [b, nil, d, c, br, a])
        bar.moveButton(line: 0, group: 0, index: 0, to: .newGroup(.newLine(beforeLine: 0)))
        #expect(bar.entries == [b, br, d, c, br, a])
        bar.moveGroup(line: 2, group: 0, to: .line(0, beforeGroup: 0))
        #expect(bar.entries == [a, nil, b, br, d, c])
        bar.moveGroup(line: 0, group: 0, to: .line(0, beforeGroup: 2))
        #expect(bar.entries == [b, nil, a, br, d, c])
        bar.moveGroup(line: 1, group: 0, to: .newLine(beforeLine: 0))
        #expect(bar.entries == [d, c, br, b, nil, a])
        bar.removeButton(line: 1, group: 0, index: 0)
        #expect(bar.entries == [d, c, br, a])
        // Separators and line breaks at the ends, side by side or around nothing make nothing empty.
        #expect(ButtonBarArrangement(entries: [br, nil, a, nil, br, nil, br, b, nil]).lines == [[[a]], [[b]]])
    }

    @Test func theDriveButtonsAreHiddenUntilSwitchedOnAndShowPlaces() async {
        let app = await start()
        defer { app.stop() }
        let bar = app.window.driveBar
        #expect(bar.isHidden && !app.commands.isChecked(.showDriveButtons))
        app.commands.perform(.showDriveButtons)
        #expect(!bar.isHidden && app.commands.isChecked(.showDriveButtons))
        // The places are asked for in the background; the bar follows when they are there.
        await wait { app.shell.panelCoordinator.places.isComplete }
        #expect(bar.places.map(\.name) == app.kernel.fileSystems.all.flatMap { $0.places() }.map(\.name))
        #expect(bar.buttons.count == bar.places.count && bar.buttons.first?.title == "Home")
        // A press shows the place in the source panel. (A stand-in place: the user's own
        // folders are none of a test's business.)
        bar.show(Place(name: "B", url: box.url("B"), kind: .folder), inNewTab: false)
        await settle(app)
        #expect(app.left.model.directory.lastPathComponent == "B")
    }

    @Test func thePlaceOfAFolderIsTheOneWithTheLongestPath() {
        let places = [
            Place(name: "Disk", url: URL(fileURLWithPath: "/"), kind: .internalDisk),
            Place(name: "Home", url: URL(fileURLWithPath: "/Users/me"), kind: .home),
            Place(name: "Stick", url: URL(fileURLWithPath: "/Volumes/Stick"), kind: .externalDisk)
        ]
        #expect(DriveBarView.currentPlace(among: places, for: URL(fileURLWithPath: "/Users/me/Documents")) == 1)
        #expect(DriveBarView.currentPlace(among: places, for: URL(fileURLWithPath: "/Users/merle")) == 0)
        #expect(DriveBarView.currentPlace(among: places, for: URL(fileURLWithPath: "/Volumes/Stick")) == 2)
        #expect(DriveBarView.currentPlace(among: places, for: URL(string: "mem://host/Users/me")!) == nil)
    }

    @Test func theFunctionKeyBarFollowsTheModifiersAndTheCommands() async {
        let app = await start()
        defer { app.stop() }
        let bar = app.window.functionKeyBar
        func titles() -> [String] { bar.entries.map(\.title) }
        func isEnabled(_ command: CommandID) -> Bool? {
            bar.buttons.first { $0.identifier?.rawValue == command.rawValue }?.isEnabled
        }
        let plain = ["F3 View", "F4 Edit", "F5 Copy", "F6 Move", "F7 NewFolder", "F8 Delete", "⌘Q Exit"]
        #expect(titles() == plain)
        app.window.modifiersChanged(to: .shift)
        #expect(
            ["⇧F4 New Text File", "⇧F5 Copy in Same Folder", "⇧F6 Rename"]
                .allSatisfy(
                    titles().contains
                )
        )
        #expect(titles().last == "⌘Q Exit")
        app.window.modifiersChanged(to: .control)
        #expect(
            titles().dropLast().allSatisfy { $0.hasPrefix("⌃F") }
                && titles().count > 3
        )
        app.window.modifiersChanged(to: [.option])
        #expect(titles().contains("⌥F7 Find Files"))
        // Cmd shortcuts are not the bar's; letting go brings the plain bar back.
        app.window.modifiersChanged(to: [.command, .shift])
        #expect(titles() == plain)
        // The buttons are greyed out like the menu entries.
        app.left.model.moveCursor(to: 0)
        app.window.validateBars()
        #expect(
            isEnabled(.copy) == false
                && isEnabled(.makeDirectory) == true
        )
        app.left.model.row(ofName: "one.txt").map(app.left.model.moveCursor(to:))
        app.window.validateBars()
        #expect(isEnabled(.copy) == true)
    }

    // MARK: Layout

    @Test func visibilityAndArrangementAreCommandsAndSurviveARestart() async {
        var app = await start()
        let window = app.window
        #expect(
            !window.buttonBar.isHidden && window.driveBar.isHidden && !window.commandLine.isHidden
                && !window.functionKeyBar.isHidden
        )
        #expect(
            app.commands.isChecked(.showButtonBar) && app.commands.isChecked(.showCommandLine)
                && app.commands.isChecked(.showFunctionKeys)
        )
        #expect(
            app.commands.isChecked(.panelsEqualWidth) && !app.commands.isChecked(.panelsStacked)
                && window.splitView.isVertical
        )
        for command in [
            CommandID.showButtonBar, .showCommandLine, .showFunctionKeys, .showDriveButtons, .panelsStacked
        ] {
            #expect(app.commands.perform(command))
        }
        #expect(
            window.buttonBar.isHidden && !window.driveBar.isHidden && window.commandLine.isHidden
                && window.functionKeyBar.isHidden
        )
        #expect(
            !window.splitView.isVertical && app.commands.isChecked(.panelsStacked)
                && !app.commands.isChecked(.showButtonBar)
        )
        app.shell.layout.divider = 300
        #expect(!app.commands.isChecked(.panelsEqualWidth))
        // The right panel becomes the source.
        app.commands.perform(.focusTarget)
        #expect(app.kernel.panels.source === app.right)
        let frame = NSRect(x: 40, y: 60, width: 900, height: 500)
        window.window?.setFrame(frame, display: false)
        app.shell.saveState()
        app.stop()

        app = await start(with: WindowTestPlugin())
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

    @Test func windowTitle() async {
        #expect(WindowLayout.title(productName: "A File Manager", version: nil, extra: "") == "A File Manager")
        #expect(WindowLayout.title(productName: "A File Manager", version: "1.2", extra: "") == "A File Manager 1.2")
        #expect(WindowLayout.title(productName: "AFM", version: "1.2", extra: "*work") == "work AFM 1.2")
        #expect(WindowLayout.title(productName: "AFM", version: nil, extra: "-work") == "work AFM")
        #expect(WindowLayout.title(productName: "AFM", version: nil, extra: "$at home") == "AFM at home")
        #expect(
            WindowLayout.title(productName: "AFM", version: nil, extra: "plain") == "AFM"
                && WindowLayout.title(productName: "AFM", version: nil, extra: "$") == "AFM"
        )
        settings.set("$testing", forKey: WindowLayout.titleExtraKey)
        let app = await start()
        defer { app.stop() }
        #expect(
            app.window.window?.title.hasPrefix("A File Manager") == true
                && app.window.window?.title.hasSuffix(" testing") == true
        )
    }

    // MARK: Command line

    @Test func theCommandLineChangesDirectoryRunsCommandsAndHandsOverTheRest() async {
        let app = await start()
        defer { app.stop() }
        let line = app.line
        #expect(line.prompt.stringValue == box.url("A").path + ">")
        line.text = "cd " + box.url("B").path
        #expect(line.execute())
        await settle(app)
        #expect(app.left.model.directory.lastPathComponent == "B" && line.text.isEmpty)
        #expect(line.prompt.stringValue == box.url("B").path + ">")
        line.text = "cd \"../A/docs\""
        #expect(line.execute())
        await settle(app)
        #expect(app.left.model.directory.lastPathComponent == "docs")
        // The name of a command runs it, whatever its case; what follows is its parameter.
        line.text = "CM_gotoparent"
        #expect(line.execute())
        await settle(app)
        #expect(app.left.model.directory.lastPathComponent == "A" && app.left.model.cursorItem?.name == "docs")
        line.text = "cm_TestParameter 3"
        #expect(line.execute())
        line.text = "cm_TestParameter some text"
        #expect(line.execute() && extra.parameters == [.index(3), .text("some text")])
        // Anything else goes to whoever runs programs.
        line.text = "ls -l  "
        #expect(line.execute() && extra.ranLines == ["ls -l"])
        #expect(
            line.history.entries == [
                "ls -l", "cm_TestParameter some text", "cm_TestParameter 3", "CM_gotoparent", "cd \"../A/docs\"",
                "cd " + box.url("B").path
            ]
        )
        #expect(line.field.objectValues.count == 6)
        // An empty line is Enter on the item under the cursor.
        #expect(line.execute())
        await settle(app)
        #expect(app.left.model.directory.lastPathComponent == "docs" && line.history.entries.count == 6)
        // The prompt follows the source panel.
        app.commands.perform(.focusTarget)
        #expect(line.prompt.stringValue == box.url("B").path + ">")
        // The history is kept in the settings, newest first, a repeated line once.
        line.text = "cm_TestParameter 3"
        line.execute()
        #expect(CommandLineHistory(settings: settings).entries.prefix(2) == ["cm_TestParameter 3", "ls -l"])
        #expect(CommandLineHistory(settings: settings).entries.count == 6)
    }

    @Test func aLineNobodyTakesStaysOnTheCommandLine() async {
        let app = await start(with: WindowTestPlugin(runsLines: false))
        defer { app.stop() }
        var beeps = 0
        app.commands.onRejected = { beeps += 1 }
        app.line.text = "ls -l"
        #expect(!app.line.execute() && beeps == 1)
        #expect(app.line.text == "ls -l" && app.line.history.entries.isEmpty)
        // The same while a job blocks commands that change the panels.
        let gate = DispatchSemaphore(value: 0)
        app.kernel.jobs.run(title: "Busy", work: { _ in gate.wait() }, completion: { _ in })
        app.line.text = "cd .."
        #expect(!app.line.execute() && app.line.text == "cd .." && beeps == 2)
        gate.signal()
        await settle(app)
        #expect(app.line.execute() && app.line.text.isEmpty)
        await settle(app)
        #expect(app.left.model.directory.path == box.url("A").deletingLastPathComponent().path)
    }

    @Test func namesAndPathsArePutOnTheCommandLine() async {
        let app = await start()
        defer { app.stop() }
        let line = app.line
        app.left.model.row(ofName: "one.txt").map(app.left.model.moveCursor(to:))
        app.commands.perform(.addNameToCommandLine)
        #expect(line.text == "one.txt ")
        app.left.model.row(ofName: "two words.txt").map(app.left.model.moveCursor(to:))
        app.commands.perform(.addPathAndNameToCommandLine)
        #expect(line.text == "one.txt \"\(box.url("A").path)/two words.txt\" ")
        line.clear()
        line.text = "open"
        app.commands.perform(.addPathToCommandLine)
        #expect(line.text == "open \(box.url("A").path)/")
        // The keys of the specification.
        let keys = app.kernel.keyBindings
        #expect(keys.command(for: Shortcut(.returnKey, .control)) == .addNameToCommandLine)
        #expect(keys.command(for: Shortcut(.returnKey, [.control, .shift])) == .addPathAndNameToCommandLine)
        #expect(keys.command(for: Shortcut(.character("p"), .control)) == .addPathToCommandLine)
        #expect(
            keys.command(for: .f(8, .option)) == .commandLineHistory
                && keys.command(for: Shortcut(.downArrow, .control)) == .commandLineHistory
        )
        #expect(keys.command(for: .cmd("l")) == .focusCommandLine && app.kernel.keyClashes.isEmpty)
        // Ctrl+E walks back through the history, the other command forth again.
        line.clear()
        for text in ["first", "second"] {
            line.text = text
            line.execute()
        }
        app.commands.perform(.previousCommandLine)
        #expect(line.text == "second")
        app.commands.perform(.previousCommandLine)
        app.commands.perform(.previousCommandLine)
        #expect(line.text == "first")
        app.commands.perform(.nextCommandLine)
        #expect(line.text == "second")
        app.commands.perform(.clearCommandLine)
        #expect(line.text.isEmpty)
    }

    @Test func theKeysOfTheCommandLineLeadBackToTheFileList() async {
        let app = await start()
        defer { app.stop() }
        let line = app.line
        let editor = NSTextView()
        func send(_ selector: Selector) -> Bool { line.control(line.field, textView: editor, doCommandBy: selector) }
        app.commands.perform(.focusCommandLine)
        // Tab keeps the text, Esc clears it; both make the list the place for keys again.
        line.text = "half typed"
        #expect(send(#selector(NSResponder.insertTab(_:))) && line.text == "half typed" && !line.hasFocus)
        #expect(send(#selector(NSResponder.cancelOperation(_:))) && line.text.isEmpty)
        // ↑ and ↓ move the cursor of the file list.
        app.left.model.moveCursor(to: 0)
        #expect(send(#selector(NSResponder.moveDown(_:))) && app.left.model.cursor == 1)
        #expect(send(#selector(NSResponder.moveUp(_:))) && app.left.model.cursor == 0)
        // Enter runs the line; other editing is the text field's own.
        line.text = "cd docs"
        #expect(send(#selector(NSResponder.insertNewline(_:))))
        await settle(app)
        #expect(app.left.model.directory.lastPathComponent == "docs")
        #expect(!send(#selector(NSResponder.deleteBackward(_:))))
    }

    @Test func whatALineMeans() {
        let commands = CommandRegistry()
        commands.register(Command("cm_SearchFor", "Find")) {}
        func action(_ line: String) -> CommandLineAction { CommandLineAction(line: line, commands: commands) }
        #expect(action("") == .openCursorItem && action("   ") == .openCursorItem)
        #expect(action("cd /tmp/x y") == .changeDirectory("/tmp/x y") && action("CD  ..") == .changeDirectory(".."))
        #expect(action("cd") == .changeDirectory("~") && action("cd '/a b'") == .changeDirectory("/a b"))
        #expect(
            action("cm_SearchFor") == .command("cm_SearchFor", .nothing)
                && action("cm_searchfor 2") == .command("cm_SearchFor", .index(2))
        )
        #expect(action("cm_SearchFor \"*.txt\"") == .command("cm_SearchFor", .text("*.txt")))
        #expect(action("cdrom eject") == .run("cdrom eject") && action("cm_Unknown") == .run("cm_Unknown"))
        #expect(CommandLineAction.quoted("a b") == "\"a b\"" && CommandLineAction.quoted("ab") == "ab")
        #expect(CommandLineAction.appending("x", to: "") == "x" && CommandLineAction.appending("x", to: "a") == "a x")
        #expect(CommandLineAction.appending("x", to: "a ") == "a x")
    }

    @Test func theHistoryKeepsTheNewestTwentyLines() {
        let settings = MemorySettings()
        let history = CommandLineHistory(settings: settings)
        for number in 1...25 { history.add("line \(number)") }
        history.add("line 10")
        history.add("  ")
        #expect(history.entries.count == 20 && history.entries.prefix(2) == ["line 10", "line 25"])
        #expect(CommandLineHistory(settings: settings).entries == history.entries)
    }

    // MARK: Menu bar

    @Test func theMenuBarHasTheMacsOwnMenusAroundThePlugins() async {
        let app = await start()
        defer { app.stop() }
        let menu = app.shell.makeMainMenu()
        #expect(
            menu.items.map(\.title) == [
                "A File Manager", "Files", "Edit", "Mark", "Commands", "Show", "Configuration", "Window", "Help"
            ]
        )
        func titles(_ index: Int) -> [String] {
            menu.items[index].submenu?.items.map { $0.isSeparatorItem ? "-" : $0.title } ?? []
        }
        // Settings… runs the configuration command.
        #expect(
            titles(0) == [
                "About A File Manager", "-", "Settings…", "-", "Services", "-", "Hide A File Manager", "Hide Others",
                "Show All",
                "-", "Quit A File Manager"
            ]
        )
        let settingsItem = menu.items[0].submenu?.items[2]
        #expect(settingsItem?.keyEquivalent == "," && settingsItem?.keyEquivalentModifierMask == .command)
        #expect(app.shell.canShowSettings)
        app.shell.showSettings()
        #expect(extra.settingsShown == 1)
        // Text fields get the editing actions: Undo and Redo from the shell, the others from
        // the plugins' commands, which travel the same path.
        #expect(titles(2).starts(with: ["Undo", "Redo", "-"]))
        let actions = menu.items.flatMap { $0.submenu?.items ?? [] }.compactMap(\.action)
        for action in [
            #selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:)),
            #selector(NSResponder.selectAll(_:)),
            Selector(("undo:")), Selector(("redo:"))
        ] {
            #expect(actions.filter { $0 == action }.count == 1)
        }
        // The Help menu of the plugins comes last and is the one the system knows as such.
        #expect(MenuBuilder.submenu(MenuBuilder.helpMenuID, of: menu)?.items.map(\.title) == ["Help Index"])
        #expect(MenuBuilder.submenu(MenuBuilder.windowMenuID, of: menu)?.items.first?.title == "Minimize")
        #expect(MenuBuilder.submenu(MenuBuilder.servicesMenuID, of: menu) != nil)
        // `Sort ▸ …` titles share a submenu.
        let sort = menu.items[4].submenu?.items.first { $0.title == "Sort" }?.submenu
        #expect(sort?.items.map(\.title) == ["With Parameter", "Second"])
        #expect(sort?.items.first.flatMap(MenuBuilder.command(of:)) == "cm_TestParameter")
    }

    @Test func aMenuBarWithoutEditingCommandsStillEdits() {
        let kernel = Kernel(productName: "Bare", settings: MemorySettings(), interaction: ScriptedInteraction())
        kernel.commands.register(Command("cm_One", "One", [.cmd("z")])) {}
        kernel.menus.add(["cm_One"], to: .filesOpen)
        let menu = MenuBuilder.mainMenu(appName: "Bare", kernel: kernel)
        #expect(menu.items.map(\.title) == ["Bare", "Files", "Edit", "Window"])
        let edit = menu.items[2].submenu?.items ?? []
        #expect(
            edit.map { $0.isSeparatorItem ? "-" : $0.title } == [
                "Undo", "Redo", "-", "Cut", "Copy", "Paste", "Select All"
            ]
        )
        // A key that belongs to a command is not taken a second time.
        #expect(edit[0].keyEquivalent.isEmpty && edit[1].keyEquivalent == "z" && edit[4].keyEquivalent == "c")
        // No configuration command, no Settings entry.
        #expect(menu.items[0].submenu?.items.contains { $0.title == "Settings…" } == false)
    }

    @Test func aMenuTooLongForTheScreenFoldsItsLastSections() {
        let commands = CommandRegistry()
        var ids: [CommandID?] = []
        for section in 0..<5 {
            if section > 0 { ids.append(nil) }
            for entry in 0..<4 {
                let id = CommandID(rawValue: "c\(section)\(entry)")
                commands.register(Command(id, "Entry \(section).\(entry)")) {}
                ids.append(id)
            }
        }
        let menu = MenuBuilder.menu("Long", ids, commands: commands, keys: nil)
        #expect(menu.items.count == 24)
        MenuBuilder.foldOverflow(of: menu, limit: 30)
        #expect(menu.items.count == 24)
        MenuBuilder.foldOverflow(of: menu, limit: 12)
        // Two sections and their separator stay, the rest is one step away.
        #expect(menu.items.count == 11 && menu.items.last?.title == "More" && menu.items[9].isSeparatorItem)
        let more = menu.items.last?.submenu?.items ?? []
        #expect(more.count == 14 && more.first?.title == "Entry 2.0" && more.last?.title == "Entry 4.3")
        // A menu without sections cannot be folded sensibly.
        let entries: [CommandID] = ids.compactMap { $0 }
        let flat = MenuBuilder.menu("Flat", entries, commands: commands, keys: nil)
        MenuBuilder.foldOverflow(of: flat, limit: 12)
        #expect(flat.items.count == 20)
    }

    @Test func shortcutsAsTheMacWritesThem() {
        #expect(Shortcut.f(5).displayText == "F5" && Shortcut.f(6, [.shift, .control]).displayText == "⌃⇧F6")
        #expect(Shortcut.cmd("c", .shift).displayText == "⇧⌘C" && Shortcut(.returnKey, .control).displayText == "⌃↩")
        #expect(Shortcut(.downArrow, .option).displayText == "⌥↓" && Shortcut(.keypadPlus).displayText == "Num +")
    }

    // MARK: Progress window

    /// A job that reports until it is told to end, and counts its reports.
    final class Reporter: @unchecked Sendable {
        private let lock = NSLock()
        private var reports = 0
        private var finished = false

        var count: Int { lock.withLock { reports } }
        func end() { lock.withLock { finished = true } }

        func work(_ monitor: any JobMonitor) -> String {
            while !monitor.cancellation.isCancelled, !lock.withLock({ finished }) {
                monitor.report(JobProgress(lines: ["Working"], itemsDone: count, itemsTotal: 1_000_000))
                lock.withLock { reports += 1 }
                Thread.sleep(forTimeInterval: 0.001)
            }
            return monitor.cancellation.isCancelled ? "cancelled" : "finished"
        }
    }

    @Test func aJobCanBePausedResumedAndCancelledWhilePaused() async {
        let app = await start()
        defer { app.stop() }
        let service = app.shell.jobService
        let reporter = Reporter()
        var result = ""
        service.run(title: "Long", work: { reporter.work($0) }, completion: { result = $0 })
        await wait { reporter.count > 5 }
        #expect(!service.isPaused)
        service.setPaused(true)
        #expect(service.isPaused && service.isBusy)
        // The job stops at its next report and stays there.
        try? await Task.sleep(nanoseconds: 150_000_000)
        let held = reporter.count
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(reporter.count == held && result.isEmpty)
        service.setPaused(false)
        let moved = await wait { reporter.count > held + 5 }
        #expect(moved && !service.isPaused)
        // Cancel reaches a paused job.
        service.setPaused(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        service.cancelCurrent()
        await settle(app)
        #expect(result == "cancelled" && !service.isPaused && !service.isBusy)
        // Without a job there is nothing to pause.
        service.setPaused(true)
        #expect(!service.isPaused)
    }

    @Test func quittingStopsAPausedJob() async {
        let app = await start()
        defer { app.stop() }
        let service = app.shell.jobService
        let reporter = Reporter()
        var results: [String] = []
        service.run(title: "First", work: { reporter.work($0) }, completion: { results.append($0) })
        service.run(title: "Second", work: { reporter.work($0) }, completion: { results.append($0) })
        await wait { reporter.count > 2 }
        service.setPaused(true)
        var idle = false
        service.cancelAll { idle = true }
        let ended = await wait(upTo: 600) { idle }
        #expect(ended && results == ["cancelled", "cancelled"])
    }

    @Test func theBackgroundKeepsCommandsThatChangeFilesBlocked() async {
        let app = await start()
        defer { app.stop() }
        let service = app.shell.jobService
        app.left.model.row(ofName: "one.txt").map(app.left.model.moveCursor(to:))
        // Nothing runs: nothing to send to the background.
        service.setRunsInBackground(true)
        #expect(!service.runsInBackground && service.queueLength == 0)
        let first = Reporter()
        let second = Reporter()
        var results: [String] = []
        service.run(title: "First", work: { first.work($0) }, completion: { results.append($0) })
        service.run(title: "Second", work: { second.work($0) }, completion: { results.append($0) })
        service.run(title: "Third", work: { _ in "third" }, completion: { results.append($0) })
        #expect(service.queueLength == 2)
        service.setRunsInBackground(true)
        #expect(service.runsInBackground && service.isBusy)
        // The main window is free, but only for what may run beside a job.
        #expect(!app.commands.isEnabled(.copy) && !app.commands.isEnabled(.goToParent))
        #expect(
            app.commands.isEnabled(.cursorToLastEntry) && app.commands.isEnabled(.showCommandLine)
                && app.commands.isEnabled(.focusTarget)
        )
        // The window is not shown in a test; the queue goes on behind it all the same.
        #expect(service.display.panel == nil)
        first.end()
        await wait { second.count > 0 }
        #expect(service.queueLength == 1 && service.runsInBackground && results == ["finished"])
        second.end()
        await settle(app)
        #expect(results == ["finished", "finished", "third"])
        // The next queue starts in the foreground again.
        #expect(!service.runsInBackground && service.queueLength == 0 && app.commands.isEnabled(.copy))
    }

    @Test func progressTexts() {
        let copying = JobProgress(
            lines: ["From: a", "To: b"],
            itemsDone: 7,
            itemsTotal: 14,
            bytesDone: 2 << 20,
            bytesTotal: 8 << 20
        )
        #expect(
            ProgressSheet.countLine(for: copying, remaining: false)
                == "7 / 14     \(Format.shortSize(2 << 20)) of \(Format.shortSize(8 << 20))"
        )
        #expect(
            ProgressSheet.countLine(for: copying, remaining: true)
                == "-7 / 14     -\(Format.shortSize(6 << 20)) of \(Format.shortSize(8 << 20))"
        )
        #expect(
            ProgressSheet.countLine(for: JobProgress(lines: [], itemsDone: 3, itemsTotal: 4), remaining: true)
                == "-1 / 4"
        )
        #expect(ProgressSheet.queueLine(0).isEmpty && ProgressSheet.queueLine(1) == "1 more job waiting")
        #expect(ProgressSheet.queueLine(3) == "3 more jobs waiting")
    }

    @Test func theProgressWindowShowsStateAndOffersItsButtons() {
        let view = ProgressContentView()
        let progress = JobProgress(lines: ["From: a"], itemsDone: 1, itemsTotal: 4)
        var state = ProgressContentView.State(
            title: "Copy:",
            progress: progress,
            speed: "about 6 s left",
            showsRemaining: false,
            queue: "1 more job waiting",
            isPaused: false,
            isCancelled: false,
            inBackground: false
        )
        view.arrange(compact: false)
        view.show(state)
        #expect(
            view.pauseButton.title == "Pause" && view.backgroundButton.title == "Background"
                && view.cancelButton.keyEquivalent == "\u{1b}"
        )
        state.isPaused = true
        state.inBackground = true
        view.arrange(compact: true)
        view.show(state)
        // In its own window Esc no longer stops the job.
        #expect(
            view.pauseButton.title == "Resume" && view.backgroundButton.title == "Foreground"
                && view.cancelButton.keyEquivalent.isEmpty
        )
        state.isCancelled = true
        view.show(state)
        #expect(!view.pauseButton.isEnabled && !view.cancelButton.isEnabled)
    }

    // MARK: Forms

    @Test func aFormReadsItsFieldsAndPutsTheKeyboardInTheFirstInput() {
        let fields: [FormField] = [
            .note("Fill this in."), .checkbox("flag", "Recursive", true), .text("name", "Name:", "report.txt"),
            .password("secret", "Password:"),
            .lines("notes", "Notes:", "a\nb"), .choice("kind", "Kind:", ["One", "Two", "Two"], selected: 2),
            .list("row", "Pick:", ["x", "y", "z"], selected: 1)
        ]
        let dialog = FormDialog(fields: fields)
        let alert = dialog.makeAlert(title: "Form", detail: "Detail", buttons: ["OK", "Apply"])
        #expect(
            alert.buttons.map(\.title) == ["OK", "Apply", "Cancel"] && alert.buttons.last?.keyEquivalent == "\u{1b}"
        )
        #expect(alert.buttons.first?.keyEquivalent == "\r")
        // Unchanged, the form answers with what the fields were given.
        let answer = dialog.values(button: 1)
        #expect(answer.button == 1 && answer.values == FormValues(defaultsOf: fields).values)
        #expect(
            (dialog.firstInput as? NSTextField)?.stringValue == "report.txt"
                && alert.window.initialFirstResponder === dialog.firstInput
        )
        #expect(dialog.scrollView == nil && dialog.lists.count == 1 && dialog.lists[0].searchField == nil)
    }

    @Test func aFormWithManyFieldsIsScrolled() {
        let fields = (1...40).map { FormField.text("field\($0)", "Field \($0):", "\($0)") }
        let dialog = FormDialog(fields: fields)
        let alert = dialog.makeAlert(title: "Many", detail: "", buttons: ["OK"], maximumHeight: 300)
        #expect(dialog.scrollView != nil && alert.accessoryView === dialog.scrollView)
        #expect(dialog.scrollView?.frame.height == 300 && (dialog.scrollView?.documentView?.frame.height ?? 0) > 900)
        // The first row is at the top of what is seen.
        #expect(dialog.scrollView?.contentView.isFlipped == true && dialog.scrollView?.contentView.bounds.origin.y == 0)
        #expect(dialog.values(button: 0).text("field40") == "40")
    }

    @Test func aLongListIsNarrowedDownByTyping() {
        let rows = (1...30).map { "Entry \($0)" } + ["Übersicht"]
        let dialog = FormDialog(fields: [.list("row", "", rows, selected: 4)])
        _ = dialog.makeAlert(title: "Pick", detail: "", buttons: ["Go"])
        let list = dialog.lists[0]
        #expect(list.searchField != nil && dialog.firstInput === list.searchField && list.selectedRow == 4)
        list.filter("entry 2")
        #expect(
            list.shown.map { rows[$0] }.starts(with: ["Entry 2", "Entry 20", "Entry 21"]) && list.shown.count == 11
        )
        // The chosen row is gone from the list: the first one that is left is chosen.
        #expect(list.selectedRow == 1 && dialog.values(button: 0).index("row") == 1)
        list.moveSelection(by: 2)
        #expect(list.selectedRow == 20)
        list.moveSelection(by: 100)
        #expect(list.selectedRow == 28)
        // A row that stays in the list stays chosen; the answer counts in the whole list.
        list.filter("")
        #expect(list.shown.count == 31 && list.selectedRow == 28)
        list.filter("ubersicht")
        #expect(list.selectedRow == 30)
        list.filter("nothing like this")
        #expect(list.selectedRow == -1 && dialog.values(button: 0).index("row") == -1)
    }
}
