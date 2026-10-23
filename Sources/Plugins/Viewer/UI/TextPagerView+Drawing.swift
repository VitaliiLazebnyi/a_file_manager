import AppKit

/// Drawing the rows on screen, with the selection and the text cursor.
extension TextPagerView {
    /// Draws the rows that are in memory; the scrollers learn the width of the widest one.
    internal func drawRows() {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard let document, let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        context.saveGState()
        context.clip(to: textArea)
        var widest: CGFloat = 0
        let last = min(rowCount, topRow + pageRows + 1)
        for number in topRow..<max(topRow, last) {
            guard let row = row(number) else { continue }
            let line = line(for: row)
            widest = max(widest, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
            draw(row, line, at: inset + CGFloat(number - topRow) * lineHeight, of: document, in: context)
        }
        context.restoreGState()
        if abs(widest - widestLine) > 0.5 {
            widestLine = widest
            DispatchQueue.main.async { [weak self] in self?.updateScrollers() }
        }
    }

    /// Draws one row whose top is `top` points down the view: its selection, its text, the text cursor.
    private func draw(
        _ row: DisplayRow,
        _ line: CTLine,
        at top: CGFloat,
        of document: TextDocument,
        in context: CGContext
    ) {
        let originX = inset - horizontalOffset
        if let selection {
            (window?.firstResponder === self
                ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor)
                .setFill()
            for range in document.textRanges(in: row, for: selection) {
                let start = CTLineGetOffsetForStringIndex(line, range.lowerBound, nil)
                let end = CTLineGetOffsetForStringIndex(line, range.upperBound, nil)
                // A run that reads right to left has its end left of its start.
                NSRect(x: originX + min(start, end), y: top, width: max(2, abs(end - start)), height: lineHeight).fill()
            }
            // A selected line end shows as a little more than the text.
            if selection.contains(row.contentEnd), row.contentEnd < row.range.upperBound, document.layout != .hex {
                let end = CTLineGetOffsetForStringIndex(line, row.text.utf16.count, nil)
                NSRect(x: originX + end, y: top, width: characterWidth / 2, height: lineHeight).fill()
            }
        }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: originX, y: top + ascent)
        CTLineDraw(line, context)
        if showsCaret, let caret, caret.row == row.index {
            NSColor.textColor.setFill()
            NSRect(x: originX + xPosition(in: row, of: caret.offset, document), y: top, width: 1, height: lineHeight)
                .fill()
        }
    }
}
