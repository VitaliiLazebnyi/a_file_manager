import Foundation

/// Editing: resync, swap, typing in a pane, copying lines across, and Undo.
extension CompareSession {
    /// What copying `rows` from `source` to `target` (on `side`) changes: the lines that arrive and the splice
    /// that takes them back; nil when nothing would change.
    private static func copied(
        _ rows: Range<Int>,
        of diff: TextDiff,
        from source: TextDocument,
        to target: TextDocument,
        side: CompareSide
    ) -> (splice: Splice, incoming: [TextLine])? {
        // Lines arrive with the line break the target file mostly uses, so a file keeps one
        // style (spec 09 › Edit mode and saving); an empty target takes the source's.
        let ending =
            target.lines.contains { line in line.ending != .noBreak }
            ? target.usualEnding(sampleLimit: 10_000) : source.usualEnding(sampleLimit: 10_000)
        // The rows were made from these texts; an index outside them is skipped, never trusted.
        let incoming = diff.rows[rows]
            .compactMap { row in lineIndex(row, on: side.other) }
            .filter { index in source.lines.indices.contains(index) }
            .map { index in TextLine(source.lines[index].text, ending: ending, number: 0) }
        let replaced = diff.rows[rows]
            .compactMap { row in lineIndex(row, on: side) }
            .filter { index in target.lines.indices.contains(index) }
        // Where nothing is replaced, the lines go in before the target's next line.
        let start =
            replaced.first ?? diff.rows[rows.upperBound...].lazy.compactMap { row in lineIndex(row, on: side) }.first
            ?? target.lines.count
        let range = start..<(start + replaced.count)
        guard range.upperBound <= target.lines.count, Array(target.lines[range]).map(\.text) != incoming.map(\.text)
        else {
            return nil
        }
        let splice = Splice(
            side: side,
            start: start,
            removed: Array(target.lines[range]),
            insertedCount: incoming.count
        )
        return (splice, incoming)
    }

    /// The index of the line a row shows on `side`; nil where the side has none.
    private static func lineIndex(_ row: DiffRow, on side: CompareSide) -> Int? {
        side == .left ? row.left : row.right
    }

    // MARK: Resync and swap

    /// "Resync comparison from here": the lines of the two rows are taken to belong together.
    internal func resync(leftRow: Int, rightRow: Int) {
        guard case .text(_, _, let diff, _) = content, diff.rows.indices.contains(leftRow),
            diff.rows.indices.contains(rightRow),
            let left = diff.rows[leftRow].left, let right = diff.rows[rightRow].right
        else {
            return
        }
        // Anchors that the new one crosses are given up.
        anchors.removeAll { anchor in
            (anchor.left < left) != (anchor.right < right) || anchor.left == left || anchor.right == right
        }
        anchors.append((left, right))
        recompute()
    }

    /// Gives up every pair of lines the user resynchronized, and compares again.
    internal func clearResync() {
        guard !anchors.isEmpty else {
            return
        }
        anchors = []
        recompute()
    }

    /// Swap panels (Ctrl+U): left becomes right.
    internal func swap() {
        (leftURL, rightURL) = (rightURL, leftURL)
        loaded = (loaded.right, loaded.left)
        modified = (modified.right, modified.left)
        findGeneration += 1
        anchors = anchors.map { anchor in (anchor.right, anchor.left) }
        undoStack = []
        switch content {
        case .empty:
            onChange()

        case .text(let left, let right, _, _):
            content = .text(left: right, right: left, diff: TextDiff(rows: [], blocks: []), width: 0)
            diffIsCurrent = false
            recompute()

        case .binary(let left, let right, _):
            content = .binary(left: right, right: left, diff: BinaryDiff.compute(left: Data(), right: Data()))
            recompute()
        }
    }

    // MARK: Editing

    /// Applies an edit in place and remembers what it replaced.
    ///
    /// The texts are taken out of `content` first, so that nothing else holds their lines and they
    /// are changed where they are: an edit in a file of millions of lines does not copy it.
    private func edit(_ change: (inout TextDocument, inout TextDocument, TextDiff) -> [Splice]) {
        guard isEditing, phase == .ready, diffIsCurrent, case .text(var left, var right, let diff, let width) = content
        else {
            return
        }
        content = .empty
        let splices = change(&left, &right, diff)
        guard !splices.isEmpty else {
            content = .text(left: left, right: right, diff: diff, width: width)
            return
        }
        let touched = (
            left: splices.contains { splice in splice.side == .left },
            right: splices.contains { splice in splice.side == .right }
        )
        undoStack.append((splices, modified))
        if undoStack.count > Self.undoDepth {
            undoStack.removeFirst()
        }
        editGeneration += 1
        findGeneration += 1
        modified = (modified.left || touched.left, modified.right || touched.right)
        // Line positions have moved, so the forced pairs no longer mean anything.
        anchors = []
        content = .text(left: left, right: right, diff: diff, width: width)
        diffIsCurrent = false
        recompute()
    }

    /// Replaces the text of a row's line on one side, as typed in the pane.
    internal func setText(_ text: String, _ side: CompareSide, row: Int) {
        edit { left, right, diff in
            guard diff.rows.indices.contains(row),
                let index = side == .left ? diff.rows[row].left : diff.rows[row].right
            else {
                return []
            }
            let apply = { (document: inout TextDocument) -> [Splice] in
                guard document.lines.indices.contains(index), document.lines[index].text != text else {
                    return []
                }
                let old = document.lines[index]
                document.lines[index].text = text
                document.lines[index].number = 0
                return [Splice(side: side, start: index, removed: [old], insertedCount: 1)]
            }
            return side == .left ? apply(&left) : apply(&right)
        }
    }

    /// Copies the lines of the given rows from the other side over the lines on `side` (Copy -> and Copy <-).
    ///
    /// Rows that have no line on the source side remove the target's lines.
    internal func copy(rows: Range<Int>, to side: CompareSide) {
        edit { left, right, diff in
            let chosen = rows.clamped(to: 0..<diff.rows.count)
            guard !chosen.isEmpty else {
                return []
            }
            var target = side == .left ? left : right
            guard
                let copied = Self.copied(chosen, of: diff, from: side == .left ? right : left, to: target, side: side)
            else {
                return []
            }
            let range = copied.splice.start..<(copied.splice.start + copied.splice.removed.count)
            // Released before the change, so that it is made in the lines of the document itself.
            target = TextDocument()
            if side == .left {
                left.lines.replaceSubrange(range, with: copied.incoming)
            } else {
                right.lines.replaceSubrange(range, with: copied.incoming)
            }
            return [copied.splice]
        }
    }

    /// Takes the last edit back, with which sides were modified before it.
    internal func undo() {
        guard isEditing, case .text(var left, var right, let diff, let width) = content, let last = undoStack.popLast()
        else {
            return
        }
        content = .empty
        for splice in last.splices.reversed() {
            let range = splice.start..<(splice.start + splice.insertedCount)
            if splice.side == .left, range.upperBound <= left.lines.count {
                left.lines.replaceSubrange(range, with: splice.removed)
            } else if splice.side == .right, range.upperBound <= right.lines.count {
                right.lines.replaceSubrange(range, with: splice.removed)
            }
        }
        modified = last.modified
        editGeneration += 1
        findGeneration += 1
        anchors = []
        content = .text(left: left, right: right, diff: diff, width: width)
        diffIsCurrent = false
        recompute()
    }
}
