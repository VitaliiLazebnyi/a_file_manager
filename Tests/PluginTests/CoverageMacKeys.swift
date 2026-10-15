import AppKit

/// A view that takes keys and notes them, so that no key goes on to the system (which beeps).
internal final class CoverageMacKeys: NSView {
    /// The characters of the keys that reached the view.
    internal private(set) var typed: [String] = []

    override internal var acceptsFirstResponder: Bool { true }

    /// Notes the key.
    override internal func keyDown(with event: NSEvent) {
        typed.append(event.characters ?? "")
    }

    deinit {
        // Nothing to release.
    }
}
