import AppKit

/// The target of a control in a test: counts what its action asked.
@MainActor
internal final class AppActionCounter: NSObject {
    /// Called for each action.
    private let onAction: () -> Void

    /// A target that calls `onAction` for each action.
    internal init(_ onAction: @escaping () -> Void) {
        self.onAction = onAction
    }

    /// The action of the control.
    @objc
    internal func run(_: Any?) {
        onAction()
    }

    deinit {
        // Nothing to release.
    }
}
