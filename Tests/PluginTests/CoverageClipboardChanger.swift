import AppKit

/// Provides the location of a file only when it is asked for, and gives the clipboard other
/// contents at that moment: a list that changes while it is being read.
///
/// Main thread only, as the pasteboard asks there.
internal final class CoverageClipboardChanger: NSObject, NSPasteboardItemDataProvider {
    /// The clipboard that changes.
    private let pasteboard: NSPasteboard
    /// Whether the location was asked for.
    internal private(set) var asked = false

    /// A provider that changes `pasteboard`.
    internal init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    /// Gives the clipboard other contents and the item no location.
    internal func pasteboard(
        _: NSPasteboard?,
        item _: NSPasteboardItem,
        provideDataForType _: NSPasteboard.PasteboardType
    ) {
        asked = true
        pasteboard.clearContents()
        pasteboard.setString("changed", forType: .string)
    }
}
