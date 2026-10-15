import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The progress window and the job service behind it: pausing, the background, the texts.
@MainActor
@Suite(.serialized)
internal struct InteractionProgressTests {
    /// A job that reports until it is told to end, and counts its reports.
    ///
    /// Unchecked: every stored property is read and written under `lock`.
    internal final class Reporter: @unchecked Sendable {
        /// Guards `reports` and `finished`.
        private let lock = NSLock()
        /// How many reports were made.
        private var reports = 0
        /// Set by `end`.
        private var finished = false

        /// How many reports were made; any thread.
        internal var count: Int { lock.withLock { reports } }

        /// Lets the job end at its next report; any thread.
        internal func end() {
            lock.withLock { finished = true }
        }

        /// The job's work: reports until it is ended or cancelled, and says which.
        internal func work(_ monitor: any JobMonitor) -> String {
            while !monitor.cancellation.isCancelled, !lock.withLock({ finished }) {
                monitor.report(JobProgress(lines: ["Working"], itemsDone: count, itemsTotal: 1_000_000))
                lock.withLock { reports += 1 }
                Thread.sleep(forTimeInterval: 0.001)
            }
            return monitor.cancellation.isCancelled ? "cancelled" : "finished"
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The window's folders and stand-ins.
    private let fixture: AppFixture
    /// The plugin that brings the test's buttons and commands.
    private let extra = WindowTestPlugin()

    /// A sandbox with the window's files.
    internal init() throws {
        fixture = try AppFixture(files: AppFixture.windowFiles)
    }

    /// A paused job stops at its next report and goes on when resumed; a paused job can be cancelled.
    @Test
    internal func aJobCanBePausedResumedAndCancelledWhilePaused() async {
        let app = await fixture.startWindow(with: extra)
        defer { app.stop() }
        let service = app.shell.jobService
        let reporter = Reporter()
        var result = ""
        service.run(title: "Long", work: { reporter.work($0) }, completion: { result = $0 })
        await AppWait.until { reporter.count > 5 }
        #expect(!service.isPaused)
        service.setPaused(true)
        #expect(service.isPaused && service.isBusy)
        // The job stops at its next report and stays there.
        try? await Task.sleep(nanoseconds: 150_000_000)
        let held = reporter.count
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(reporter.count == held && result.isEmpty)
        service.setPaused(false)
        let moved = await AppWait.until { reporter.count > held + 5 }
        #expect(moved && !service.isPaused)
        // Cancel reaches a paused job.
        service.setPaused(true)
        service.cancelCurrent()
        await app.settle()
        #expect(result == "cancelled" && !service.isPaused && !service.isBusy)
        // Without a job there is nothing to pause.
        service.setPaused(true)
        #expect(!service.isPaused)
    }

    /// Quitting cancels a paused job and the one waiting behind it.
    @Test
    internal func quittingStopsAPausedJob() async {
        let app = await fixture.startWindow(with: extra)
        defer { app.stop() }
        let service = app.shell.jobService
        let reporter = Reporter()
        var results: [String] = []
        service.run(title: "First", work: { reporter.work($0) }, completion: { results.append($0) })
        service.run(title: "Second", work: { reporter.work($0) }, completion: { results.append($0) })
        await AppWait.until { reporter.count > 2 }
        service.setPaused(true)
        var idle = false
        service.cancelAll { idle = true }
        let ended = await AppWait.until { idle }
        #expect(ended && results == ["cancelled", "cancelled"])
    }

    /// Jobs sent to the background free the window only for commands that may run beside them.
    @Test
    internal func theBackgroundKeepsCommandsThatChangeFilesBlocked() async {
        let app = await fixture.startWindow(with: extra)
        defer { app.stop() }
        let service = app.shell.jobService
        app.cursor(app.left, on: "one.txt")
        // Nothing runs: nothing to send to the background.
        service.setRunsInBackground(true)
        #expect(!service.runsInBackground && service.queueLength == 0)
        let first = Reporter()
        let second = Reporter()
        var results: [String] = []
        service.run(title: "First", work: { first.work($0) }, completion: { results.append($0) })
        service.run(title: "Second", work: { second.work($0) }, completion: { results.append($0) })
        service.run(title: "Third", work: { _ in "third" }, completion: { results.append($0) })
        #expect(service.queueLength == 2)
        service.setRunsInBackground(true)
        #expect(service.runsInBackground && service.isBusy)
        // The main window is free, but only for what may run beside a job.
        #expect(!app.commands.isEnabled(.copy) && !app.commands.isEnabled(.goToParent))
        #expect(
            app.commands.isEnabled(.cursorToLastEntry) && app.commands.isEnabled(.showCommandLine)
                && app.commands.isEnabled(.focusTarget)
        )
        // The window is not shown in a test; the queue goes on behind it all the same.
        #expect(service.display.panel == nil)
        first.end()
        await AppWait.until { second.count >= 1 }
        #expect(service.queueLength == 1 && service.runsInBackground && results == ["finished"])
        second.end()
        await app.settle()
        #expect(results == ["finished", "finished", "third"])
        // The next queue starts in the foreground again.
        #expect(!service.runsInBackground && service.queueLength == 0 && app.commands.isEnabled(.copy))
    }

