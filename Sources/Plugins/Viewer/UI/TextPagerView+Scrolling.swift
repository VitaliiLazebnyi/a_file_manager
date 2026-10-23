import AppKit

/// Scrolling by rows and sideways, and the two scrollers.
extension TextPagerView {
    /// Keeps the top row between the first and the last page.
    internal func clampTopRow() {
        topRow = max(0, min(topRow, rowCount - pageRows))
    }

    /// Puts `row` at the top (as far as the text reaches) and fetches what comes into view.
    internal func scroll(toRow row: Int) {
        let before = topRow
        topRow = row
        clampTopRow()
        guard topRow != before else {
            return
        }
        ensureLoaded(force: false)
        updateScrollers()
        needsDisplay = true
        onStatusChange()
    }

    /// Scrolls as little as needed for `row` to be on screen.
    internal func scrollToShow(_ row: Int) {
        if row < topRow {
            scroll(toRow: row)
        } else if row >= topRow + pageRows {
            scroll(toRow: row - pageRows + 1)
        }
    }

    /// Scrolls sideways to `offset` points, as far as the widest row reaches.
    internal func scrollHorizontally(to offset: CGFloat) {
        horizontalOffset = max(0, min(offset, max(0, widestLine + 2 * inset - textArea.width)))
        updateScrollers()
        needsDisplay = true
    }

    /// Sets the knobs of the scrollers to what is shown, and turns off one with nothing to scroll.
    internal func updateScrollers() {
        let rows = rowCount
        let page = pageRows
        verticalScroller.isEnabled = rows > page
        verticalScroller.knobProportion = rows > 0 ? min(1, CGFloat(page) / CGFloat(rows)) : 1
        verticalScroller.doubleValue = rows > page ? Double(topRow) / Double(rows - page) : 0
        let overhang = widestLine + 2 * inset - textArea.width
        horizontalScroller.isEnabled = overhang > 0
        horizontalScroller.knobProportion = overhang > 0 ? textArea.width / (widestLine + 2 * inset) : 1
        horizontalScroller.doubleValue = overhang > 0 ? Double(horizontalOffset / overhang) : 0
    }

    /// The action of the vertical scroller.
    @objc
    internal func scrolledVertically() {
        scrollerMoved(verticalScroller.hitPart)
    }

    /// What a click or drag on `part` of the vertical scroller does: a page up or down, or the
    /// place of the knob.
    internal func scrollerMoved(_ part: NSScroller.Part) {
        switch part {
        case .decrementPage:
            scroll(toRow: topRow - pageRows)

        case .incrementPage:
            scroll(toRow: topRow + pageRows)

        default:
            scroll(toRow: Int((verticalScroller.doubleValue * Double(max(0, rowCount - pageRows))).rounded()))
        }
    }

    /// The action of the horizontal scroller.
    @objc
    internal func scrolledHorizontally() {
        scrollHorizontally(
            to: CGFloat(horizontalScroller.doubleValue) * max(0, widestLine + 2 * inset - textArea.width)
        )
    }

    /// The wheel scrolls; with Ctrl it zooms the font.
    internal func scroll(byWheel event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            // A trackpad sends dozens of small deltas for one gesture: a step is a line's worth.
            zoomRemainder += event.scrollingDeltaY
            let step: CGFloat = event.hasPreciseScrollingDeltas ? 24 : 1
            let steps = Int(zoomRemainder / step)
            if steps != 0 {
                zoomRemainder -= CGFloat(steps) * step
                onZoom(max(-3, min(3, steps)))
            }
            return
        }
        let precise = event.hasPreciseScrollingDeltas
        if event.scrollingDeltaX != 0 {
            scrollHorizontally(to: horizontalOffset - event.scrollingDeltaX * (precise ? 1 : characterWidth * 3))
        }
        scrollRemainder -= event.scrollingDeltaY * (precise ? 1 : lineHeight)
        let rows = Int(scrollRemainder / lineHeight)
        if rows != 0 {
            scrollRemainder -= CGFloat(rows) * lineHeight
            scroll(toRow: topRow + rows)
        }
    }
}
