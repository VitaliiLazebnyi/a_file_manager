import AppKit

/// A button that runs a closure.
internal final class ActionButton: NSButton {
    private var handler: (() -> Void)?

    /// A rounded push button titled `title` that runs `handler` when pressed.
    internal convenience init(_ title: String, _ handler: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.handler = handler
        target = self
        action = #selector(pressed)
        bezelStyle = .rounded
    }

    @objc
    private func pressed() { handler?() }
}
