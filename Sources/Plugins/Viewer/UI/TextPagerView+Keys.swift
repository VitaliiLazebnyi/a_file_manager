import AppKit

/// The cursor keys and the selection (spec 10 › Text modes).
extension TextPagerView {
    /// How the cursor keys move (spec 10 › Text modes).
    internal enum Motion {
        /// To the end of the text (Ctrl+End).
        case fileEnd
        /// To the start of the text (Ctrl+Home).
        case fileStart
        /// A character to the left (←).
        case left
        /// A page down (Page Down, Space).
        case pageDown
        /// A page up (Page Up).
        case pageUp
        /// A character to the right (→).
        case right
        /// A row down (↓).
        case rowDown
        /// To the end of the row (End).
        case rowEnd
        /// To the start of the row (Home).
        case rowStart
        /// A row up (↑).
        case rowUp
        /// To the start of the word before (Ctrl+←).
        case wordLeft
        /// To the start of the next word (Ctrl+→).
        case wordRight

        /// Whether it moves up or down, where the text cursor keeps its place in the row.
        internal var isVertical: Bool { self == .rowUp || self == .rowDown || self == .pageUp || self == .pageDown }
    }

    /// Selects the whole text (Ctrl+A).
    internal func selectAll() {
        guard let document else {
            return
        }
        selection = document.content.isEmpty ? nil : document.content
        anchor = document.content.lowerBound
        needsDisplay = true
        onStatusChange()
    }

    /// Selects nothing; the text cursor stays.
    internal func clearSelection() {
        selection = nil
        needsDisplay = true
        onStatusChange()
    }

    /// Puts the text cursor at `offset` in `row`; `extending` selects from the anchor to it (Shift).
    internal func setCaret(_ offset: Int64, row: Int, extending: Bool) {
        if extending {
            let from = anchor ?? caret?.offset ?? offset
            anchor = from
            selection = from == offset ? nil : min(from, offset)..<max(from, offset)
        } else {
            anchor = offset
            selection = nil
        }
        caret = (offset, row)
        caretToRestore = nil
        scrollToShow(row)
        needsDisplay = true
        onStatusChange()
    }

    /// Moves the text cursor without selecting, or scrolls when it is not shown.
    internal func perform(_ motion: Motion) {
        perform(motion, extending: false)
    }

    /// Moves the text cursor, selecting with `extending` (Shift), or scrolls when it is not shown
    /// (spec 10 › Text modes).
    internal func perform(_ motion: Motion, extending: Bool) {
        guard let document, rowCount > 0 else {
            return
        }
        guard showsCaret else {
            scrollInstead(motion)
            return
        }
        let current = caret ?? (row(topRow)?.range.lowerBound ?? document.content.lowerBound, topRow)
        if !motion.isVertical { preferredX = nil }
        moveCaret(motion, from: current, extending: extending)
    }

    /// How many rows a vertical motion goes.
    private func rowStep(_ motion: Motion) -> Int {
        switch motion {
        case .rowUp:
            return -1

        case .rowDown:
            return 1

        case .pageUp:
            return -pageRows

        default:
            return pageRows
        }
    }

    /// Without a text cursor the keys scroll: rows up and down, a few characters or half a view sideways.
    private func scrollInstead(_ motion: Motion) {
        switch motion {
        case .rowUp, .rowDown, .pageUp, .pageDown:
            scroll(toRow: topRow + rowStep(motion))

        case .rowStart, .fileStart:
            scroll(toRow: 0)

        case .rowEnd, .fileEnd:
            scroll(toRow: rowCount)

        case .left:
            scrollHorizontally(to: horizontalOffset - characterWidth * 4)

        case .right:
            scrollHorizontally(to: horizontalOffset + characterWidth * 4)

        case .wordLeft:
            scrollHorizontally(to: horizontalOffset - textArea.width / 2)

        case .wordRight:
            scrollHorizontally(to: horizontalOffset + textArea.width / 2)
        }
    }

