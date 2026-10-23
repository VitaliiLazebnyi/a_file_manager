import AppKit

/// Typeset rows, places in them, and the mouse: clicks, drags and the context menu.
extension TextPagerView {
    /// The typeset row, made once and kept while the row is in memory.
    internal func line(for row: DisplayRow) -> CTLine {
        if let line = lines[row.index] {
            return line
        }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: row.text, attributes: [.font: font, .foregroundColor: NSColor.textColor])
        )
        lines[row.index] = line
        return line
    }

    /// The UTF-16 place in the text of `row` nearest to `position` points from its start.
    internal func textIndex(in row: DisplayRow, atX position: CGFloat) -> Int {
        max(0, min(row.text.utf16.count, CTLineGetStringIndexForPosition(line(for: row), CGPoint(x: position, y: 0))))
    }

    /// How far from the start of `row` byte `offset` is drawn, in points; the end of the text for its line end.
    internal func xPosition(in row: DisplayRow, of offset: Int64, _ document: TextDocument) -> CGFloat {
        let index =
            offset >= row.contentEnd && document.layout != .hex
            ? row.text.utf16.count : document.textIndex(in: row, of: offset)
        return CTLineGetOffsetForStringIndex(line(for: row), min(index, row.text.utf16.count), nil)
    }

    /// The row and the place in its text under a point of the view.
    internal func hit(_ point: NSPoint) -> (row: DisplayRow, index: Int)? {
        let number = max(topRow, min(rowCount - 1, topRow + Int(floor((point.y - inset) / lineHeight))))
        guard let row = row(number) else {
            return nil
        }
        return (row, textIndex(in: row, atX: point.x - inset + horizontalOffset))
    }

    /// A click puts the text cursor there (Shift selects to it); a double click selects a word, a triple
    /// click a row.
    internal func click(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let document, let hit = hit(convert(event.locationInWindow, from: nil)) else {
            return
        }
        preferredX = nil
        if event.clickCount == 2 {
            let word = Self.wordRange(
                around: min(hit.index, max(0, hit.row.text.utf16.count - 1)),
                in: hit.row.text
            )
            let lower = document.byteOffset(in: hit.row, at: word.lowerBound)
            let upper = document.byteOffset(in: hit.row, at: word.upperBound)
            anchor = lower
            setCaret(max(lower, upper), row: hit.row.index, extending: true)
        } else if event.clickCount >= 3 {
            anchor = hit.row.range.lowerBound
            setCaret(hit.row.range.upperBound, row: hit.row.index, extending: true)
        } else {
            setCaret(
                document.byteOffset(in: hit.row, at: hit.index),
                row: hit.row.index,
                extending: event.modifierFlags.contains(.shift)
            )
        }
    }

    /// A drag selects; above or below the text it scrolls a row at a time.
    internal func drag(_ event: NSEvent) {
        guard let document else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if point.y < 0 { scroll(toRow: topRow - 1) }
        if point.y > textArea.height { scroll(toRow: topRow + 1) }
        guard let hit = hit(NSPoint(x: point.x, y: max(0, min(point.y, textArea.height - 1)))) else {
            return
        }
        setCaret(document.byteOffset(in: hit.row, at: hit.index), row: hit.row.index, extending: true)
    }

    /// The text of the row under a point of the window, and the place in it: for the context
    /// menu, which looks for a link there (spec 10 › Context menu rules).
    internal func text(at windowPoint: NSPoint) -> (text: String, index: Int)? {
        hit(convert(windowPoint, from: nil)).map { ($0.row.text, $0.index) }
    }
}
