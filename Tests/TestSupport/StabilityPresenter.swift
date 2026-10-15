public import AppKit

/// Stands in for putting windows on screen: a tool's `present` seam is given `present(_:)`,
/// which records the window controller and shows nothing. A presented window counts as open
/// until it closes (it is told to close as on screen, and says so). AppKit tells of one close
/// only while a window is not put on screen again: a window closed once and presented again
/// says nothing when it is closed a second time, so a test checks what that close did instead.
@preconcurrency
@MainActor
public final class StabilityPresenter {
    /// The controllers asked to show their windows, in order (one may come more than once).
    public private(set) var presented: [NSWindowController] = []
    /// The presented windows that closed since they were last presented.
    private var closed: Set<ObjectIdentifier> = []
    private var observer: (any NSObjectProtocol)?

    /// The presented windows that have not closed since, each once.
    public var open: [NSWindow] {
        var seen: Set<ObjectIdentifier> = []
        return presented.compactMap(\.window)
            .filter { window in
                let id = ObjectIdentifier(window)
                return !closed.contains(id) && seen.insert(id).inserted
            }
    }

    /// Starts recording.
    public init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else {
                return
            }
            MainActor.assumeIsolated { _ = self?.closed.insert(ObjectIdentifier(window)) }
        }
    }

    /// What the seam is given: records `controller` instead of showing its window.
    public func present(_ controller: NSWindowController) {
        presented.append(controller)
        if let window = controller.window { closed.remove(ObjectIdentifier(window)) }
    }

    /// Whether `window` was presented and has not closed since.
    public func isOpen(_ window: NSWindow?) -> Bool {
        open.contains { $0 === window }
    }

    /// Closes every presented window that is still open.
    public func closeAll() {
        for window in open { window.close() }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
