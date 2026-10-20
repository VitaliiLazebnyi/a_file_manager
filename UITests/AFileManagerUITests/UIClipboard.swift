import AppKit

/// The clipboard as a test found it, to put back at its end.
@MainActor
internal struct UIClipboard {
    /// The text on the clipboard now.
    internal static var text: String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// Each item's data, by type.
    private let items: [[NSPasteboard.PasteboardType: Data]]

    /// What the clipboard holds now.
    internal init() {
        items = (NSPasteboard.general.pasteboardItems ?? [])
            .map { item in
                Dictionary(
                    uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
                )
            }
    }

    /// Puts back what the clipboard held.
    internal func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let restored = items.map { kept in
            let item = NSPasteboardItem()
            for (type, data) in kept {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
    }
}
