import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The small window shown while the plugins finish before the program quits.
///
/// Put on screen as a modal window only in a running application (the UI tests'); here its
/// answers and its parts are checked.
@MainActor
@Suite
internal struct InteractionQuitProgressTests {
    /// Makes sure AppKit is there for the window.
    internal init() {
        _ = NSApplication.shared
    }

    /// Every view inside `view`, depth first.
    private static func views(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(views(in:))
    }

    /// Quit Now is answered once and says so; Don't Quit as often as pressed, until the window is closed.
    @Test
    internal func theAnswersAreGivenUntilTheWindowIsClosed() {
        let progress = QuitProgress()
        var answers: [String] = []
        progress.onQuitNow = { answers.append("quit") }
        progress.onDontQuit = { answers.append("stay") }
        progress.pressQuitNow()
        progress.pressQuitNow()
        progress.pressDontQuit()
        #expect(answers == ["quit", "stay"] && progress.isStopping)
        #expect(progress.heading.stringValue == QuitProgress.stoppingText)
        progress.close()
        progress.pressDontQuit()
        let late = QuitProgress()
        late.close()
        late.pressQuitNow()
        #expect(answers == ["quit", "stay"] && !late.isStopping)
    }

    /// The window's buttons give the answers; Return keeps the program.
    @Test
    internal func theButtonsGiveTheAnswers() throws {
        let progress = QuitProgress()
        var answers: [String] = []
        progress.onQuitNow = { answers.append("quit") }
        progress.onDontQuit = { answers.append("stay") }
        let panel = progress.makePanel()
        defer { panel.close() }
        let buttons = Self.views(in: try #require(panel.contentView)).compactMap { $0 as? NSButton }
        let stay = try #require(buttons.first { $0.title == "Don’t Quit" })
        #expect(stay.keyEquivalent == "\r")
        stay.performClick(nil)
        try #require(buttons.first { $0.title == "Quit Now" }).performClick(nil)
        #expect(answers == ["stay", "quit"])
    }

    /// Without a running application the window is due but not shown; once closed it does not
    /// come, and it is due only once.
    @Test
    internal func withoutARunningApplicationNothingIsShown() async {
        let progress = QuitProgress()
        progress.show(after: 0.01)
        progress.show(after: 0.01)
        #expect(await AppWait.until { progress.isDue })
        progress.close()
        progress.show(after: 0)
        #expect(progress.isClosed)
    }
}
