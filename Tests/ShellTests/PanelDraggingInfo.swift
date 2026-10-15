import AppKit

/// A drag as AppKit describes it to a view it moves over: what it carries, where the mouse is,
/// what its source allows and which drag it is.
@MainActor
internal final class PanelDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    /// Everything a drag of files may allow.
    internal static let anything: NSDragOperation = [.copy, .move, .generic]

    /// The pasteboard of the drag.
    internal let draggingPasteboard: NSPasteboard
    /// Where the mouse is, in the window.
    internal var draggingLocation: NSPoint
    /// What the source of the drag allows.
    internal var draggingSourceOperationMask: NSDragOperation
    /// Which drag this is.
    internal let draggingSequenceNumber: Int
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
    /// The source is not known.
    internal var draggingSource: Any? { nil }
    /// No spring loading.
    internal var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    /// Drag number `sequence` carrying what `pasteboard` holds, over `location`.
    internal init(
        sequence: Int,
        pasteboard: NSPasteboard,
        location: NSPoint,
        allowed: NSDragOperation
    ) {
        draggingSequenceNumber = sequence
        draggingPasteboard = pasteboard
        draggingLocation = location
        draggingSourceOperationMask = allowed
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

    deinit {
        // Nothing to release.
    }
}
