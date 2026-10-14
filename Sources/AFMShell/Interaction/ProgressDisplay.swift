import AFMKernel
import AppKit

/// The progress window of the job service (spec 07 › Progress window): a sheet on the main
/// window, or, once the user pressed Background, a small window of its own that leaves the
/// main window free. One window serves the whole queue; it shows the running job and how many
/// are waiting. Main thread only.
final class ProgressDisplay {
    weak var window: NSWindow?
    weak var service: ProgressJobService?
    private var monitor: ProgressSheet?
    private var panel: NSPanel?
    private var panelIsSheet = false
    private let content = ProgressContentView()
    /// The count shows what is left instead of what is done (toggled by a click on it).
    private var showsRemaining = false
    private var observers: [NSObjectProtocol] = []

    init() {
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

    /// Whether the progress window is on screen, and in which form.
    var isShown: Bool { panel != nil }
    var isShownAsSheet: Bool { panel != nil && panelIsSheet }

    /// A job started. Short jobs finish before the window would appear; a window that is
    /// already there for the job before simply carries on.
    func begin(_ monitor: ProgressSheet) {
        self.monitor = monitor
        showsRemaining = false
        observeWindow()
        if panel != nil { return refresh() }
        MainLoop.after(0.4) { [weak self, weak monitor] in
            if let self, let monitor, self.monitor === monitor { self.show() }
        }
    }

    /// The window cannot be shown while the main window is minimised or the program is hidden;
    /// a job that is still running when that changes gets its window then.
    private func observeWindow() {
        guard observers.isEmpty, let window else { return }
        let center = NotificationCenter.default
        let retry: (Notification) -> Void = { [weak self] _ in
            guard let self, self.monitor != nil, self.panel == nil else { return }
            self.show()
        }
        observers = [
            center.addObserver(
                forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main, using: retry),
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main, using: retry),
            center.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main, using: retry)
        ]
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// A job ended. With `keepOpen` the window waits for the next job of the queue.
    func end(_ monitor: ProgressSheet, keepOpen: Bool) {
        guard self.monitor === monitor else { return }
        self.monitor = nil
        if !keepOpen { close() }
    }

    func close() {
        guard let panel else { return }
        if panelIsSheet { window?.endSheet(panel) } else { panel.orderOut(nil) }
        // The content is used again by the next window.
        panel.contentView = NSView()
        self.panel = nil
    }

    /// Puts the window on screen now. Nothing is shown while the main window is not.
    func show() {
        guard panel == nil, let monitor, let window, window.isVisible else { return }
        let inBackground = service?.runsInBackground ?? false
        let panel = NSPanel(
            contentRect: .zero, styleMask: inBackground ? [.titled, .miniaturizable] : [.titled],
            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        content.arrange(compact: inBackground)
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        self.panel = panel
        panelIsSheet = !inBackground
        refresh()
        if inBackground {
            panel.title = monitor.title
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            // In the lower right corner of the main window, where it covers the least.
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 24, y: frame.minY + 48))
            panel.orderFront(nil)
            window.makeKey()
        } else {
            window.beginSheet(panel)
        }
    }

    /// The user chose the other form: a window that is on screen changes at once.
    func modeChanged() {
        guard panel != nil else { return }
        close()
        show()
    }

    func render(_ monitor: ProgressSheet) {
        if monitor === self.monitor { refresh() }
    }

    /// Brings what the window shows up to date.
    func refresh() {
        guard panel != nil, let service else { return }
        let state = ProgressContentView.State(
            title: monitor?.title ?? "",
            progress: monitor?.latest,
            speed: service.isPaused
                ? "Paused"
                : monitor.flatMap { monitor in monitor.latest.map { ProgressSheet.speedLine(monitor.rate, for: $0) } }
                    ?? " ",
            showsRemaining: showsRemaining,
            queue: ProgressSheet.queueLine(service.queueLength),
            isPaused: service.isPaused,
            isCancelled: monitor?.cancellation.isCancelled ?? false,
            inBackground: !panelIsSheet)
        content.show(state)
        if !panelIsSheet, let title = monitor?.title { panel?.title = title }
    }

    @objc private func pausePressed() {
        guard let service else { return }
        service.setPaused(!service.isPaused)
    }

    @objc private func cancelPressed() {
        service?.cancelCurrent()
    }

    @objc private func backgroundPressed() {
        guard let service else { return }
        service.setRunsInBackground(!service.runsInBackground)
    }
}

