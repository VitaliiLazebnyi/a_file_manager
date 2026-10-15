import AFMKernel
import Foundation

/// One reading of a location for a tab of a panel: its cancellation, the order the list should
/// come in, and who is waiting for it to end. Main thread only.
@MainActor
internal final class PanelLoad {
    /// Set when the reading is overtaken or abandoned.
    internal let flag = CancellationFlag()
    /// The order of the tab's list, which the reading follows when it changes under way.
    internal let order: PanelLoading.OrderBox
    /// Where the reading takes the tab; nil for a reading of the folder the tab shows.
    internal let destination: URL?
    /// A quiet reading: nothing is announced unless it finds the folder changed.
    internal let isQuiet: Bool
    /// When the reading was asked for, in the system's uptime.
    internal let started = ProcessInfo.processInfo.systemUptime
    /// What has to live as long as the reading (the way out of a reading that was taken over).
    internal var keeps: [AnyObject] = []
    private var completion: ((Bool) -> Void)?

    /// A reading in `order` to `destination` (nil: the tab's own folder); `completion` hears
    /// whether it worked.
    internal init(order: ListOrder, destination: URL?, isQuiet: Bool, completion: ((Bool) -> Void)?) {
        self.order = PanelLoading.OrderBox(order)
        self.destination = destination
        self.isQuiet = isQuiet
        self.completion = completion
    }

    /// The reading ended; `succeeded` is false for a failure. Whoever waits is told once.
    internal func complete(_ succeeded: Bool) {
        let waiting = completion
        completion = nil
        keeps = []
        waiting?(succeeded)
    }

    /// A newer reading overtook this one, or its tab is gone: whoever waits hears of
    /// the failure, after the newer reading is in place.
    internal func supersede() {
        MainLoop.queue { self.complete(false) }
    }

    deinit {
        // Nothing to release.
    }
}
