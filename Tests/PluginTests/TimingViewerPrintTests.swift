import AppKit
import Testing

@testable import ViewerPlugin

/// Printing a text from the Lister while the pane leaves its window: the print panel is a sheet
/// of the window the user printed from, taken when printing started. The text is prepared in the
/// background; the tests hold that step back by suspending the pane's work queue.
@MainActor
@Suite(.serialized)
internal struct TimingViewerPrintTests {
    private static let text = (1...200).map { "Line \($0) of the text\n" }.joined()

    /// A Lister window on a text file, with the text shown.
    private static func lister(_ bench: CoverageViewerPaneBench) async throws -> ViewerPane {
        let pane = try #require(await bench.open(try bench.file("notes.txt", text: Self.text)))
        #expect(await bench.textShown(pane))
        return pane
    }

    /// A window that is never put on screen.
    private static func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    /// A pane that is in no window has nothing to print from: nothing is prepared or printed.
    @Test
    internal func aPaneInNoWindowPrintsNothing() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let pane = try await Self.lister(bench)
        let window = try #require(pane.window)
        pane.removeFromSuperview()
        defer { window.contentView = pane }
        pane.printContent()
        #expect(pane.activity == nil && bench.dialogs.operations.isEmpty)
    }

    /// The pane leaves its window while the text is prepared: the print panel is still a sheet of
    /// the window printed from.
    @Test
    internal func aPaneThatLeftItsWindowPrintsForThatWindow() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let pane = try await Self.lister(bench)
        let window = try #require(pane.window)
        pane.workQueue.suspend()
        pane.printContent()
        #expect(pane.activity != nil)
        pane.removeFromSuperview()
        defer { window.contentView = pane }
        pane.workQueue.resume()
        #expect(await bench.wait { bench.dialogs.operations.count == 1 })
        #expect(bench.dialogs.operations.first?.window === window && pane.activity == nil)
        #expect(((bench.dialogs.operations.first?.operation.view as? TextPrintView)?.lines.count ?? 0) >= 200)
    }

    /// The window printed from goes away while the text is prepared, the pane staying: nothing is
    /// printed, and the pane stops saying that it prepares.
    @Test
    internal func whenTheWindowPrintedFromHasGoneNothingIsPrinted() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let pane = try await Self.lister(bench)
        let lister = try #require(pane.window)
        defer { lister.contentView = pane }
        weak var gone: NSWindow?
        pane.workQueue.suspend()
        autoreleasepool {
            let window = Self.window()
            window.contentView = pane
            gone = window
            pane.printContent()
            window.contentView = nil
            window.close()
        }
        #expect(pane.activity != nil)
        #expect(await bench.wait { gone == nil })
        pane.workQueue.resume()
        #expect(await bench.wait { pane.activity == nil })
        #expect(bench.dialogs.operations.isEmpty)
    }
}