    /// Moves the text cursor from `current` (its offset and row) as `motion` says.
    private func moveCaret(_ motion: Motion, from current: (offset: Int64, row: Int), extending: Bool) {
        switch motion {
        case .fileStart:
            withRow(0) { pager, _, row in pager.setCaret(row.range.lowerBound, row: 0, extending: extending) }

        case .fileEnd:
            let last = rowCount - 1
            withRow(last) { pager, _, row in pager.setCaret(row.contentEnd, row: last, extending: extending) }

        case .rowUp, .rowDown, .pageUp, .pageDown:
            let target = max(0, min(rowCount - 1, current.row + rowStep(motion)))
            moveCaretVertically(from: current, to: target, extending: extending)

        case .rowStart:
            withRow(current.row) { pager, _, row in
                pager.setCaret(row.range.lowerBound, row: row.index, extending: extending)
            }

        case .rowEnd:
            withRow(current.row) { pager, _, row in
                pager.setCaret(row.contentEnd, row: row.index, extending: extending)
            }

        case .left, .wordLeft:
            withRow(current.row) { pager, document, row in
                let byWord = motion == .wordLeft
                pager.moveCaretLeft(from: current.offset, in: row, of: document, byWord: byWord, extending: extending)
            }

        case .right, .wordRight:
            withRow(current.row) { pager, document, row in
                let byWord = motion == .wordRight
                pager.moveCaretRight(from: current.offset, in: row, of: document, byWord: byWord, extending: extending)
            }
        }
    }

    /// Moves the text cursor to row `target`, keeping its place in the row (`preferredX`).
    private func moveCaretVertically(from current: (offset: Int64, row: Int), to target: Int, extending: Bool) {
        withRow(current.row) { pager, document, from in
            let place = pager.preferredX ?? pager.xPosition(in: from, of: current.offset, document)
            pager.preferredX = place
            pager.withRow(target) { pager, document, row in
                pager.setCaret(
                    document.byteOffset(in: row, at: pager.textIndex(in: row, atX: place)),
                    row: target,
                    extending: extending
                )
            }
        }
    }

    /// ← and Ctrl+←: a character (a byte in Hex) or a word to the left, onto the row before at the start of one.
    private func moveCaretLeft(
        from offset: Int64,
        in row: DisplayRow,
        of document: TextDocument,
        byWord: Bool,
        extending: Bool
    ) {
        if offset <= row.range.lowerBound {
            guard row.index > 0 else {
                return
            }
            withRow(row.index - 1) { pager, shown, previous in
                // The end of a wrapped row is the same byte as the start of the next:
                // step onto its last character instead.
                let end =
                    previous.contentEnd < offset
                    ? previous.contentEnd
                    : shown.byteOffset(in: previous, at: max(0, previous.text.utf16.count - 1))
                pager.setCaret(end, row: previous.index, extending: extending)
            }
            return
        }
        guard document.layout != .hex else {
            setCaret(offset - 1, row: row.index, extending: extending)
            return
        }
        var index = min(document.textIndex(in: row, of: offset), row.text.utf16.count)
        if byWord {
            index = Self.wordStart(before: index, in: row.text)
        } else {
            repeat {
                index -= 1
            } while index > 0 && document.byteOffset(in: row, at: index) == document.byteOffset(in: row, at: index - 1)
        }
        setCaret(document.byteOffset(in: row, at: max(0, index)), row: row.index, extending: extending)
    }

    /// → and Ctrl+→: a character (a byte in Hex) or to the next word, onto the next row at the end of one.
    private func moveCaretRight(
        from offset: Int64,
        in row: DisplayRow,
        of document: TextDocument,
        byWord: Bool,
        extending: Bool
    ) {
        if offset >= row.contentEnd {
            guard row.index + 1 < rowCount else {
                return
            }
            withRow(row.index + 1) { pager, _, next in
                pager.setCaret(next.range.lowerBound, row: next.index, extending: extending)
            }
            return
        }
        guard document.layout != .hex else {
            setCaret(offset + 1, row: row.index, extending: extending)
            return
        }
        let count = row.text.utf16.count
        var index = document.textIndex(in: row, of: offset)
        if byWord {
            index = Self.wordStart(after: index, in: row.text)
        } else {
            repeat {
                index += 1
            } while index < count && document.byteOffset(in: row, at: index) == offset
        }
        setCaret(document.byteOffset(in: row, at: index), row: row.index, extending: extending)
    }
}
