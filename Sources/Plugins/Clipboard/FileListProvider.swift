import AppKit

/// The paths of a large selection as text, for other programs: nothing is made until one of
/// them asks, and then the whole list in one piece.
///
/// **Threading.** The pasteboard calls on the main thread; the list never changes.
internal final class FileListProvider: NSObject, NSPasteboardItemDataProvider {
    private let urls: [URL]

    /// A provider of the paths of `urls`, one per line.
    internal init(_ urls: [URL]) {
        self.urls = urls
    }

    /// Writes the paths, one per line, as the text `type` another program asked for; main thread.
    internal func pasteboard(
        _: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        item.setString(urls.map(\.path).joined(separator: "\n"), forType: type)
    }
}
