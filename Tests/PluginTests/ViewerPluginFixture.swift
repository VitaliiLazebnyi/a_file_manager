import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import ViewerPlugin

/// A suite of the viewer's window tests: it holds a fresh setup, and gets the setup's parts and the steps the tests
/// share (keys, waiting, opening a Lister) from the extension.
@MainActor
internal protocol ViewerPluginFixture {
    /// The viewer and the program around it, made for this test.
    var setup: ViewerPluginSetup { get }
}

/// The parts of the setup by their short names, and the steps the window tests share.
extension ViewerPluginFixture {
    /// The file system the files are read from.
    internal var memory: MemoryFileSystem { setup.memory }
    /// The program around the viewer.
    internal var bench: TestBench { setup.bench }
    /// The viewer.
    internal var plugin: ViewerPlugin { setup.plugin }
    /// The tests' own pasteboard.
    internal var pasteboard: NSPasteboard { setup.scratch.pasteboard }
    /// The program's commands.
    internal var commands: CommandRegistry { bench.commands }
    /// The scripted answers to the program's questions, and the log of what it asked.
    internal var interaction: ScriptedInteraction { bench.interaction }

    /// The cover of a panel, where the quick view is put.
    internal func host(_ panel: FakePanel) throws -> ViewerPluginSetup.OverlayHost {
        try #require(setup.hosts[ObjectIdentifier(panel)])
    }

    /// Waits, letting the main thread run, until the condition holds or the tests' ceiling has passed; returns
    /// whether it holds.
    @discardableResult
    internal func wait(until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(Wait.ceiling)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
        return condition()
    }

    /// A key press of characters as the window would deliver it.
    internal func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try keyEvent(characters, code: 0, flags)
    }

    /// A press of a key that types no character (an arrow, a function key) as the window would deliver it.
    internal func key(code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try keyEvent("", code: code, flags)
    }

    /// A press of the function key F`number` (1 to 12).
    internal func functionKey(_ number: Int, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        let codes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        return try key(code: codes[number - 1], flags)
    }

    /// Opens a Lister on a file of the left panel and waits until its text is shown.
    internal func openLister(on name: String) async throws -> ViewerWindowController {
        bench.left.moveCursor(toName: name)
        #expect(commands.perform(.viewSingle))
        let controller = try #require(plugin.windows.last)
        controller.pane.pasteboard = pasteboard
        controller.window?.layoutIfNeeded()
        #expect(await wait { controller.pane.loaded != nil })
        return controller
    }

    /// Waits until the pager shows the rows of the pane's current mode.
    internal func rowsShown(_ controller: ViewerWindowController) async -> Bool {
        let pane = controller.pane
        return await wait {
            pane.pager.document?.layout == pane.layout
                && pane.pager.document?.encoding == pane.encoding.forLayout(pane.layout)
                && !pane.pager.isIndexing && pane.pager.position != nil
        }
    }

    /// The text of the first rows the pane's document has, none while there is no document.
    internal func visibleText(_ pane: ViewerPane, rows: Int) -> [String] {
        ((try? pane.pager.document?.rows(from: 0, count: rows, cancellation: nil)) ?? []).map(\.text)
    }

    /// The key-down event of the characters and key code, with the modifier keys.
    private func keyEvent(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: code
            )
        )
    }
}
