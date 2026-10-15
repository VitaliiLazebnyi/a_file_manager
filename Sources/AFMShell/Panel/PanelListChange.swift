import AFMKernel
import Foundation

/// A change of a tab's list that the model works out from the list as it is
/// (`PanelModel.prepare`): a fresh reading compared with what is shown, a list that has grown,
/// another filter. `PanelViewController.apply` makes it, in the background for a long list.
@MainActor
internal struct PanelListChange {
    /// The tab whose list changes.
    internal let tab: PanelModel
    /// The length of the list that is coming; 0 when the change brings no list.
    internal let count: Int
    /// The list the change brings, if any: when it turns out not to be needed, it is let go of
    /// in the background.
    internal let fresh: [FileItem]
    /// Asked on the main thread before the result is taken: when it says no, nothing is changed.
    internal let isWanted: () -> Bool
    /// Works the change out, on any thread.
    internal let prepare: @Sendable (PanelModel.Basis) -> PanelModel.Prepared

    /// A change of `tab` that brings the list `fresh` (empty for none, `count` long), made while
    /// `isWanted` says so, worked out by `prepare`.
    internal init(
        of tab: PanelModel,
        bringing fresh: [FileItem],
        while isWanted: @escaping () -> Bool,
        by prepare: @escaping @Sendable (PanelModel.Basis) -> PanelModel.Prepared
    ) {
        self.tab = tab
        count = fresh.count
        self.fresh = fresh
        self.isWanted = isWanted
        self.prepare = prepare
    }

    /// A change of `tab` for a list of `count` entries that the change does not carry itself.
    internal init(
        of tab: PanelModel,
        count: Int,
        while isWanted: @escaping () -> Bool,
        by prepare: @escaping @Sendable (PanelModel.Basis) -> PanelModel.Prepared
    ) {
        self.tab = tab
        self.count = count
        fresh = []
        self.isWanted = isWanted
        self.prepare = prepare
    }
}
