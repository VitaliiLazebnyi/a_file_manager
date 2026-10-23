import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The progress window: a sheet on the main window, a window of its own in the background, its
/// buttons, and the texts it shows.
///
/// What would put it on the screen is recorded instead (`ProgressScreen`): the main window is
/// never shown, and the progress window never comes on the screen the tests run on.
@MainActor
@Suite(.serialized)
internal struct InteractionProgressWindowTests {
    /// What the display asked of the screen, in order.
    @MainActor
    private final class Screen {
        /// Whether the main window counts as on screen.
        var mainWindowIsShown = true
        /// The calls, as words: `sheet`, `end sheet`, `front`, `out`.
        private(set) var calls: [String] = []
        /// The panel that is up, as a sheet or by itself.
        private(set) var shown: NSPanel?
        /// The main window a sheet is on, or that keeps the keyboard.
        private(set) var mainWindow: NSWindow?

        /// The recording calls for a display.
        var calling: ProgressScreen {
            var screen = ProgressScreen()
            screen.isShown = { [weak self] _ in self?.mainWindowIsShown == true }
            screen.beginSheet = { [weak self] panel, window in self?.record("sheet", panel, window) }
            screen.endSheet = { [weak self] _, window in self?.record("end sheet", nil, window) }
            screen.orderFront = { [weak self] panel, window in self?.record("front", panel, window) }
            screen.orderOut = { [weak self] _ in self?.record("out", nil, nil) }
            return screen
        }

        /// Notes a call.
        private func record(_ call: String, _ panel: NSPanel?, _ window: NSWindow?) {
            calls.append(call)
            shown = panel
            mainWindow = window
        }

        deinit {
            // Nothing to release.
        }
    }

    /// Makes sure AppKit is there for the windows.
    internal init() {
        _ = NSApplication.shared
    }

    /// A service with a main window that is never shown, whose display reports to `screen`.
    private static func makeService(_ screen: Screen) -> (ProgressJobService, NSWindow) {
        let service = ProgressJobService()
        service.display.screen = screen.calling
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        service.window = window
        return (service, window)
    }

    /// The window comes as a sheet; its buttons pause, send it to the background and cancel the
    /// job; it goes when the queue is empty.
    @Test
    internal func theWindowsButtonsActOnTheJob() async throws {
        // Nothing comes on the screen, and nothing is left open.
        // Only the progress windows: other suites' windows are theirs to close.
        let windows = StabilityWindows { $0.contentView is ProgressContentView }
        defer {
            #expect(windows.shown.isEmpty && windows.open.isEmpty, "\(windows.shown) \(windows.openTitles)")
            windows.closeAll()
        }
        let screen = Screen()
        let (service, window) = Self.makeService(screen)
        let reporter = InteractionProgressTests.Reporter()
        defer {
            reporter.end()
            service.display.close()
        }
        var results: [String] = []
        service.run(title: "Copying", work: { reporter.work($0) }, completion: { results.append($0) })
        #expect(await AppWait.until { service.display.panel != nil })
        let panel = try #require(service.display.panel)
        #expect(screen.calls == ["sheet"] && screen.shown === panel && screen.mainWindow === window)
        let content = try #require(panel.contentView as? ProgressContentView)
        Controls.send(content.pauseButton)
        #expect(service.isPaused && content.pauseButton.title == "Resume")
        Controls.send(content.pauseButton)
        #expect(!service.isPaused)
        // A click on the count shows what is left.
        content.onCountClicked?()
        // Background: the sheet goes, a window of its own comes in the corner of the main window.
        Controls.send(content.backgroundButton)
        let own = try #require(service.display.panel)
        #expect(service.runsInBackground && own !== panel && own.title == "Copying")
        #expect(screen.calls == ["sheet", "end sheet", "front"] && screen.shown === own && screen.mainWindow === window)
        #expect(own.frame.maxX == window.frame.maxX - 24 && own.frame.minY == window.frame.minY + 48)
        #expect(own.styleMask.contains(.miniaturizable) && own.isFloatingPanel && !own.hidesOnDeactivate)
        Controls.send(content.cancelButton)
        #expect(await AppWait.until { results == ["cancelled"] })
        #expect(service.display.panel == nil && screen.calls.last == "out")
    }

    /// A window that is up for one job of a queue carries on with the next; between jobs it
    /// shows no title.
    @Test
    internal func theWindowCarriesOnWithTheNextJob() async {
        // Nothing comes on the screen, and nothing is left open.
        // Only the progress windows: other suites' windows are theirs to close.
        let windows = StabilityWindows { $0.contentView is ProgressContentView }
        defer {
            #expect(windows.shown.isEmpty && windows.open.isEmpty, "\(windows.shown) \(windows.openTitles)")
            windows.closeAll()
        }
        let screen = Screen()
        // The display holds the main window weakly: the test keeps it.
        let (service, window) = Self.makeService(screen)
        let first = InteractionProgressTests.Reporter()
        let second = InteractionProgressTests.Reporter()
        defer {
            first.end()
            second.end()
            service.display.close()
        }
        var results: [String] = []
        service.run(title: "First", work: { first.work($0) }, completion: { results.append($0) })
        service.run(title: "Second", work: { second.work($0) }, completion: { results.append($0) })
        #expect(await AppWait.until { service.display.panel != nil })
        let panel = service.display.panel
        first.end()
        #expect(await AppWait.until { second.count > 1 })
        #expect(service.display.panel === panel && results == ["finished"])
        service.display.refresh()
        second.end()
        #expect(await AppWait.until { results.count == 2 })
        #expect(screen.calls == ["sheet", "end sheet"] && screen.mainWindow === window)
    }

