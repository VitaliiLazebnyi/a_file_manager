import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import CompareContentPlugin

/// A compare window on two files of a memory file system, its session run inline, and what the window did
/// outside itself recorded instead of done: beeps, the file panel, the font panel, the clipboard.
///
/// Main thread only. `close()` closes the window; every test calls it (deferred).
@MainActor
internal final class CoverageCompareStage {
    /// What the window asked of the desktop.
    @MainActor
    internal final class Recorder {
        /// Where the window is put instead of on the desktop: tests keep it off screen.
        internal let presenter = StabilityPresenter()
        /// How often the window beeped.
        internal var beeps: Int { beepCount.value }
        /// The same, kept apart, for a test that lets go of the window and its recorder.
        internal let beepCount = Shared(0)
        /// How often the font panel was asked for.
        internal var fontPanels = 0
        /// The answers of the file panel, in order; without one the user cancels.
        internal var chosen: [URL] = []
        /// A clipboard of the test's own.
        internal let scratch = ScratchPasteboard()

        /// The effects that record into this.
        internal var effects: CompareWindowEffects {
            CompareWindowEffects(
                // Weakly: the presenter holds the window's controller, which holds these effects.
                present: { [weak presenter] in presenter?.present($0) },
                beep: { [beepCount] in beepCount.modify { $0 += 1 } },
                chooseFile: { [weak self] _, done in
                    done(self?.chosen.isEmpty == false ? self?.chosen.removeFirst() : nil)
                },
                showFontPanel: { [weak self] _ in self?.fontPanels += 1 },
                pasteboard: scratch.pasteboard
            )
        }

        deinit {
            // Nothing to release.
        }
    }

    /// What the window did outside itself. Declared first, so that it goes first: its presenter holds the window's
    /// controller, which must go before the kernel it belongs to.
    internal let recorder = Recorder()
    /// The files.
    internal let memory = MemoryFileSystem()
    /// The kernel with fake panels and jobs that run at once.
    internal let bench: TestBench
    /// The session the window draws.
    internal let session: CompareSession
    /// The window's controller; nil once closed.
    internal private(set) var controller: CompareWindowController?
    /// Whether the window told that it closed.
    internal private(set) var wasClosed = false
    /// The compare windows of this stage that come on screen or stay open.
    internal let windows = StabilityWindows { $0.title == "Compare contents (coverage)" }

    /// The window.
    internal var window: NSWindow? { controller?.window }

    /// The two path fields, left first.
    internal var pathFields: [NSTextField] {
        views(NSTextField.self).filter { $0.isEditable && !($0 is NSSearchField) && $0.superview is NSStackView }
    }

    /// The search field.
    internal var searchField: NSSearchField? { views(NSSearchField.self).first }

    /// The two panes, left first.
    internal var tables: [NSTableView] { views(NSTableView.self) }

    /// The status line.
    internal var status: String { views(NSTextField.self).last?.stringValue ?? "" }

    /// The rows selected in the left pane.
    internal var selectedRows: [Int] { tables.first.map { Array($0.selectedRowIndexes) } ?? [] }

    /// `/A/left.txt` and `/B/right.txt` with the given texts, compared, and the window shown (as far as a test
    /// shows it: never on screen).
    internal convenience init(left: String, right: String) {
        self.init(left: left, right: right, settings: MemorySettings())
    }

    /// The same with the settings `settings`.
    internal init(left: String, right: String, settings: MemorySettings) {
        memory.addFile("/A/left.txt", left)
        memory.addFile("/B/right.txt", right)
        bench = TestBench(
            plugins: [],
            fileSystems: [memory],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: settings
        )
        session = CompareSession(kernel: bench.kernel)
        session.runsInline = true
        session.leftURL = memory.url("/A/left.txt")
        session.rightURL = memory.url("/B/right.txt")
        let made = CompareWindowController(session: session, effects: recorder.effects) { [weak self] _ in
            self?.wasClosed = true
        }
        controller = made
        // A title of its own: other tests look for their compare windows by the usual one.
        made.window?.title = "Compare contents (coverage)"
        session.compare()
        made.show()
    }

    /// Asks the window to close, as its close button does (`performClose` would run the event loop for a moment).
    internal func askToClose() {
        guard let window, let controller else {
            return
        }
        if controller.windowShouldClose(window) { window.close() }
    }

    /// Closes the window and lets go of it.
    internal func close() {
        controller?.close()
        controller = nil
        recorder.presenter.closeAll()
        #expect(windows.shown.isEmpty && windows.open.isEmpty)
        windows.closeAll()
    }

    /// Every view of `type` in the window, in the order of the view tree.
    internal func views<View: NSView>(_: View.Type) -> [View] {
        func walk(_ view: NSView) -> [View] {
            ([view as? View].compactMap(\.self)) + view.subviews.flatMap(walk)
        }
        return window?.contentView.map(walk) ?? []
    }

    /// The button with this title.
    internal func button(_ title: String) -> NSButton? {
        views(NSButton.self).first { $0.title == title }
    }

    /// Clicks the button with this title: its action is sent. (`performClick` would run the event loop for a moment,
    /// which ends the run loop the test runner waits in.)
    internal func click(_ title: String) {
        guard let button = button(title), let action = button.action else {
            return
        }
        _ = button.target?.perform(action, with: button)
    }

    /// Ticks or clears the box with this title, as a click does, and sends its action.
    internal func toggle(_ title: String) {
        guard let box = button(title) else {
            return
        }
        box.state = box.state == .on ? .off : .on
        click(title)
    }

    /// A key press in the left pane: a named key by its key code, or a character.
    internal func press(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) {
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: window?.windowNumber ?? 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        else {
            return
        }
        tables[0].keyDown(with: event)
    }

    deinit {
        // `close()` has closed the window.
    }
}
