import AppKit

/// The view of the result list.
extension SyncWindowController {
    /// The result list, whose keys go to the window first.
    internal final class KeyTableView: NSTableView {
        /// Handles a key; true when it was used, else the table handles it.
        internal var onKey: ((NSEvent) -> Bool)?

        /// Offers the key to `onKey` first.
        override internal func keyDown(with event: NSEvent) {
            if onKey?(event) != true {
                super.keyDown(with: event)
            }
        }

        /// A right click on a row outside the selection moves the selection there first.
        override internal func menu(for event: NSEvent) -> NSMenu? {
            let row = self.row(at: convert(event.locationInWindow, from: nil))
            guard row >= 0 else {
                return nil
            }
            if !selectedRowIndexes.contains(row) {
                selectRowIndexes([row], byExtendingSelection: false)
            }
            return super.menu(for: event)
        }
    }
}
