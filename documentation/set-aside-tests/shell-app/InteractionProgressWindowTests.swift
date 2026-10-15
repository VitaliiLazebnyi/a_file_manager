import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The progress window on screen: a sheet on the main window, a window of its own in the
/// background, its buttons, and the texts it shows.
@MainActor
@Suite(.serialized)
internal struct InteractionProgressWindowTests {
    /// Makes sure AppKit is there for the windows.
    internal init() {
        _ = NSApplication.shared
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            print("PROBE terminate", Thread.callStackSymbols.joined(separator: "\n"))
        }
        atexit { print("PROBE atexit") }
    }

    /// A main window on screen for the sheet, taken away again by `close`.
    private static func makeMainWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 700, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    /// The window comes as a sheet; its buttons pause, send it to the background and cancel the
    /// job; it goes when the queue is empty.
    @Test
    internal func theWindowsButtonsActOnTheJob() async throws {
        let window = Self.makeMainWindow()
        let service = ProgressJobService()
        let reporter = InteractionProgressTests.Reporter()
        defer {
            reporter.end()
            service.display.close()
            window.orderOut(nil)
        }
        service.window = window
        var results: [String] = []
        service.run(title: "Copying", work: { reporter.work($0) }, completion: { results.append($0) })
        #expect(await AppWait.until { service.display.panel != nil })
        let panel = try #require(service.display.panel)
        #expect(window.attachedSheet === panel)
        let content = try #require(panel.contentView as? ProgressContentView)
        content.pauseButton.performClick(nil)
        #expect(service.isPaused && content.pauseButton.title == "Resume")
        content.pauseButton.performClick(nil)
        #expect(!service.isPaused)
        // A click on the count shows what is left.
        content.onCountClicked?()
        content.backgroundButton.performClick(nil)
        let own = try #require(service.display.panel)
        #expect(service.runsInBackground && window.attachedSheet == nil && own.title == "Copying" && own.isVisible)
        content.cancelButton.performClick(nil)
        #expect(await AppWait.until { results == ["cancelled"] })
        #expect(service.display.panel == nil && !own.isVisible)
    }

    /// A window that is up for one job of a queue carries on with the next; between jobs it
    /// shows no title.
    @Test
    internal func theWindowCarriesOnWithTheNextJob() async throws {
        let window = Self.makeMainWindow()
        let service = ProgressJobService()
        let first = InteractionProgressTests.Reporter()
        let second = InteractionProgressTests.Reporter()
        defer {
            first.end()
            second.end()
            service.display.close()
            window.orderOut(nil)
        }
        service.window = window
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
    }

    /// Without the main window on screen nothing is shown; the window comes once the main
    /// window is back.
    @Test
    internal func theWindowWaitsForTheMainWindow() async {
        let window = Self.makeMainWindow()
        window.orderOut(nil)
        let service = ProgressJobService()
        let reporter = InteractionProgressTests.Reporter()
        defer {
            reporter.end()
            service.display.close()
            window.orderOut(nil)
        }
        service.window = window
        service.run(title: "Hidden", work: { reporter.work($0) }, completion: { _ in () })
        #expect(await AppWait.until { reporter.count > 30 })
        #expect(service.display.panel == nil)
        window.orderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(service.display.panel != nil)
        // Shown already: asked again, nothing changes.
        let panel = service.display.panel
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        service.display.show()
        #expect(service.display.panel === panel)
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
