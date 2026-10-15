import AFMKernel
import AppKit

@testable import AFMShell

/// What the tests read of a panel in a word: the program reads the same state by its parts.
extension PanelViewController {
    /// The status line of these figures, for a folder that is all there.
    internal static func statusText(_ totals: PanelModel.Totals) -> String {
        statusText(totals, itemsSoFar: nil, refreshing: false)
    }

    /// The status line of these figures, for a folder of which `itemsSoFar` entries have come.
    internal static func statusText(_ totals: PanelModel.Totals, itemsSoFar: Int?) -> String {
        statusText(totals, itemsSoFar: itemsSoFar, refreshing: false)
    }

    /// True while a reading of the active tab's folder that was put off is still to come.
    internal var hasPendingReread: Bool { dirty[ObjectIdentifier(model)] != nil }

    /// What the status line says.
    internal var statusLineText: String { statusLabel.stringValue }

    /// What the path bar says, e.g. `/Users/me/*.*`.
    internal var pathBarText: String { pathBar.text }

    /// What a drag that starts on a row carries; nothing when the row cannot be dragged.
    internal func draggedItems(fromRow row: Int) -> [FileItem] {
        dragPayload(fromRow: row)?.items ?? []
    }

    /// What dropping `sources` on a row would do, as a drag that carries them would be judged.
    internal func dropPlan(
        for sources: [URL],
        row: Int,
        modifiers: NSEvent.ModifierFlags,
        allowed: NSDragOperation
    ) -> PanelDropPlan? {
        dropPlan(for: DropSession(sequence: 0, sources: sources), row: row, modifiers: modifiers, allowed: allowed)
    }
}
