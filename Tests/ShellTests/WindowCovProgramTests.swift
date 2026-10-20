import AFMContracts
import AFMKernel
import AppKit
import StandardPlugins
import TestSupport
import Testing

@testable import AFMShell

/// The window around the panels in the running program: the command line's keys and edges, the
/// drive buttons, the main window's menus and notifications, and how the panels start.
@MainActor
@Suite(.serialized)
internal struct WindowCovProgramTests {
    /// Started before the program's plugins: it records ejecting and the places the user typed.
    @MainActor
    private final class Recorder: Plugin, ServerConsentService {
        /// The plugin's name.
        let name = "Recorder"
        /// The drives asked to be ejected.
        private(set) var ejected: [URL] = []
        /// The places the user typed.
        private(set) var chosen: [URL] = []
        /// Whether a drive can be ejected now.
        var canEject = true

        /// Registers the eject command and the server consent before anyone else does.
        func start(in kernel: Kernel) {
            kernel.services.register((any ServerConsentService).self, self)
            kernel.commands.register(
                Command(.ejectVolume, "Eject"),
                enabled: { [weak self] in self?.canEject == true },
                parameterized: { [weak self] argument in argument.location.map { self?.ejected.append($0) } }
            )
        }

        /// Kept.
        func userChose(_ location: URL) {
            chosen.append(location)
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The window's folders and stand-ins.
    private let fixture: AppFixture
    /// A file system on a "server", with a drive that can be ejected.
    private let watched = PanelWatchedFileSystem()
    /// The recorder of what would leave the program.
    private let recorder = Recorder()

    /// A sandbox with the window's files.
    internal init() throws {
        fixture = try AppFixture(files: AppFixture.windowFiles)
        watched.inner.addFile("/a/one.txt")
        watched.placeCanBeEjected = true
    }

    /// A key press with Control, as the field gets it.
    private static func control(_ keyCode: UInt16, _ character: String) -> NSEvent {
        Controls.key(keyCode, character, .control)
    }

    /// The program with the recorder first, the plugins a file manager cannot do without, and
    /// the watched file system.
    private func start() async -> AppRun {
        let kernel = Kernel(
            productName: StandardPlugins.productName,
            settings: fixture.settings,
            interaction: fixture.user
        )
        kernel.fileSystems.register(watched)
        kernel.load([recorder] + CorePlugins.make(pasteboard: fixture.scratch.pasteboard))
        let app = AppRun(kernel: kernel, shell: Shell(kernel: kernel, home: fixture.box.url("home")))
        await app.settle()
        return app
    }

    /// The line keeps Ctrl+Y, Ctrl+W, Ctrl+T, Ctrl+A and its own commands while it is typed in;
    /// other keys go to the menus.
    @Test
    internal func theCommandLineKeepsItsOwnKeys() async {
        let app = await start()
        defer { app.stop() }
        let line = app.line
        let field = line.field
        // Not typed in: nothing is kept.
        #expect(field.onKey?(Self.control(16, "y")) == false)
        app.commands.perform(.focusCommandLine)
        #expect(line.hasFocus)
        line.text = "cd some words"
        #expect(field.onKey?(Self.control(13, "w")) == true && line.text == "cd some ")
        line.text = "first second"
        line.field.currentEditor()?.selectedRange = NSRange(location: 0, length: 0)
        #expect(field.onKey?(Self.control(17, "t")) == true && line.text == " second")
        #expect(field.onKey?(Self.control(0, "a")) == true)
        #expect(line.field.currentEditor()?.selectedRange.length == line.text.utf16.count)
        #expect(field.onKey?(Self.control(11, "b")) == false && field.onKey?(Controls.key(11, "b")) == false)
        #expect(field.performKeyEquivalent(with: Self.control(16, "y")) && line.text.isEmpty)
        // A command of the line itself: the line run before comes back.
        line.history.add("ls -l")
        #expect(field.onKey?(Self.control(14, "e")) == true && line.text == "ls -l")
        line.recall(-1)
        #expect(line.text.isEmpty)
        // Typing starts the history from the newest line again.
        line.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        line.returnToFileList()
        #expect(!field.performKeyEquivalent(with: Self.control(16, "y")))
    }

    /// The edges of the line: the item under the cursor is [..], the folder is the root, a line
    /// kept out of the history, the list of earlier lines open or switched off, a line outside
    /// a window, a field whose line has gone.
    @Test
    internal func theCommandLineAtItsEdges() async {
        let app = await start()
        defer { app.stop() }
        let line = app.line
        // On [..] there is no item to add; at the root the path keeps its one slash.
        app.left.model.moveCursor(to: 0)
        line.addCursorItem(withPath: false)
        #expect(line.text.isEmpty)
        app.commands.perform(.changeDirectory, .location(URL(fileURLWithPath: "/")))
        await app.settle()
        line.addPath()
        #expect(line.text == "/")
        line.clear()
        // A line that begins with a blank is run with its blank and kept out of the history.
        let before = line.history.entries
        line.text = " cd " + fixture.box.url("B").path
        #expect(line.execute() && line.history.entries == before)
        await app.settle()
        // Nobody runs programs here: a private line that is no command stays on the line.
        line.text = " echo secret"
        #expect(!line.execute() && line.text == " echo secret")
        line.clear()
        // The list of earlier lines: opened, it keeps the arrows, Enter and Esc to itself.
        line.history.add("ls")
        // (Whether the list opens is the screen's business: the UI tests check that.)
        line.showHistory()
        line.showHistory()
        #expect(line.hasFocus)
        // The combo box opens its list a moment later, in an event loop of its own: not here,
        // where that loop would end the test process's own.
        line.field.cell.map(NSObject.cancelPreviousPerformRequests(withTarget:))
        // Remembering switched off meanwhile: the list is emptied and does not open.
        fixture.settings.set(false, forKey: CommandLineHistory.recordKey)
        line.showHistory()
        #expect(!line.isHistoryOpen && line.field.numberOfItems == 0)
        fixture.settings.set(true, forKey: CommandLineHistory.recordKey)
        // A line outside a window cannot take the keyboard; its field outlives it harmlessly.
        var field: CommandLineField?
        weak var gone: CommandLineView?
        autoreleasepool {
            let alone = CommandLineView(kernel: app.kernel, panels: app.shell.panelCoordinator)
            alone.focusField()
            #expect(!alone.hasFocus)
            field = alone.field
            gone = alone
        }
        #expect(await AppWait.until { gone == nil })
        #expect(field?.onKey?(Self.control(16, "y")) == false)
    }

    /// A place typed on the line that is on a server is the user's own choice; a local one is
    /// none of the consent's business.
    @Test
    internal func aServerTypedOnTheLineIsTheUsersChoice() async {
        let app = await start()
        defer { app.stop() }
        let line = app.line
        line.text = "cd " + fixture.box.url("B").path
        #expect(line.execute())
        await app.settle()
        #expect(recorder.chosen.isEmpty)
        watched.connectsToServer = true
        line.text = "cd watched:/a"
        #expect(line.execute())
        await app.settle()
        #expect(recorder.chosen.map { "\($0.scheme ?? ""):\($0.path)" } == ["watched:/a"])
        #expect(app.left.model.directory.scheme == "watched" && app.left.model.directory.path == "/a")
    }

    /// A drive button shows its place, in a new tab when asked; the eject button ejects its drive.
    @Test
    internal func theDriveButtonsGoThereAndEject() async throws {
        let app = await start()
        defer { app.stop() }
        let bar = app.window.driveBar
        #expect(await AppWait.until { bar.places.contains { $0.name == "Watched" } })
        let index = try #require(bar.places.firstIndex { $0.name == "Watched" })
        Controls.send(try #require(bar.ejectButtons[index]))
        #expect(recorder.ejected == [bar.places[index].url])
        // While no drive can be ejected, the eject buttons are greyed out.
        recorder.canEject = false
        bar.validate()
        #expect(bar.ejectButtons[index]?.isEnabled == false)
        Controls.send(bar.buttons[index])
        await app.settle()
        #expect(app.left.model.directory.scheme == "watched" && app.left.model.directory.path == "/")
        let tabs = app.left.tabs.tabs.count
        bar.show(bar.places[index], inNewTab: true)
        await app.settle()
        #expect(app.left.tabs.tabs.count == tabs + 1)
    }

    /// The main window's menus run and check their commands; entries of others are left alone.
    @Test
    internal func theMainWindowsMenusRunAndCheckTheirCommands() async {
        let app = await start()
        defer { app.stop() }
        let window = app.window
        let foreign = NSMenuItem(title: "Other", action: nil, keyEquivalent: "")
        #expect(window.validateMenuItem(foreign))
        window.performCommand(foreign)
        let command = app.commands[.showHidden]
        let hidden = MenuBuilder.item(command ?? Command(.showHidden, ""), keys: nil)
        #expect(window.validateMenuItem(hidden) && hidden.state == .off)
        window.performCommand(hidden)
        #expect(app.commands.isChecked(.showHidden) && window.isValidationPending)
        _ = window.validateMenuItem(hidden)
        #expect(hidden.state == .on)
    }

    /// The window follows the modifiers, its own state and the program becoming active.
    @Test
    internal func theMainWindowFollowsModifiersStateAndActivation() async throws {
        let app = await start()
        defer { app.stop() }
        let window = app.window
        let main = try #require(window.window)
        // Shift held: the function keys show what they do with it; not while text is typed.
        let shift = try #require(
            NSEvent.keyEvent(
                with: .flagsChanged,
                location: .zero,
                modifierFlags: .shift,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 56
            )
        )
        let plain = window.functionKeyBar.entries
        window.flagsChanged(with: shift)
        #expect(window.functionKeyBar.entries != plain)
        app.commands.perform(.focusCommandLine)
        window.modifiersChanged(to: .shift)
        #expect(window.functionKeyBar.entries == plain)
        // Hiding the command line while it is typed in gives the keyboard back to the panel.
        app.commands.perform(.showCommandLine)
        #expect(app.line.isHidden && !app.line.hasFocus)
        // Full screen as the window says, unless the state was saved for the next start.
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: main)
        #expect(!app.shell.layout.isFullScreen)
        app.shell.layout.isFullScreen = true
        window.saveState()
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: main)
        #expect(app.shell.layout.isFullScreen)
        // Shown again, a window left in full screen goes back to it.
        var shown: [Bool] = []
        window.present = { _, fullScreen in shown.append(fullScreen) }
        window.showWindow(nil)
        #expect(shown == [true])
        // The window becoming key or not, the program becoming active.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: main)
        #expect(window.functionKeyBar.entries == plain)
        window.perform(NSSelectorFromString("appBecameActive"))
        #expect(window.isValidationPending)
        // An event, long after the last check, has the bars checked again.
        await app.settle()
        #expect(await AppWait.until { !window.isValidationPending })
        #expect(
            await AppWait.until {
                NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: main)
                return window.isValidationPending
            }
        )
    }
}
