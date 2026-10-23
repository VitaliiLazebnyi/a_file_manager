import AFMKernel
import AppKit

/// Going to a place: a byte offset, a percentage, a line; the row is looked up in the background.
extension TextPagerView {
    /// Where the next search starts: behind the start of the selection (the last hit), else at
    /// the text cursor, else at the top of the view.
    ///
    /// Backwards it is the place to end before.
    internal func searchStart(backwards: Bool) -> Int64 {
        let unit = Int64(document?.encoding.unitSize ?? 1)
        if let selection {
            return backwards ? selection.lowerBound : selection.lowerBound + unit
        }
        return caret?.offset ?? topOffset
    }

    /// Scrolls to the row that holds a byte offset and puts the text cursor there; the row is looked up in the
    /// background.
    internal func reveal(offset: Int64) {
        reveal(RevealTarget(offset: offset, select: nil, rowsAbove: 0, keepingSelection: false))
    }

    /// The same with `select` selected (a found text), `rowsAbove` rows below the top; `keepingSelection`
    /// leaves the selection and the text cursor as they are.
    internal func reveal(offset: Int64, select: Range<Int64>?, rowsAbove: Int, keepingSelection: Bool) {
        reveal(RevealTarget(offset: offset, select: select, rowsAbove: rowsAbove, keepingSelection: keepingSelection))
    }

    /// Goes to `target`: once its row is found, or, while the index has not reached it, when it has.
    internal func reveal(_ target: RevealTarget) {
        guard let document else {
            return
        }
        revealGeneration += 1
        let wanted = revealGeneration
        outstandingReveal = target
        revealWaitsForIndex = false
        // Whether a row that is not found is not there at all, or only not indexed yet.
        let indexWasComplete = document.isIndexComplete
        let latest = latestReveal
        let request = newRequest(replacing: &revealRequest, for: document)
        queues.lookups.async { [weak self] in
            guard latest.value == wanted else {
                return
            }
            let row: Int?
            do { row = try document.row(containing: target.offset, cancellation: request.flag) } catch {
                if !request.flag.isCancelled { document.record(error) }
                row = nil
            }
            DispatchQueue.main.async {
                guard let self, self.revealGeneration == wanted, self.document === document else {
                    return
                }
                if let row {
                    self.arrive(at: row, for: target)
                } else {
                    self.miss(target, in: document, indexWasComplete: indexWasComplete)
                }
            }
        }
    }

    /// Scrolls to a place in the text, 0 to 100 % of its bytes.
    internal func scroll(toPercent percent: Double) {
        guard let document else {
            return
        }
        let fraction = min(1, max(0, percent / 100))
        if document.isIndexComplete {
            scroll(toRow: Int((Double(rowCount) * fraction).rounded(.down)))
        } else {
            reveal(offset: document.content.lowerBound + Int64(Double(document.content.count) * fraction))
        }
    }

    /// Scrolls to a line (counted from 1), when there is one.
    internal func scroll(toLine line: Int) {
        scroll(toLine: line) { _ in
            // Nobody waits to hear whether the line is there.
        }
    }

    /// Scrolls to a line (counted from 1); false is handed to `completion` when there is none.
    internal func scroll(toLine line: Int, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let document else {
            return
        }
        revealGeneration += 1
        let wanted = revealGeneration
        outstandingReveal = nil
        let latest = latestReveal
        let request = newRequest(replacing: &revealRequest, for: document)
        queues.lookups.async { [weak self] in
            guard latest.value == wanted else {
                return
            }
            let row: Int?
            do { row = try document.row(ofLine: line, cancellation: request.flag) } catch {
                if !request.flag.isCancelled { document.record(error) }
                row = nil
            }
            DispatchQueue.main.async {
                guard let self, self.revealGeneration == wanted, self.document === document else {
                    return
                }
                if let row {
                    self.topRow = row
                    self.clampTopRow()
                    self.caret = nil
                    self.ensureLoaded(force: true)
                    self.updateScrollers()
                    self.needsDisplay = true
                }
                completion(row != nil)
                self.onStatusChange()
            }
        }
    }

    /// The row of `target` was found: it goes to the place, with the selection or the text cursor it names.
    private func arrive(at row: Int, for target: RevealTarget) {
        outstandingReveal = nil
        // The same text laid out anew (`keepingSelection`): only the place changes.
        if !target.keepingSelection {
            caretToRestore = nil
            if let select = target.select {
                selection = select
                caret = (select.lowerBound, row)
                anchor = select.upperBound
            } else {
                selection = nil
                caret = showsCaret ? (target.offset, row) : nil
                anchor = nil
            }
        }
        topRow = row - target.rowsAbove
        clampTopRow()
        ensureLoaded(force: true)
        updateScrollers()
        needsDisplay = true
        onStatusChange()
    }

    /// The row of `target` was not found in `document`: beyond its end, or not indexed yet.
    private func miss(_ target: RevealTarget, in document: TextDocument, indexWasComplete: Bool) {
        if indexWasComplete {
            // The offset is beyond the text.
            outstandingReveal = nil
        } else if document.isIndexComplete {
            // The index was completed while the row was looked up: ask again, now for good.
            reveal(target)
        } else {
            // That part of the text is not indexed yet; `rowCountChanged` asks again.
            revealWaitsForIndex = true
        }
    }
}
