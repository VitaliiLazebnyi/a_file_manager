import AFMKernel
import AppKit

/// What the progress window shows.
///
/// The operation, the item being worked on, the bar, the counts, the speed, the length of the
/// queue and the buttons Pause, Cancel and Background. Main thread only.
internal final class ProgressContentView: NSView {
    /// Everything the view shows at one moment.
    internal struct State {
        /// The operation, as the plugin named its job.
        internal var title: String
        /// The job's last report; nil before the first.
        internal var progress: JobProgress?
        /// The speed and the time left, or why there is none.
        internal var speed: String
        /// The count shows what is left instead of what is done.
        internal var showsRemaining: Bool
        /// The jobs waiting behind this one, as a line; empty for none.
        internal var queue: String
        /// The job is held.
        internal var isPaused: Bool
        /// The job was told to stop.
        internal var isCancelled: Bool
        /// The view is in a window of its own, not in a sheet.
        internal var inBackground: Bool
    }

    /// Holds the job, or lets it go on.
    internal let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    /// Stops the job.
    internal let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    /// Turns the sheet into a window of its own, or back.
    internal let backgroundButton = NSButton(title: "Background", target: nil, action: nil)
    /// Called for a click on the count.
    internal var onCountClicked: (() -> Void)?
    /// The operation, in the sheet.
    private let heading = NSTextField(labelWithString: "")
    /// The two lines of the job's report (what it copies, and to where).
    private let lineLabels = [NSTextField(labelWithString: ""), NSTextField(labelWithString: "")]
    /// Items and data done, or left.
    private let countLabel = NSTextField(labelWithString: "")
    /// The share done, in percent.
    private let percentLabel = NSTextField(labelWithString: "")
    /// The speed and the time left.
    private let speedLabel = NSTextField(labelWithString: "")
    /// The jobs waiting.
    private let queueLabel = NSTextField(labelWithString: "")
    /// The share done, as a bar.
    private let bar = NSProgressIndicator()
    /// The width of the content, which differs between the sheet and the window.
    private var widthConstraint: NSLayoutConstraint?

    /// The view, arranged for a sheet.
    internal init() {
        super.init(frame: .zero)
        styleLabels()
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

    /// Not used: the view is made in code.
    @available(*, unavailable)
    internal required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    /// Arranges the view for the sheet or, with `compact`, for the window of its own.
    ///
    /// The window of its own is smaller than the sheet: its title bar names the operation, and
    /// Esc must not stop a job the user sent out of the way.
    internal func arrange(compact: Bool) {
        heading.isHidden = compact
        widthConstraint?.constant = compact ? 400 : 520
        cancelButton.keyEquivalent = compact ? "" : "\u{1b}"
        layoutSubtreeIfNeeded()
    }

    /// Shows `state`.
    internal func show(_ state: State) {
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

    /// The fonts, colours and behaviour of the labels and the bar.
    private func styleLabels() {
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
    }

    /// A click on the count.
    @objc
    private func countClicked() {
        onCountClicked?()
    }

    deinit {
        // Nothing to release.
    }
}
