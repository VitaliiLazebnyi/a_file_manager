import AppKit

/// A drag as AppKit describes it to the view it moves over, with the source it came from.
@MainActor
internal final class WindowCovDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    /// Where the drag came from.
    internal let draggingSource: Any?
    /// Where the mouse is, in the window.
    internal var draggingLocation: NSPoint
    /// The pasteboard of the drag.
    internal let draggingPasteboard = NSPasteboard.withUniqueName()
    /// What the source allows.
    internal var draggingSourceOperationMask: NSDragOperation = .move
    /// Which drag this is.
    internal let draggingSequenceNumber = 1
    /// The window the drag is over.
    internal var draggingDestinationWindow: NSWindow?
    /// How the dragged items are arranged.
    internal var draggingFormation: NSDraggingFormation = .default
    /// Whether the items slide to where they were dropped.
    internal var animatesToDestination = false
    /// How many items the destination takes.
    internal var numberOfValidItemsForDrop = 0

    /// Where the dragged image is: where the mouse is.
    internal var draggedImageLocation: NSPoint { draggingLocation }
    /// No picture.
    internal var draggedImage: NSImage? { nil }
    /// No spring loading.
    internal var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    /// A drag from `source` over `location` of the window.
    internal init(from source: Any?, at location: NSPoint) {
        draggingSource = source
        draggingLocation = location
    }

    /// Nothing slides.
    internal func slideDraggedImage(to _: NSPoint) {
        // Nothing is drawn.
    }

    /// No items are offered one by one.
    internal func enumerateDraggingItems(
        options _: NSDraggingItemEnumerationOptions,
        for _: NSView?,
        classes _: [AnyClass],
        searchOptions _: [NSPasteboard.ReadingOptionKey: Any],
        using _: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
        // Nothing to enumerate.
    }

    /// Nothing to reset.
    internal func resetSpringLoading() {
        // No spring loading.
    }
}
