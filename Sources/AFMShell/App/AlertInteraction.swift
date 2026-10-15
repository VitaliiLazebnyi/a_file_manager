import AFMKernel
import AppKit

/// Asks the user with standard alerts.
///
/// Main thread only, like every `UserInteraction`.
internal final class AlertInteraction: UserInteraction {
    /// The interaction of the running program.
    internal init() {
        // Nothing to set up: every question builds its own alert.
    }

    /// The button Return presses when the question does not say.
    ///
    /// The last one for a critical question with a choice, the first one otherwise; nil when
    /// there is no button at all.
    internal static func defaultButton(for style: QuestionStyle, of buttons: [String]) -> Int? {
        guard !buttons.isEmpty else {
            return nil
        }
        return style == .critical && buttons.count > 1 ? buttons.count - 1 : 0
    }

    /// Presses the last button of `alert` for Esc (key code 53) in its window, and swallows the
    /// key; any other key goes on as it came.
    private static func pressLastButton(of alert: NSAlert?, for event: NSEvent) -> NSEvent? {
        guard event.keyCode == 53, let alert, event.window === alert.window else {
            return event
        }
        alert.buttons.last?.performClick(nil)
        return nil
    }

    /// Asks for a line of text, starting with `value`; nil when the user cancels.
    internal func prompt(_ message: String, value: String, detail: String) -> String? {
        let alert = alert(message, detail, .information)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 460, height: 24)
        field.lineBreakMode = .byTruncatingHead
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// Asks the user to pick one of `buttons`; returns its index.
    ///
    /// Return presses the first button, except in a critical question (one that destroys
    /// something for good, or trusts somebody): there it presses the last one, the one that
    /// changes nothing, so a reflexive Return never answers it with yes. Esc takes the last
    /// button in every question.
    internal func choose(_ message: String, detail: String, buttons: [String], style: QuestionStyle) -> Int {
        choose(
            message,
            detail: detail,
            buttons: buttons,
            style: style,
            defaultButton: Self.defaultButton(for: style, of: buttons)
        )
    }

    /// The same with the caller's say in which button Return presses.
    ///
    /// With nil Return presses none: the user has to click, or to press Esc for the last one.
    internal func choose(
        _ message: String,
        detail: String,
        buttons: [String],
        style: QuestionStyle,
        defaultButton: Int?
    ) -> Int {
        let alert = makeQuestion(message, detail: detail, buttons: buttons, style: style, defaultButton: defaultButton)
        // Esc on a last button that is also Return's: a button has one key of its own.
        var monitor: Any?
        if let last = alert.buttons.last, last.keyEquivalent != "\u{1b}" {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak alert] event in
                Self.pressLastButton(of: alert, for: event)
            }
        }
        defer { monitor.map(NSEvent.removeMonitor) }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    /// Builds a question without showing it.
    ///
    /// The keys are set here for every button, whatever the system would give them by their
    /// titles: Return for `defaultButton` and for no other, Esc for the last one (unless that is
    /// Return's already; `choose` sees to Esc then).
    internal func makeQuestion(
        _ message: String,
        detail: String,
        buttons: [String],
        style: QuestionStyle,
        defaultButton: Int?
    ) -> NSAlert {
        let alert = alert(message, detail, style)
        for title in buttons {
            alert.addButton(withTitle: DisplayText.clean(title))
        }
        let wanted = defaultButton.flatMap { alert.buttons.indices.contains($0) ? $0 : nil }
        for (index, button) in alert.buttons.enumerated() {
            if index == wanted {
                button.keyEquivalent = "\r"
            } else {
                button.keyEquivalent = index == alert.buttons.count - 1 ? "\u{1b}" : ""
            }
            button.keyEquivalentModifierMask = []
        }
        // Without a button for Return, none is drawn as the one Return would press, and the
        // keyboard starts on the last one (Space presses it), not on a destructive first.
        if wanted == nil {
            alert.window.initialFirstResponder = alert.buttons.last
        }
        return alert
    }

    /// Tells the user something and waits until it was read.
    internal func inform(_ message: String, detail: String, style: QuestionStyle) {
        alert(message, detail, style).runModal()
    }

    /// A message near the bottom of the main window that goes away by itself.
    ///
    /// Clicks go through it to what lies below.
    internal func notice(_ message: String) {
        Notice.show(message, over: NSApp.mainWindow ?? NSApp.keyWindow)
    }

    /// Shows a plugin's form; nil when the user cancels.
    internal func form(_ title: String, detail: String, fields: [FormField], buttons: [String]) -> FormValues? {
        FormDialog(fields: fields).run(title: title, detail: detail, buttons: buttons)
    }

    /// An alert with the message, the detail and the look of `style`, without buttons.
    private func alert(_ message: String, _ detail: String, _ style: QuestionStyle) -> NSAlert {
        let alert = NSAlert()
        // Messages name files; a name must not be able to write lines of its own into a
        // question, or to show its letters in another order than they have.
        alert.messageText = DisplayText.clean(message, keepingLines: true)
        alert.informativeText = DisplayText.clean(detail, keepingLines: true)
        switch style {
        case .information:
            alert.alertStyle = .informational

        case .warning:
            alert.alertStyle = .warning

        case .critical:
            alert.alertStyle = .critical
        }
        return alert
    }

    deinit {
        // Nothing to release.
    }
}
