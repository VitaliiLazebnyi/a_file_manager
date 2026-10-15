import AFMContracts
import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import CompareContentPlugin
@testable import DirectorySyncPlugin

/// The Synchronize directories window on two folders of a memory file system.
///
/// Nothing is put on screen: the window is presented to a recorder, and the folder panel and
/// the sets pop-up answer from the test.
@MainActor
internal final class CovSyncStage {
    /// The two folders, `/A` and `/B`.
    internal let memory = MemoryFileSystem()
    /// The plugin; its comparisons run at once.
    internal let plugin = DirectorySyncPlugin(opensWindows: false)
    /// The kernel with fake panels on the two folders.
    internal let bench: TestBench
    /// What the window shows.
    internal let session: SyncSession
    /// The window.
    internal let controller: SyncWindowController
    /// Where the window is put instead of on screen.
    internal let presenter = StabilityPresenter()
    /// Which windows of the tool came on screen or stay open.
    internal let windows = StabilityWindows { $0.title == "Synchronize directories" }
    /// What the folder panel and the sets pop-up answer, and how often they were asked.
    internal let answers = CovSyncAnswers()

    /// The window's content.
    internal var content: NSView? { controller.window?.contentView }
    /// The result list.
    internal var table: NSTableView? { views(NSTableView.self).first }
    /// The text fields the user types in, from the left: left path, mask, right path, hours.
    internal var fields: [NSTextField] { views(NSTextField.self).filter(\.isEditable) }

    /// Fills the two folders with a few files of every kind and the empty `folders`, and opens the tool.
    internal init(empty folders: [String]) throws {
        let early = Date(timeIntervalSince1970: 1_000_000)
        memory.addFile("/A/new.txt", "from the left", modified: early.addingTimeInterval(500))
        memory.addFile("/A/update.txt", "newer on the left", modified: early.addingTimeInterval(60))
        memory.addFile("/B/update.txt", "older", modified: early)
        memory.addFile("/B/sub/arrives.txt", "from the right", modified: early)
        memory.addFile("/A/sub/deeper/same.txt", "same", modified: early)
        memory.addFile("/B/sub/deeper/same.txt", "same", modified: early)
        memory.addFile("/A/odd.txt", "left text", modified: early)
        memory.addFile("/B/odd.txt", "right text!", modified: early)
        for folder in folders { _ = memory.addDirectory(folder) }
        bench = TestBench(
            plugins: [plugin, CompareContentPlugin(opensWindows: false)],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
        bench.commands.perform(.synchronizeDirectories)
        guard let opened = plugin.session else { throw CocoaError(.featureUnsupported) }
        session = opened
        controller = SyncWindowController(session: session, effects: answers.effects)
        controller.present = presenter.present
    }

    /// Every view of `type` in the window, in order.
    internal func views<View: NSView>(_: View.Type) -> [View] {
        func walk(_ view: NSView) -> [View] {
            view.subviews.flatMap { subview in [subview as? View].compactMap(\.self) + walk(subview) }
        }
        return content.map(walk) ?? []
    }

    /// The button with this title.
    internal func button(_ title: String) -> NSButton? {
        views(NSButton.self).first { $0.title == title }
    }

    /// Clicks the button with this title; false when there is none.
    @discardableResult
    internal func press(_ title: String) -> Bool {
        guard let found = button(title) else {
            return false
        }
        return found.sendAction(found.action, to: found.target)
    }

    /// Presses a key in the result list.
    internal func type(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags) throws {
        let event = NSEvent.keyEvent(
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
        table?.keyDown(with: try #require(event))
    }

    /// The position in the list of the row of this name.
    internal func position(_ name: String) -> Int? {
        session.entries.firstIndex { entry in
            guard case .row(let index) = entry else {
                return false
            }
            return session.rows[index].name == name
        }
    }

    /// The index in the session's rows of the row of this name.
    internal func row(_ name: String) -> Int? {
        session.rows.firstIndex { $0.name == name }
    }

    /// Closes everything and checks that no window of the tool came on screen or stays open.
    internal func finish() {
        controller.close()
        plugin.stop()
        presenter.closeAll()
        #expect(windows.shown.isEmpty && windows.open.isEmpty)
        windows.closeAll()
    }

    deinit {
        // Nothing to release.
    }
}
