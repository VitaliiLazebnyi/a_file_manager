import AFMKernel
import AppKit

/// The small window that is shown when quitting takes a while because plugins are still
/// writing (changes inside archives, uploads): it says so and offers two ways out, to quit
/// without waiting and not to quit after all. What the two do is `Shell.finishToQuit`'s.
///
/// The window is run as a modal one, from the run loop: the program is on its way out, and
/// nothing else is to be started. Everything that reaches the main thread through the run
/// loop or the main queue still arrives (the plugins' completions, their questions). Without
/// a running application (tests) nothing is put on screen, and the two answers are given by
/// `pressQuitNow` and `pressDontQuit`. Main thread only.
final class QuitProgress: NSObject {
    static let waitingText = "Finishing before quitting…"
    static let waitingDetail = "Changes that have not been written yet are being written (into archives, to servers). "
        + "You can wait, quit without waiting, or go on working."
    static let stoppingText = "Quitting…"

    /// The user does not want to wait: called once.
    var onQuitNow: (() -> Void)?
    /// The user does not want to quit after all.
    var onDontQuit: (() -> Void)?
    /// The time after which the window is shown has passed.
    private(set) var isDue = false
    /// Quit Now was pressed; the plugins are giving up.
    private(set) var isStopping = false
    private(set) var isClosed = false
    private var cancelTimer: (() -> Void)?
    private var panel: NSPanel?
    private let heading = NSTextField(labelWithString: QuitProgress.waitingText)
    private let quitButton = NSButton(title: "Quit Now", target: nil, action: nil)
    private let stayButton = NSButton(title: "Don’t Quit", target: nil, action: nil)

    /// True while the window is on screen.
    var isShown: Bool { panel != nil }
    var text: String { heading.stringValue }

    /// Shows the window after `delay`, unless `close` comes first.
    func show(after delay: TimeInterval) {
        guard !isClosed, cancelTimer == nil else { return }
        cancelTimer = MainLoop.after(delay) { [weak self] in self?.present() }
    }

    /// Takes the window away, or keeps it from coming.
    func close() {
        isClosed = true
        cancelTimer?()
        cancelTimer = nil
        guard panel != nil else { return }
        // Ends the modal loop from wherever this is called: a button, or a block of the run
        // loop, which the loop does not look at by itself until an event wakes it.
        NSApp.stopModal()
        if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                         context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(wake, atStart: true)
        }
    }

    func pressQuitNow() {
        guard !isStopping, !isClosed else { return }
        isStopping = true
        heading.stringValue = QuitProgress.stoppingText
        quitButton.isEnabled = false
        onQuitNow?()
    }

    func pressDontQuit() {
        guard !isClosed else { return }
        onDontQuit?()
    }

    @objc private func quitPressed() { pressQuitNow() }
    @objc private func stayPressed() { pressDontQuit() }

    private func present() {
        cancelTimer = nil
        guard !isClosed else { return }
        isDue = true
        // Only a running application has a screen and a modal loop to show it in.
        guard panel == nil, NSApplication.shared.isRunning else { return }
        let panel = makePanel()
        self.panel = panel
        panel.center()
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        self.panel = nil
    }

    /// Builds the window without showing it.
    func makePanel() -> NSPanel {
        heading.font = .boldSystemFont(ofSize: 13)
        let detail = NSTextField(wrappingLabelWithString: QuitProgress.waitingDetail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        quitButton.target = self
        quitButton.action = #selector(quitPressed)
        stayButton.target = self
        stayButton.action = #selector(stayPressed)
        // Return keeps the program: quitting without waiting is clicked on purpose.
        stayButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, quitButton, stayButton])
        let stack = NSStackView(views: [heading, detail, bar, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: 440),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        return panel
    }
}
