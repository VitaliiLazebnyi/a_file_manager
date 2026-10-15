import AFMKernel
import AppKit

/// The progress window of the job service (spec 07 › Progress window).
///
/// A sheet on the main window, or, once the user pressed Background, a small window of its own
/// that leaves the main window free. One window serves the whole queue; it shows the running
/// job and how many are waiting. Main thread only.
@MainActor
internal final class ProgressDisplay {
    /// The main window, which the sheet covers.
    internal weak var window: NSWindow?
    /// The service whose jobs are shown, and which the buttons act on.
    internal weak var service: ProgressJobService?
    /// The progress window while it is on screen.
    internal private(set) var panel: NSPanel?
    /// The progress of the running job; nil between jobs.
    private var monitor: ProgressSheet?
    /// True while the window is a sheet, false while it is a window of its own.
    private var panelIsSheet = false
    /// What the window shows; used again by every window.
    private let content = ProgressContentView()
    /// The count shows what is left instead of what is done (toggled by a click on it).
    private var showsRemaining = false
    /// What brings the window back once the main window can show it; filled and read on the
    /// main thread, emptied in `deinit`, when nothing else holds the display.
    nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

    /// A display without a window yet.
    internal init() {
        content.pauseButton.target = self
        content.pauseButton.action = #selector(pausePressed)
        content.cancelButton.target = self
        content.cancelButton.action = #selector(cancelPressed)
        content.backgroundButton.target = self
        content.backgroundButton.action = #selector(backgroundPressed)
        content.onCountClicked = { [weak self] in
            self?.showsRemaining.toggle()
            self?.refresh()
        }
    }

    /// A job started.
    ///
    /// Short jobs finish before the window would appear; a window that is already there for the
    /// job before simply carries on.
    internal func begin(_ monitor: ProgressSheet) {
        self.monitor = monitor
        showsRemaining = false
        observeWindow()
        if panel != nil {
            refresh()
            return
        }
        MainLoop.after(0.4) { [weak self, weak monitor] in
            if let self, let monitor, self.monitor === monitor {
                show()
            }
        }
    }

    /// A job ended.
    ///
    /// With `keepOpen` the window waits for the next job of the queue.
    internal func end(_ monitor: ProgressSheet, keepOpen: Bool) {
        guard self.monitor === monitor else {
            return
        }
        self.monitor = nil
        if !keepOpen {
            close()
        }
    }

    /// Takes the window away.
    internal func close() {
        guard let panel else {
            return
        }
        if panelIsSheet {
            window?.endSheet(panel)
        } else {
            panel.orderOut(nil)
        }
        // The content is used again by the next window.
        panel.contentView = NSView()
        self.panel = nil
    }

    /// Puts the window on screen now.
    ///
    /// Nothing is shown while the main window is not.
    internal func show() {
        guard panel == nil, let monitor, let window, window.isVisible else {
            return
        }
        let inBackground = service?.runsInBackground ?? false
        let shown = NSPanel(
            contentRect: .zero,
            styleMask: inBackground ? [.titled, .miniaturizable] : [.titled],
            backing: .buffered,
            defer: false
        )
        shown.isReleasedWhenClosed = false
        content.arrange(compact: inBackground)
        shown.contentView = content
        shown.setContentSize(content.fittingSize)
        panel = shown
        panelIsSheet = !inBackground
        refresh()
        guard inBackground else {
            window.beginSheet(shown)
            return
        }
        shown.title = monitor.title
        shown.isFloatingPanel = true
        shown.hidesOnDeactivate = false
        shown.becomesKeyOnlyIfNeeded = true
        // In the lower right corner of the main window, where it covers the least.
        let frame = window.frame
        shown.setFrameOrigin(NSPoint(x: frame.maxX - shown.frame.width - 24, y: frame.minY + 48))
        shown.orderFront(nil)
        window.makeKey()
    }

    /// The user chose the other form: a window that is on screen changes at once.
    internal func modeChanged() {
        guard panel != nil else {
            return
        }
        close()
        show()
    }

    /// The job of `monitor` reported; the window follows if the job is the one shown.
    internal func render(_ monitor: ProgressSheet) {
        if monitor === self.monitor {
            refresh()
        }
    }

    /// Brings what the window shows up to date.
    internal func refresh() {
        guard panel != nil, let service else {
            return
        }
        let progress = monitor?.latest
        var speed = " "
        if service.isPaused {
            speed = "Paused"
        } else if let monitor, let progress {
            speed = ProgressSheet.speedLine(monitor.rate, for: progress)
        }
        let state = ProgressContentView.State(
            title: monitor?.title ?? "",
            progress: progress,
            speed: speed,
            showsRemaining: showsRemaining,
            queue: ProgressSheet.queueLine(service.queueLength),
            isPaused: service.isPaused,
            isCancelled: monitor?.cancellation.isCancelled ?? false,
            inBackground: !panelIsSheet
        )
        content.show(state)
        if !panelIsSheet, let title = monitor?.title {
            panel?.title = title
        }
    }

    /// The window cannot be shown while the main window is minimised or the program is hidden;
    /// a job that is still running when that changes gets its window then.
    private func observeWindow() {
        guard observers.isEmpty, let window else {
            return
        }
        let center = NotificationCenter.default
        // Delivered on the main queue.
        let retry: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.showIfMissing() }
        }
        observers = [
            center.addObserver(
                forName: NSWindow.didDeminiaturizeNotification,
                object: window,
                queue: .main,
                using: retry
            ),
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main, using: retry),
            center.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main, using: retry)
        ]
    }

    /// Shows the window of a running job that has none.
    private func showIfMissing() {
        if monitor != nil, panel == nil {
            show()
        }
    }

    /// The Pause and Resume button.
    @objc
    private func pausePressed() {
        if let service {
            service.setPaused(!service.isPaused)
        }
    }

    /// The Cancel button.
    @objc
    private func cancelPressed() {
        service?.cancelCurrent()
    }

    /// The Background and Foreground button.
    @objc
    private func backgroundPressed() {
        if let service {
            service.setRunsInBackground(!service.runsInBackground)
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