    /// The count line shows done or remaining items and bytes; the queue line the jobs waiting.
    @Test
    internal func progressTexts() {
        let copying = JobProgress(
            lines: ["From: a", "To: b"],
            itemsDone: 7,
            itemsTotal: 14,
            bytesDone: 2 << 20,
            bytesTotal: 8 << 20
        )
        #expect(
            ProgressSheet.countLine(for: copying, remaining: false)
                == "7 / 14     \(Format.shortSize(2 << 20)) of \(Format.shortSize(8 << 20))"
        )
        #expect(
            ProgressSheet.countLine(for: copying, remaining: true)
                == "-7 / 14     -\(Format.shortSize(6 << 20)) of \(Format.shortSize(8 << 20))"
        )
        #expect(
            ProgressSheet.countLine(for: JobProgress(lines: [], itemsDone: 3, itemsTotal: 4), remaining: true)
                == "-1 / 4"
        )
        #expect(ProgressSheet.queueLine(0).isEmpty && ProgressSheet.queueLine(1) == "1 more job waiting")
        #expect(ProgressSheet.queueLine(3) == "3 more jobs waiting")
    }

    /// The window's buttons follow the job: Pause or Resume, Background or Foreground, Esc only in the sheet.
    @Test
    internal func theProgressWindowShowsStateAndOffersItsButtons() {
        let view = ProgressContentView()
        let progress = JobProgress(lines: ["From: a"], itemsDone: 1, itemsTotal: 4)
        var state = ProgressContentView.State(
            title: "Copy:",
            progress: progress,
            speed: "about 6 s left",
            showsRemaining: false,
            queue: "1 more job waiting",
            isPaused: false,
            isCancelled: false,
            inBackground: false
        )
        view.arrange(compact: false)
        view.show(state)
        #expect(
            view.pauseButton.title == "Pause" && view.backgroundButton.title == "Background"
                && view.cancelButton.keyEquivalent == "\u{1b}"
        )
        state.isPaused = true
        state.inBackground = true
        view.arrange(compact: true)
        view.show(state)
        // In its own window Esc no longer stops the job.
        #expect(
            view.pauseButton.title == "Resume" && view.backgroundButton.title == "Foreground"
                && view.cancelButton.keyEquivalent.isEmpty
        )
        state.isCancelled = true
        view.show(state)
        #expect(!view.pauseButton.isEnabled && !view.cancelButton.isEnabled)
    }

    /// The speed line says "Calculating…" at first, then the speed and the time left, or only the time.
    @Test
    internal func progressLine() {
        var rate = TransferRate()
        let copying = JobProgress(
            lines: ["From: a", "To: b"],
            itemsDone: 1,
            itemsTotal: 4,
            bytesDone: 20 << 20,
            bytesTotal: 100 << 20
        )
        #expect(ProgressSheet.speedLine(rate, for: copying) == "Calculating…")
        rate.add(amount: 0, at: 0)
        rate.add(amount: 20 << 20, at: 2)
        #expect(ProgressSheet.speedLine(rate, for: copying) == "10.00 M/s  ·  about 8 s left")
        // A job that moves no data is measured in items and shows only the time.
        var items = TransferRate()
        let deleting = JobProgress(lines: ["Deleting: a"], itemsDone: 10, itemsTotal: 40)
        items.add(amount: 0, at: 0)
        items.add(amount: 10, at: 2)
        #expect(ProgressSheet.speedLine(items, for: deleting) == "about 6 s left")
    }
}
