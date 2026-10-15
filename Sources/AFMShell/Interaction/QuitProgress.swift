import AFMKernel
import AppKit

/// The small window that is shown when quitting takes a while because plugins are still writing.
///
/// Changes inside archives, uploads: it says so and offers two ways out, to quit without
/// waiting and not to quit after all. What the two do is `Shell.finishToQuit`'s.
///
/// The window is run as a modal one, from the run loop: the program is on its way out, and
/// nothing else is to be started. Everything that reaches the main thread through the run
/// loop or the main queue still arrives (the plugins' completions, their questions). Without
/// a running application (tests) nothing is put on screen, and the two answers are given by
/// `pressQuitNow` and `pressDontQuit`. Main thread only.
@MainActor
internal final class QuitProgress: NSObject {
    /// The first line while the plugins are being waited for.
    internal static let waitingText = "Finishing before quitting…"
    /// What the window explains below it.
    internal static let waitingDetail =
        "Changes that have not been written yet are being written (into archives, to servers). "
        + "You can wait, quit without waiting, or go on working."
    /// The first line once the user chose not to wait.
    internal static let stoppingText = "Quitting…"

    /// The first line of the window: what the program is doing.
    internal let heading = NSTextField(labelWithString: QuitProgress.waitingText)
    /// The user does not want to wait: called once.
    internal var onQuitNow: (() -> Void)?
    /// The user does not want to quit after all.
    internal var onDontQuit: (() -> Void)?
    /// The time after which the window is shown has passed.
    internal private(set) var isDue = false
    /// Quit Now was pressed; the plugins are giving up.
    internal private(set) var isStopping = false
    /// The window was taken away, or kept from coming, for good.
    internal private(set) var isClosed = false
    /// Calls off the timer that shows the window.
    private var cancelTimer: (() -> Void)?
    /// The window while it is on screen.
    private var panel: NSPanel?
    /// Quits without waiting.
    private let quitButton = NSButton(title: "Quit Now", target: nil, action: nil)
    /// Calls the quit off.
    private let stayButton = NSButton(title: "Don’t Quit", target: nil, action: nil)

    /// Shows the window after `delay`, unless `close` comes first.
    internal func show(after delay: TimeInterval) {
        guard !isClosed, cancelTimer == nil else {
            return
        }
        cancelTimer = MainLoop.after(delay) { [weak self] in self?.present() }
    }

    /// Takes the window away, or keeps it from coming.
    internal func close() {
        isClosed = true
        // The answers hold what holds this window.
        onQuitNow = nil
        onDontQuit = nil
        cancelTimer?()
        cancelTimer = nil
        guard panel != nil else {
            return
        }
        // Ends the modal loop from wherever this is called: a button, or a block of the run
        // loop, which the loop does not look at by itself until an event wakes it.
        NSApp.stopModal()
        let wake = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        )
        wake.map { NSApp.postEvent($0, atStart: true) }
    }

    /// The user chose not to wait: the plugins are told to give up (`onQuitNow`), once.
    internal func pressQuitNow() {
        guard !isStopping, !isClosed else {
            return
        }
        isStopping = true
        heading.stringValue = Self.stoppingText
        quitButton.isEnabled = false
        onQuitNow?()
    }

    /// The user chose not to quit after all (`onDontQuit`).
    internal func pressDontQuit() {
        guard !isClosed else {
            return
        }
        onDontQuit?()
    }

    /// Builds the window without showing it.
    internal func makePanel() -> NSPanel {
        heading.font = .boldSystemFont(ofSize: 13)
        let detail = NSTextField(wrappingLabelWithString: Self.waitingDetail)
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
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: 440),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32)
        ])
        let window = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.setContentSize(content.fittingSize)
        return window
    }

    /// The Quit Now button.
    @objc
    private func quitPressed() {
        pressQuitNow()
    }

    /// The Don't Quit button.
    @objc
    private func stayPressed() {
        pressDontQuit()
    }

    /// The time is up: the window is shown and run as a modal one until `close`.
    private func present() {
        // `close` calls the timer off: the window is not closed yet.
        cancelTimer = nil
        isDue = true
        // Only a running application has a screen and a modal loop to show it in.
        guard panel == nil, NSApplication.shared.isRunning else {
            return
        }
        let window = makePanel()
        panel = window
        window.center()
        NSApp.runModal(for: window)
        window.orderOut(nil)
        panel = nil
    }
}
