import AFMKernel
import AppKit

/// What a drag that started in a panel carries.
///
/// Main thread only.
///
/// A drag of a few items holds them from the start. A drag of very many marked items
/// starts with the marks alone (`PanelModel.Operands`, which costs nothing to take): the
/// list of the items and of their locations is put together in the background while the
/// drag is already under way, and whoever needs it before that (a drop a moment after the
/// start, another program asking for the files) has it put together then and there.
@MainActor
internal final class PanelDragPayload: NSObject, NSPasteboardItemDataProvider, @preconcurrency NSPasteboardTypeOwner {
    /// The items with their locations, once they are put together.
    private struct Gathered: Sendable {
        /// The dragged items.
        let items: [FileItem]
        /// Their locations, in the same order.
        let locations: [URL]

        /// The items `items`, with their locations.
        init(_ items: [FileItem]) {
            self.items = items
            locations = items.map(\.url)
        }
    }

    /// The ticket of the drag, which the first pasteboard item carries.
    internal let token = UUID().uuidString
    /// How many items are dragged.
    internal let count: Int
    /// The files are handed out on demand, all through the first pasteboard item.
    internal let isWrittenLazily: Bool
    private var gathered: Gathered?
    private var marks: PanelModel.Operands?
    private var waiting: [([URL]) -> Void] = []

    /// False while the items are still being put together in the background.
    internal var isReady: Bool { gathered != nil }

    /// The dragged items; put together here and now if the background has not got there.
    internal var items: [FileItem] {
        if gathered == nil, let marks {
            take(Gathered(marks.markedItems()))
        }
        return gathered?.items ?? []
    }

    /// The locations of the dragged items, in their order.
    internal var locations: [URL] {
        _ = items
        return gathered?.locations ?? []
    }

    /// A drag of these items, a few or many.
    internal init(items: [FileItem]) {
        count = items.count
        isWrittenLazily = items.count > PanelDrop.itemsWrittenSingly
        gathered = Gathered(items)
    }

    /// The marked items of a panel, as `marks` has them; they are many.
    internal init(marked marks: PanelModel.Operands) {
        count = marks.markedCount
        isWrittenLazily = true
        self.marks = marks
        super.init()
        Background.compute(
            work: { Gathered(marks.markedItems()) },
            then: { [weak self] gathered in self?.take(gathered) }
        )
    }

    /// Calls `receive` with the locations when they are known: now, or when the
    /// background has put them together.
    internal func whenReady(_ receive: @escaping ([URL]) -> Void) {
        if let gathered {
            receive(gathered.locations)
        } else {
            waiting.append(receive)
        }
    }

    /// Another program asks for a file: the first one of the local disks.
    ///
    /// AppKit asks on the main thread.
    internal nonisolated func pasteboard(
        _: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .fileURL else {
            return
        }
        let location = MainActor.assumeIsolated { items.first(where: \.url.isFileURL)?.url.absoluteString }
        if let location {
            item.setString(location, forType: .fileURL)
        }
    }

    /// Another program asks for the list of files: only now are their paths put together.
    internal func pasteboard(_ sender: NSPasteboard, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == PanelDrop.fileNamesType else {
            return
        }
        sender.setPropertyList(items.lazy.filter(\.url.isFileURL).map(\.url.path) as [String], forType: type)
    }

    /// The items are put together: whoever waited hears of them.
    ///
    /// The first to come counts.
    private func take(_ result: Gathered) {
        guard gathered == nil else {
            return
        }
        gathered = result
        marks = nil
        let waiting = waiting
        self.waiting = []
        for receiver in waiting {
            receiver(result.locations)
        }
    }

    deinit {
        // Nothing to release.
    }
}
