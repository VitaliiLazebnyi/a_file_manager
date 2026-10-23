import AFMContracts
import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// The Lister's keys: moving through text, the keys of images and of the player, Esc and Tab,
/// and a pane that is not in a Lister window.
@MainActor
@Suite(.serialized)
internal struct CoverageViewerPaneKeyTests {
    private enum Code {
        static let leftArrow: UInt16 = 123, rightArrow: UInt16 = 124, downArrow: UInt16 = 125, upArrow: UInt16 = 126
        static let pageUp: UInt16 = 116, pageDown: UInt16 = 121, home: UInt16 = 115, end: UInt16 = 119
        static let escape: UInt16 = 53, tab: UInt16 = 48, space: UInt16 = 49
    }

    private static let text = (1...80).map { "Line \($0) of the text, with words\n" }.joined()

    private static func press(
        _ pane: ViewerPane,
        _ bench: CoverageViewerPaneBench,
        _ code: UInt16,
        _ flags: NSEvent.ModifierFlags = [],
        characters: String = ""
    ) throws -> Bool {
        pane.handleKey(try #require(bench.key(characters, code: code, flags: flags)))
    }

    /// Lets the main queue run what a key handed to it (one turn: in a full run every turn waits behind the other
    /// tests, and five of them after each of fourteen keys made this the slowest test of the bundle).
    private static func afterWhatTheKeyHandedOn() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { done.resume() }
        }
    }

    /// A window that can say a sheet is open, not released when closed, holding a new pane that shows
    /// the text; the caller closes the window.
    private static func paneInWindow(
        _ bench: CoverageViewerPaneBench
    ) async throws -> (CovViewSheetWindow, ViewerPane) {
        let window = CovViewSheetWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let pane = ViewerPane(
            kernel: bench.setup.bench.kernel,
            settings: bench.settings,
            temporaryCopies: TemporaryCopies(),
            isEmbedded: false
        )
        bench.prepare(pane)
        window.contentView = pane
        pane.load(ViewerItem(source: .file(try bench.file("notes.txt", text: Self.text)), title: "notes"))
        #expect(await bench.textShown(pane))
        return (window, pane)
    }

    /// A key down of `characters` with the key code `code` in `target`.
    private static func key(_ characters: String, _ code: UInt16, in target: NSWindow) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: target.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: code
            )
        )
    }

    /// The cursor keys, alone and with Shift, Control, Option and Command, move through the text.
    @Test
    internal func theCursorKeysMoveThroughTheText() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let pane = try #require(await bench.open(try bench.file("notes.txt", text: Self.text)))
        #expect(await bench.textShown(pane))
        let pager = pane.pager
        func offset() -> Int64 { pager.position?.offset ?? -1 }
        let steps: [(code: UInt16, flags: NSEvent.ModifierFlags)] = [
            (Code.downArrow, []), (Code.rightArrow, [.control]), (Code.rightArrow, [.command]),
            (Code.leftArrow, [.option]), (Code.leftArrow, [.command]), (Code.rightArrow, []), (Code.leftArrow, []),
            (Code.pageDown, []), (Code.pageUp, []), (Code.space, []), (Code.home, []),
            (Code.end, []), (Code.upArrow, []), (Code.rightArrow, [.shift])
        ]
        for (code, flags) in steps {
            // Space is the one key here that types a character.
            let characters = code == Code.space ? " " : ""
            #expect(try Self.press(pane, bench, code, flags, characters: characters))
            await Self.afterWhatTheKeyHandedOn()
        }
        #expect(await bench.wait { pager.selection != nil })
        #expect(try Self.press(pane, bench, Code.downArrow, [.command]))
        #expect(await bench.wait { (pager.position?.line ?? 0) >= 80 })
        #expect(try Self.press(pane, bench, Code.upArrow, [.command]))
        #expect(await bench.wait { offset() == 0 })
        #expect(try Self.press(pane, bench, Code.pageDown, [.control]))
        #expect(try Self.press(pane, bench, Code.pageUp, [.control]))
        #expect(try Self.press(pane, bench, Code.end, [.command]))
        #expect(try Self.press(pane, bench, Code.home, [.control]))
        #expect(await bench.wait { offset() == 0 })
        // A key that means nothing here is left alone.
        #expect(try !Self.press(pane, bench, 7, characters: "x"))
    }

    /// The arrows scroll an image; other keys are left alone.
    @Test
    internal func theArrowsScrollAnImage() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let png = try CoverageViewerImages.encoded([CoverageViewerImages.picture(3_000, 3_000)], type: "public.png")
        let pane = try #require(await bench.open(try bench.file("big.png", png)))
        #expect(await bench.wait { pane.imageView != nil })
        let presses: [(UInt16, NSEvent.ModifierFlags)] = [
            (Code.rightArrow, []), (Code.leftArrow, .shift), (Code.downArrow, []), (Code.upArrow, [])
        ]
        for (code, flags) in presses {
            #expect(try Self.press(pane, bench, code, flags))
        }
        #expect(try !Self.press(pane, bench, Code.pageDown))
    }

    /// Space, M, E and the arrows control the player.
    @Test
    internal func theKeysOfThePlayer() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        bench.settings.playerVolume = 0
        let sound = try bench.file("tone.wav", CoverageViewerMediaFiles.wav(seconds: 1))
        let pane = try #require(await bench.open(sound))
        #expect(await bench.wait { pane.mediaView != nil })
        let player = try #require(pane.mediaView)
        // Muted first: nothing is heard whatever the volume.
        #expect(try Self.press(pane, bench, 46, characters: "m"))
        #expect(try Self.press(pane, bench, Code.upArrow))
        #expect(abs(player.volume - 0.01) < 0.001 && abs(bench.settings.playerVolume - 0.01) < 0.001)
        #expect(try Self.press(pane, bench, Code.upArrow, [.shift]))
        #expect(try Self.press(pane, bench, Code.downArrow))
        #expect(try Self.press(pane, bench, Code.space, characters: " "))
        #expect(try Self.press(pane, bench, 14, characters: "e"))
        #expect(try Self.press(pane, bench, Code.rightArrow, [.shift]))
        #expect(try Self.press(pane, bench, Code.leftArrow, [.shift]))
        #expect(try !Self.press(pane, bench, Code.leftArrow))
        #expect(try !Self.press(pane, bench, Code.pageDown))
        // F fits the film to the window or fills it.
        #expect(try Self.press(pane, bench, 3, characters: "f"))
    }

    /// Esc stops what runs, then closes the window; in the quick view it is left to the panel,
    /// and Tab gives the keyboard back to the file list.
    @Test
    internal func escapeAndTab() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let pane = try #require(await bench.open(try bench.file("notes.txt", text: Self.text)))
        let flag = CancellationFlag()
        pane.activity = ViewerPane.Activity(text: "Working", progress: nil, cancel: flag)
        #expect(try Self.press(pane, bench, Code.escape))
        #expect(flag.isCancelled)
        pane.activity = nil
        #expect(try Self.press(pane, bench, Code.escape))
        #expect(await bench.wait { bench.setup.plugin.windows.isEmpty })
        bench.setup.bench.left.moveCursor(toName: "notes.txt")
        #expect(bench.setup.commands.perform(.quickView))
        let quick = try #require(bench.setup.plugin.quickView)
        #expect(try !Self.press(quick.pane, bench, Code.escape))
        #expect(try Self.press(quick.pane, bench, Code.tab))
        // Without the keyboard the quick view lets the keys pass.
        let passing = try #require(bench.key("w", code: 13, flags: []))
        #expect(quick.pane.monitored(passing) === passing)
    }

    /// A pane outside a Lister window: its keys and entries for the window do nothing; the
    /// keyboard can be given to it; the wheel and the context menu of its text are the pane's.
    @Test
    internal func aPaneOutsideAListerWindow() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let (window, pane) = try await Self.paneInWindow(bench)
        defer { window.close() }
        pane.fileCounter = (0, 2)
        #expect(try Self.press(pane, bench, 45, characters: "n"))
        #expect(try Self.press(pane, bench, 12, characters: "q"))
        #expect(CoverageViewerMenus.run("Configure", in: "Options", of: pane))
        #expect(CoverageViewerMenus.run("Save position", in: "Options", of: pane))
        pane.takeKeyboard()
        #expect(window.firstResponder === pane.pager && pane.hasKeyboard)
        // The wheel with Control on the text changes the font; its context menu is the pane's.
        pane.pager.scrollWheel(with: try CoverageViewerEvents.scroll(lines: 2, flags: .maskControl))
        #expect(pane.fontSizeChange == 2)
        pane.pager.selectAll()
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        #expect(pane.pager.menu(for: event)?.items.first?.title == "Copy as text")
        window.contentView = nil
    }

    /// A key of the window goes to the pane first; keys of other windows, keys while a sheet is
    /// open, and keys for a field being edited pass.
    @Test
    internal func keysOfTheWindowGoToThePaneFirst() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let (window, pane) = try await Self.paneInWindow(bench)
        defer { window.close() }
        pane.takeKeyboard()
        let wrap = bench.settings.wrap
        #expect(pane.monitored(try Self.key("w", 13, in: window)) == nil)
        #expect(bench.settings.wrap != wrap)
        let unknown = try Self.key("x", 7, in: window)
        #expect(pane.monitored(unknown) === unknown)
        let elsewhere = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        elsewhere.isReleasedWhenClosed = false
        defer { elsewhere.close() }
        let foreign = try Self.key("w", 13, in: elsewhere)
        #expect(pane.monitored(foreign) === foreign)
        window.openSheet = elsewhere
        let sheeted = try Self.key("w", 13, in: window)
        #expect(pane.monitored(sheeted) === sheeted)
        window.openSheet = nil
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
        pane.addSubview(field)
        defer { field.removeFromSuperview() }
        #expect(window.makeFirstResponder(field))
        let typed = try Self.key("w", 13, in: window)
        #expect(pane.monitored(typed) === typed)
        window.contentView = nil
    }
}
