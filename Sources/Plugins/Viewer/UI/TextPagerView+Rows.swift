import AFMKernel
import AppKit

/// Fetching the rows on screen in the background, and running what waits for them.
extension TextPagerView {
    /// Whether a row on screen is not in memory.
    internal var isVisibleRangeMissing: Bool {
        let last = min(rowCount, topRow + pageRows + 1) - 1
        return last >= topRow && (row(topRow) == nil || row(last) == nil)
    }

    /// Row `index` when it is in memory.
    internal func row(_ index: Int) -> DisplayRow? {
        let place = index - loadedFirst
        return place >= 0 && place < loaded.count ? loaded[place] : nil
    }

    /// Fetches the rows on screen and a page on either side, unless they are there already (or `force`).
    internal func ensureLoaded(force: Bool) {
        guard let document else {
            return
        }
        guard force || isVisibleRangeMissing else {
            runAfterLoad()
            return
        }
        // A text whose reading was stopped keeps what it shows.
        guard !document.cancellation.isCancelled else {
            return
        }
        generation += 1
        let wanted = generation
        let first = max(0, topRow - pageRows)
        let count = pageRows * 3 + 2
        let latest = latestRows
        // The fetch that is overtaken stops reading, even where it waits for a server.
        let request = newRequest(replacing: &fetchRequest, for: document)
        queues.rows.async { [weak self] in
            // Overtaken while it waited (the scroller dragged over a slow server): do not read.
            guard latest.value == wanted else {
                return
            }
            let rows: [DisplayRow]
            do {
                rows = try autoreleasepool { try document.rows(from: first, count: count, cancellation: request.flag) }
            } catch {
                if !request.flag.isCancelled { document.record(error) }
                rows = []
            }
            DispatchQueue.main.async {
                guard let self, self.generation == wanted, self.document === document else {
                    return
                }
                // A fetch that was stopped brought nothing: the rows on screen stay.
                guard !request.flag.isCancelled else {
                    return
                }
                self.loaded = rows
                self.loadedFirst = first
                // The lines of rows that are still shown are kept: making one costs a typesetting.
                self.lines = self.lines.filter { $0.key >= first && $0.key < first + rows.count }
                if let top = self.row(self.topRow) { self.knownTopOffset = top.range.lowerBound }
                self.needsDisplay = true
                self.updateScrollers()
                self.runAfterLoad()
                self.onStatusChange()
            }
        }
    }

    /// The stop for a request that the next one of its kind replaces, and that ends with `document`.
    internal func newRequest(
        replacing old: inout LinkedCancellation?,
        for document: TextDocument
    ) -> LinkedCancellation {
        old?.flag.cancel()
        let request = LinkedCancellation(document.cancellation)
        old = request
        return request
    }

    /// Runs `action` with the pager, its document and a row (of the rows there are), scrolling
    /// to the row and loading it first when necessary.
    internal func withRow(_ index: Int, _ action: @escaping (TextPagerView, TextDocument, DisplayRow) -> Void) {
        if let document, let row = row(index) {
            action(self, document, row)
            return
        }
        let before = generation
        scrollToShow(index)
        afterLoad.append { pager in
            if let shown = pager.document, let row = pager.row(index) { action(pager, shown, row) }
        }
        // Scrolling asked for the rows already.
        if generation == before { ensureLoaded(force: false) }
    }

    private func runAfterLoad() {
        let actions = afterLoad
        afterLoad = []
        for action in actions {
            action(self)
        }
    }
}