/// What the progress window shows: the operation, the item being worked on, the bar, the
/// counts, the speed, the length of the queue and the buttons Pause, Cancel and Background.
final class ProgressContentView: NSView {
    struct State {
        var title: String
        var progress: JobProgress?
        var speed: String
        var showsRemaining: Bool
        var queue: String
        var isPaused: Bool
        var isCancelled: Bool
        var inBackground: Bool
    }

    let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let backgroundButton = NSButton(title: "Background", target: nil, action: nil)
    var onCountClicked: (() -> Void)?

    private let heading = NSTextField(labelWithString: "")
    private let lineLabels = [NSTextField(labelWithString: ""), NSTextField(labelWithString: "")]
    private let countLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "")
    private let speedLabel = NSTextField(labelWithString: "")
    private let queueLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private var widthConstraint: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        heading.font = .boldSystemFont(ofSize: 13)
        for label in lineLabels {
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for label in [countLabel, percentLabel, speedLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }
        percentLabel.alignment = .right
        speedLabel.textColor = .secondaryLabelColor
        queueLabel.textColor = .secondaryLabelColor
        queueLabel.font = .systemFont(ofSize: 11)
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        countLabel.toolTip = "Click to show what is left"
        countLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(countClicked)))

        let barRow = NSStackView(views: [bar, percentLabel])
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [countLabel, spacer, pauseButton, cancelButton, backgroundButton])
        let stack = NSStackView(views: [heading] + lineLabels + [barRow, speedLabel, queueLabel, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let width = stack.widthAnchor.constraint(equalToConstant: 520)
        widthConstraint = width
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            width,
            barRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            percentLabel.widthAnchor.constraint(equalToConstant: 44)
        ])
        for label in lineLabels {
            label.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The window of its own is smaller than the sheet: its title bar names the operation, and
    /// Esc must not stop a job the user sent out of the way.
    func arrange(compact: Bool) {
        heading.isHidden = compact
        widthConstraint?.constant = compact ? 400 : 520
        cancelButton.keyEquivalent = compact ? "" : "\u{1b}"
        layoutSubtreeIfNeeded()
    }

    func show(_ state: State) {
        heading.stringValue = state.title
        let lines = state.progress?.lines ?? []
        for (index, label) in lineLabels.enumerated() {
            // Names of files, whatever they hold, stay on their line.
            label.stringValue = lines.indices.contains(index) ? DisplayText.clean(lines[index]) : ""
            // A shortened name is shown in full when the mouse rests on it.
            label.toolTip = label.stringValue.isEmpty ? nil : label.stringValue
        }
        countLabel.stringValue =
            state.progress.map { ProgressSheet.countLine(for: $0, remaining: state.showsRemaining) } ?? ""
        percentLabel.stringValue = state.progress.map { "\(Int(($0.fraction * 100).rounded(.down))) %" } ?? ""
        bar.doubleValue = state.progress?.fraction ?? 0
        speedLabel.stringValue = state.isCancelled ? "Stopping…" : state.speed
        // The line keeps its place while empty, so the window does not change its height.
        queueLabel.stringValue = state.queue.isEmpty ? " " : state.queue
        pauseButton.title = state.isPaused ? "Resume" : "Pause"
        pauseButton.isEnabled = !state.isCancelled
        cancelButton.isEnabled = !state.isCancelled
        backgroundButton.title = state.inBackground ? "Foreground" : "Background"
    }

    @objc private func countClicked() {
        onCountClicked?()
    }
}
