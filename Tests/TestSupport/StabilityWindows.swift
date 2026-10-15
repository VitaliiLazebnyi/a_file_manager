public import AppKit

/// Watches the windows of the test process from the moment it is made: which of the windows
/// opened since then came on screen, and which are still open. Tests run in the session the
/// owner watches, so a test must never show a window and must close every window it opens.
///
/// A suite makes one in its `init`, naming the windows of its subject (the tests of other suites
/// run at the same time and open windows of their own), and at the end of each test expects
/// `shown` and `open` to be empty; `closeAll()` in a `defer` leaves nothing behind when a test
/// fails either.
@preconcurrency
@MainActor
public final class StabilityWindows {
    /// The titles of the windows opened since that the window server reported on screen, or
    /// that became key or main (which only a window on screen does), in that order.
    public private(set) var shown: [String] = []
    /// The windows that were there before.
    private let earlier: Set<ObjectIdentifier>
    /// Whether a window is one of those watched.
    private let isWatched: (NSWindow) -> Bool
    private var observers: [any NSObjectProtocol] = []

    /// The windows opened since the watch began that are still open (ordered in, on screen or not).
    public var open: [NSWindow] {
        NSApplication.shared.windows.filter { isNew($0) && $0.isVisible }
    }

    /// The titles of `open`, for a message.
    public var openTitles: [String] { open.map(\.title) }

    /// Starts watching the windows `isWatched` says yes to; all of them by default.
    public init(_ isWatched: @escaping (NSWindow) -> Bool = { _ in true }) {
        self.isWatched = isWatched
        earlier = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let window = note.object as? NSWindow else {
                    return
                }
                MainActor.assumeIsolated { self?.saw(window, becoming: name) }
            }
        }
    }

    /// Closes every window opened since the watch began that is still open.
    public func closeAll() {
        for window in open { window.close() }
    }

    private func saw(_ window: NSWindow, becoming name: Notification.Name) {
        guard isNew(window) else {
            return
        }
        // Only a window that is ordered in counts: one that never was reports itself unoccluded when it is
        // ordered out, and a test may post the key notification of a window that never came on screen.
        let onScreen =
            window.isVisible
            && (name != NSWindow.didChangeOcclusionStateNotification || window.occlusionState.contains(.visible))
        if onScreen { shown.append(window.title) }
    }

    private func isNew(_ window: NSWindow) -> Bool {
        !earlier.contains(ObjectIdentifier(window)) && isWatched(window)
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
