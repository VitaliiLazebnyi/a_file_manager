import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The command line below the panels: what a line does, its keys and its history.
@MainActor
@Suite(.serialized)
internal struct WindowCommandLineTests {
    /// The window's folders and stand-ins.
    private let fixture: AppFixture
    /// The plugin that brings the test's buttons and commands, and runs command lines.
    private let extra = WindowTestPlugin()

    /// A sandbox with the window's files.
    internal init() throws {
        fixture = try AppFixture(files: AppFixture.windowFiles)
    }

    /// `cd` changes the folder, a command's name runs it, anything else goes to whoever runs programs.
    @Test
    internal func theCommandLineChangesDirectoryRunsCommandsAndHandsOverTheRest() async {
        let app = await fixture.startWindow(with: extra)
        defer { app.stop() }
        let line = app.line
        let box = fixture.box
        #expect(line.prompt.stringValue == box.url("A").path + ">")
        line.text = "cd " + box.url("B").path
        #expect(line.execute())
        await app.settle()
        #expect(app.left.model.directory.lastPathComponent == "B" && line.text.isEmpty)
        #expect(line.prompt.stringValue == box.url("B").path + ">")
        line.text = "cd \"../A/docs\""
        #expect(line.execute())
        await app.settle()
        #expect(app.left.model.directory.lastPathComponent == "docs")
        // The name of a command runs it, whatever its case; what follows is its parameter.
        line.text = "CM_gotoparent"
        #expect(line.execute())
        await app.settle()
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
        await app.settle()
        #expect(app.left.model.directory.lastPathComponent == "docs" && line.history.entries.count == 6)
        // The prompt follows the source panel.
        app.commands.perform(.focusTarget)
        #expect(line.prompt.stringValue == box.url("B").path + ">")
        // The history is kept in the settings, newest first, a repeated line once.
        line.text = "cm_TestParameter 3"
        line.execute()
        #expect(CommandLineHistory(settings: fixture.settings).entries.prefix(2) == ["cm_TestParameter 3", "ls -l"])
        #expect(CommandLineHistory(settings: fixture.settings).entries.count == 6)
    }

    /// A line nobody takes, or one refused while a job runs, stays on the line with a beep.
    @Test
    internal func aLineNobodyTakesStaysOnTheCommandLine() async {
        let app = await fixture.startWindow(with: WindowTestPlugin(runsLines: false))
        defer { app.stop() }
        var beeps = 0
        app.commands.onRejected = { beeps += 1 }
        app.line.text = "ls -l"
        #expect(!app.line.execute() && beeps == 1)
        #expect(app.line.text == "ls -l" && app.line.history.entries.isEmpty)
        // The same while a job blocks commands that change the panels.
        let gate = DispatchSemaphore(value: 0)
        app.kernel.jobs.run(title: "Busy", work: { _ in gate.wait() }, completion: { _ in () })
        app.line.text = "cd .."
        #expect(!app.line.execute() && app.line.text == "cd .." && beeps == 2)
        gate.signal()
        await app.settle()
        #expect(app.line.execute() && app.line.text.isEmpty)
        await app.settle()
        #expect(app.left.model.directory.path == fixture.box.url("A").deletingLastPathComponent().path)
    }

    /// The names and paths of the source panel go on the line; Ctrl+E and its partner walk the history.
    @Test
    internal func namesAndPathsArePutOnTheCommandLine() async {
        let app = await fixture.startWindow(with: extra)
        defer { app.stop() }
        let line = app.line
        let folder = fixture.box.url("A").path
        app.cursor(app.left, on: "one.txt")
        app.commands.perform(.addNameToCommandLine)
        #expect(line.text == "one.txt ")
        app.cursor(app.left, on: "two words.txt")
        app.commands.perform(.addPathAndNameToCommandLine)
        #expect(line.text == "one.txt \"\(folder)/two words.txt\" ")
        line.clear()
        line.text = "open"
        app.commands.perform(.addPathToCommandLine)
        #expect(line.text == "open \(folder)/")
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

    /// Tab and Esc leave the line, the arrows move the list's cursor, Enter runs the line.
    @Test
    internal func theKeysOfTheCommandLineLeadBackToTheFileList() async {
        let app = await fixture.startWindow(with: extra)
        defer { app.stop() }
        let line = app.line
        let editor = NSTextView()
        func send(_ selector: Selector) -> Bool {
            line.control(line.field, textView: editor, doCommandBy: selector)
        }
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
        await app.settle()
        #expect(app.left.model.directory.lastPathComponent == "docs")
        #expect(!send(#selector(NSResponder.deleteBackward(_:))))
    }

    /// A line is `cd`, a command with its parameter, Enter on the cursor's item, or a program to run.
    @Test
    internal func whatALineMeans() {
        let commands = CommandRegistry()
        commands.register(Command("cm_SearchFor", "Find")) {
            // Nothing to do: the command only has to be known.
        }
        func action(_ line: String) -> CommandLineAction {
            CommandLineAction(line: line, commands: commands)
        }
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

    /// The history keeps the newest twenty lines, a repeated one moved to the front, no blank one.
    @Test
    internal func theHistoryKeepsTheNewestTwentyLines() {
        let settings = MemorySettings()
        let history = CommandLineHistory(settings: settings)
        for number in 1...25 {
            history.add("line \(number)")
        }
        history.add("line 10")
        history.add("  ")
        #expect(history.entries.count == 20 && history.entries.prefix(2) == ["line 10", "line 25"])
        #expect(CommandLineHistory(settings: settings).entries == history.entries)
    }
}
