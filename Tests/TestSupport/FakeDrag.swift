public import AppKit

/// A drag as a table view's data source sees it: a pasteboard, where it comes from and nothing
/// else.
///
/// For dropping rows on a list without a mouse.
@preconcurrency
@MainActor
public final class FakeDrag: NSObject, NSDraggingInfo {
    /// The pasteboard the drag carries.
    public let draggingPasteboard: NSPasteboard
    /// The view the drag started in.
    public let draggingSource: Any?
    /// No window: the drop is handed to the data source directly.
    public let draggingDestinationWindow: NSWindow? = nil
    /// Every operation is allowed.
    public let draggingSourceOperationMask: NSDragOperation = .every
    /// Not used by a data source.
    public let draggingLocation = NSPoint.zero
    /// Not used by a data source.
    public let draggedImageLocation = NSPoint.zero
    /// Not used by a data source.
    public let draggedImage: NSImage? = nil
    /// Not used by a data source.
    public let draggingSequenceNumber = 1
    /// Not used by a data source.
    public var draggingFormation = NSDraggingFormation.default
    /// Not used by a data source.
    public var animatesToDestination = false
    /// Not used by a data source.
    public var numberOfValidItemsForDrop = 1
    /// Not used by a data source.
    public let springLoadingHighlight = NSSpringLoadingHighlight.none

    /// A drag from `source` that carries `pasteboard`.
    public init(from source: Any?, pasteboard: NSPasteboard) {
        draggingSource = source
        draggingPasteboard = pasteboard
        super.init()
    }

    /// Not used by a data source.
    public func slideDraggedImage(to _: NSPoint) {
        // Nothing is drawn.
    }

    /// Not used by a data source.
    public func enumerateDraggingItems(
        options _: NSDraggingItemEnumerationOptions,
        for _: NSView?,
        classes _: [AnyClass],
        searchOptions _: [NSPasteboard.ReadingOptionKey: Any],
        using _: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
        // Nothing is dragged as items.
    }

    /// Not used by a data source.
    public func resetSpringLoading() {
        // Nothing springs open.
    }
}
