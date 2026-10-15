import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// The keys of a Lister pane as the application delivers them, and who has the keyboard. The
/// windows are never put on screen.
@MainActor
@Suite(.serialized)
internal struct CovViewPaneKeyboardTests {
    private static func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private static func pane(_ bench: CoverageViewerPaneBench, embedded: Bool) -> ViewerPane {
        let pane = ViewerPane(
            kernel: bench.setup.bench.kernel,
            settings: bench.settings,
            temporaryCopies: TemporaryCopies(),
            isEmbedded: embedded
        )
        bench.prepare(pane)
        return pane
    }

    private static func key(_ characters: String, _ code: UInt16, in window: NSWindow) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: code
            )
        )
    }

    /// A key the application delivers to the pane's window reaches the pane once, through its
    /// key monitor; a key the pane does not handle changes nothing.
    @Test
    internal func keysOfTheWindowReachThePane() throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let window = Self.window()
        defer { window.close() }
        let pane = Self.pane(bench, embedded: false)
        var closes = 0
        pane.onClose = { closes += 1 }
        window.contentView = pane
        defer { window.contentView = nil }
        NSApp.sendEvent(try Self.key("\u{1B}", 53, in: window))
        #expect(closes == 1)
        NSApp.sendEvent(try Self.key("x", 7, in: window))
        #expect(closes == 1)
    }

    /// The pane takes the keyboard; it gives it to its text when it shows one, else keeps it.
    @Test
    internal func thePaneTakesTheKeyboard() throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let window = Self.window()
        defer { window.close() }
        let pane = Self.pane(bench, embedded: false)
        window.contentView = pane
        defer { window.contentView = nil }
        #expect(pane.acceptsFirstResponder)
        pane.showMessage("Nothing to read")
        pane.takeKeyboard()
        #expect(window.firstResponder === pane && pane.hasKeyboard)
    }

    /// The quick view takes the keys of its window only while it has the keyboard.
    @Test
    internal func theQuickViewTakesKeysOnlyWithTheKeyboard() throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let window = Self.window()
        defer { window.close() }
        let pane = Self.pane(bench, embedded: true)
        let list = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let content = NSView()
        content.addSubview(pane)
        content.addSubview(list)
        window.contentView = content
        defer { window.contentView = nil }
        let flag = CancellationFlag()
        pane.activity = ("Working", nil, flag)
        #expect(window.makeFirstResponder(nil) && !pane.hasKeyboard)
        let escape = try Self.key("\u{1B}", 53, in: window)
        #expect(pane.monitored(escape) === escape && !flag.isCancelled)
        #expect(window.makeFirstResponder(pane))
        #expect(pane.monitored(escape) == nil && flag.isCancelled)
    }

    /// A pane that goes away with its window lets go of its key monitor.
    @Test
    internal func aPaneThatGoesWithItsWindowIsFreed() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        weak var gone: ViewerPane?
        weak var goneWindow: NSWindow?
        autoreleasepool {
            let window = Self.window()
            let pane = Self.pane(bench, embedded: false)
            window.contentView = pane
            gone = pane
            goneWindow = window
            // Closed with the pane still in it: the window takes the pane along when it goes.
            window.close()
        }
        #expect(await bench.wait { gone == nil && goneWindow == nil })
        // Its monitor went with it: a key of the application reaches no pane that is gone.
        let other = Self.window()
        defer { other.close() }
        NSApp.sendEvent(try Self.key("x", 7, in: other))
    }
}