    /// Without the main window on screen nothing is shown; the window comes once the main
    /// window is back.
    @Test
    internal func theWindowWaitsForTheMainWindow() async {
        // Nothing is left open. (`shown` is not asked: a window that was never on screen reports
        // itself unoccluded when it is ordered out, or here when the test says it became key.)
        // Only the progress windows: other suites' windows are theirs to close.
        let windows = StabilityWindows { $0.contentView is ProgressContentView }
        defer {
            #expect(windows.open.isEmpty, "\(windows.openTitles)")
            windows.closeAll()
        }
        let screen = Screen()
        screen.mainWindowIsShown = false
        let (service, window) = Self.makeService(screen)
        let reporter = InteractionProgressTests.Reporter()
        defer {
            reporter.end()
            service.display.close()
        }
        service.run(title: "Hidden", work: { reporter.work($0) }, completion: { _ in () })
        #expect(await AppWait.until { reporter.count > 30 })
        #expect(service.display.panel == nil && screen.calls.isEmpty)
        screen.mainWindowIsShown = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(service.display.panel != nil && screen.calls == ["sheet"])
        // Shown already: asked again, nothing changes.
        let panel = service.display.panel
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        service.display.show()
        #expect(service.display.panel === panel && screen.calls == ["sheet"])
    }

    /// A display that serves no queue shows its job as a sheet and changes nothing on it; between
    /// two jobs it shows no title; the end of a job it does not show changes nothing.
    @Test
    internal func aDisplayWithoutAQueueAndBetweenJobs() throws {
        // Nothing comes on the screen, and nothing is left open.
        // Only the progress windows: other suites' windows are theirs to close.
        let windows = StabilityWindows { $0.contentView is ProgressContentView }
        defer {
            #expect(windows.shown.isEmpty && windows.open.isEmpty, "\(windows.shown) \(windows.openTitles)")
            windows.closeAll()
        }
        let screen = Screen()
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let display = ProgressDisplay()
        display.screen = screen.calling
        display.window = window
        let first = ProgressSheet(title: "First", cancellation: CancellationFlag())
        display.begin(first)
        display.show()
        let panel = try #require(display.panel)
        #expect(screen.calls == ["sheet"])
        // Between jobs, for a queue: no title, nothing cancelled.
        let service = ProgressJobService()
        display.service = service
        display.end(ProgressSheet(title: "Other", cancellation: CancellationFlag()), keepOpen: false)
        #expect(display.panel === panel)
        display.end(first, keepOpen: true)
        display.refresh()
        let content = try #require(panel.contentView as? ProgressContentView)
        #expect(display.panel === panel && content.cancelButton.isEnabled)
        display.close()
        #expect(screen.calls == ["sheet", "end sheet"] && display.panel == nil)
    }

    /// Without a job the window has nothing to change.
    @Test
    internal func withoutAJobTheWindowHasNothingToChange() {
        let display = ProgressDisplay()
        display.modeChanged()
        display.close()
        display.refresh()
        #expect(display.panel == nil)
    }

    /// Without a job the view shows empty lines, a full queue line and no bar.
    @Test
    internal func theViewOfNoJobIsEmpty() {
        let view = ProgressContentView()
        let state = ProgressContentView.State(
            title: "",
            progress: nil,
            speed: " ",
            showsRemaining: false,
            queue: "",
            isPaused: false,
            isCancelled: true,
            inBackground: true
        )
        var clicks = 0
        view.onCountClicked = { clicks += 1 }
        view.show(state)
        view.perform(NSSelectorFromString("countClicked"))
        #expect(clicks == 1 && !view.cancelButton.isEnabled && view.backgroundButton.title == "Foreground")
    }

    /// A job that stands still with nothing to measure in bytes has a blank speed line; a sample
    /// at the same time only raises the amount.
    @Test
    internal func aStillJobHasABlankSpeedLine() {
        var rate = TransferRate()
        rate.add(amount: 10, at: 0)
        rate.add(amount: 10, at: 3)
        rate.add(amount: 5, at: 3)
        #expect(rate.perSecond == 0)
        let deleting = JobProgress(lines: ["Deleting: a"], itemsDone: 10, itemsTotal: 40)
        #expect(ProgressSheet.speedLine(rate, for: deleting) == " ")
        rate.add(amount: 40, at: 3)
        #expect(rate.perSecond == 10)
    }
}
