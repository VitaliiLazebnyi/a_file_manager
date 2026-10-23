import AFMKernel
import AppKit

/// The documents shown: one replaces the other once its wanted row is indexed.
extension TextPagerView {
    /// Shows `document` from its start; see `show(_:at:select:keepingSelection:parallel:)`.
    internal func show(_ document: TextDocument, parallel: Bool) {
        show(document, at: 0, select: nil, keepingSelection: false, parallel: parallel)
    }

    /// Shows `document` with the row of byte `offset` at the top, optionally with a selection
    /// (a found text).
    ///
    /// The text's rows are indexed in the background, on all cores with `parallel`; until the
    /// wanted row is known the view keeps what it showed before. `keepingSelection` is for the same
    /// bytes laid out anew: the selection stays.
    internal func show(
        _ document: TextDocument,
        at offset: Int64,
        select: Range<Int64>?,
        keepingSelection: Bool,
        parallel: Bool
    ) {
        pending?.document.cancellation.cancel()
        // The text shown goes on being read for the new layout only if nothing else is waiting
        // for the cores.
        if let shown = self.document, shown !== document, !shown.isIndexComplete { shown.stopIndexing() }
        pending = PendingDocument(document: document, offset: offset, select: select, keep: keepingSelection)
        if document.isIndexComplete {
            adoptPendingIfReady()
            return
        }
        // The threads hold the coalescer and the document, not this view.
        let coalescer = progress
        // Not more builds at a time than the gate allows: a read that cannot be interrupted keeps
        // its thread, and paging through files on such a volume must not strand one thread per file.
        indexGate.submit(
            cancellation: document.indexCancellation,
            refused: {
                document.record(ViewerError.busy)
                coalescer.signal()
            },
            {
                document.buildIndex(parallel: parallel, scanning: .standard) { coalescer.signal() }
            }
        )
    }

    /// Called on the main thread when the indexing threads have news.
    internal func indexProgressed() {
        adoptPendingIfReady()
        rowCountChanged()
    }

    /// Shows the pending document once its wanted row is indexed (or its build was refused).
    private func adoptPendingIfReady() {
        // A build that was refused (too many reads that cannot be ended are still pending) is shown
        // as it is, with its read error in the status line.
        guard let next = pending,
            next.document.isIndexComplete || next.document.indexedThrough > next.offset
                || next.document.readError as? ViewerError == .busy
        else { return }
        pending = nil
        // The same bytes laid out anew keep what the user sees and is doing: the selection, the
        // text at the top as it is now, and a place the view is still on its way to.
        let carried = next.keep ? outstandingReveal : nil
        let kept = next.keep ? selection : nil
        let keptCaret = next.keep ? caret?.offset : nil
        let top = next.keep ? row(topRow)?.range.lowerBound ?? next.offset : next.offset
        if document !== next.document {
            document?.cancellation.cancel()
            // What waited for rows of the old text is of no use for this one.
            afterLoad = []
            queues = DocumentQueues()
        }
        document = next.document
        knownTopOffset = nil
        generation += 1
        revealGeneration += 1
        outstandingReveal = nil
        loaded = []
        lines.removeAll()
        caret = nil
        caretToRestore = keptCaret
        anchor = kept?.lowerBound
        selection = kept
        topRow = 0
        horizontalOffset = 0
        needsDisplay = true
        if let carried {
            reveal(carried)
        } else if top > next.document.content.lowerBound || next.select != nil {
            reveal(
                RevealTarget(
                    offset: top,
                    select: next.select,
                    rowsAbove: next.select == nil ? 0 : searchGoBack,
                    keepingSelection: next.select == nil
                )
            )
        } else {
            ensureLoaded(force: false)
        }
        restoreCaret()
        onStatusChange()
    }

    /// Finds the row of the text cursor kept across a new layout; asked again as the index grows
    /// when its part of the text is not indexed yet.
    private func restoreCaret() {
        guard let offset = caretToRestore, let document, restoringCaretIn !== document else {
            return
        }
        restoringCaretIn = document
        queues.lookups.async { [weak self] in
            let row: Int?
            do { row = try document.row(containing: offset, cancellation: document.cancellation) } catch {
                if !document.cancellation.isCancelled { document.record(error) }
                row = nil
            }
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.restoringCaretIn = nil
                guard self.document === document, self.caretToRestore == offset else {
                    return
                }
                if let row {
                    self.caretToRestore = nil
                    self.caret = (offset, row)
                    self.needsDisplay = true
                    self.onStatusChange()
                } else if document.isIndexComplete {
                    self.caretToRestore = nil
                }
            }
        }
    }

    /// Stops the reading of the shown text and of the one that is to replace it, which are
    /// blocked on a slow file system perhaps; what is shown stays.
    internal func stopReading() {
        pending?.document.cancellation.cancel()
        document?.cancellation.cancel()
        fetchRequest?.flag.cancel()
        revealRequest?.flag.cancel()
    }

    /// Stops everything and shows nothing.
    internal func clear() {
        stopReading()
        pending = nil
        document = nil
        afterLoad = []
        queues = DocumentQueues()
        knownTopOffset = nil
        generation += 1
        revealGeneration += 1
        outstandingReveal = nil
        loaded = []
        lines.removeAll()
        selection = nil
        caret = nil
        caretToRestore = nil
        needsDisplay = true
    }

    /// The index grew: a place that waited for it is asked for again, and what came into view is fetched.
    private func rowCountChanged() {
        if revealWaitsForIndex, let waiting = outstandingReveal {
            reveal(waiting)
        }
        updateScrollers()
        if isVisibleRangeMissing { ensureLoaded(force: false) }
        if caretToRestore != nil { restoreCaret() }
        onStatusChange()
    }
}
