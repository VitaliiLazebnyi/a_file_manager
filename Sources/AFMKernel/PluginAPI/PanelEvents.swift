import Foundation

/// What happens in the panels, for plugins that follow them (a quick-view pane follows the
/// cursor, a tree follows the directory).
public enum PanelEvent: Sendable {
    /// The cursor is on another item, or the panel's list changed under it.
    case cursorMoved
    /// The marked items changed.
    case selectionChanged
    /// The panel shows another directory or another tab.
    case locationChanged
    /// This panel became the source.
    case becameSource
}

/// Where the window shell announces panel events and plugins listen. Main thread only.
@MainActor
public final class PanelEvents {
    private final class Subscription {
        let handler: (PanelEvent, any PanelHandle) -> Void
        init(_ handler: @escaping (PanelEvent, any PanelHandle) -> Void) { self.handler = handler }
    }

    private var subscriptions: [() -> Subscription?] = []

    public init() {}

    /// `handler` is called on the main thread for every event until the returned object is
    /// released; whoever subscribes keeps it.
    public func subscribe(_ handler: @escaping (PanelEvent, any PanelHandle) -> Void) -> AnyObject {
        let subscription = Subscription(handler)
        subscriptions.append { [weak subscription] in subscription }
        return subscription
    }

    /// Called by the shell.
    public func post(_ event: PanelEvent, from panel: any PanelHandle) {
        MainThread.assert("Panel events")
        subscriptions.removeAll { $0() == nil }
        for subscription in subscriptions.compactMap({ $0() }) { subscription.handler(event, panel) }
    }
}
