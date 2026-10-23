import AFMKernel
import Foundation

/// Select all, Invert selection, the commands that go by the item under the cursor, and steps.
extension Selections {
    /// `step` 0 means every entry; n ≥ 1 every n-th line downward from the cursor, and
    /// n ≤ -1 upward (spec 17 › Commands with parameters).
    internal func all(select: Bool, scope: SelectionScope, step: Int) {
        let model = source
        let change: PanelModel.SelectionChange = select ? .add : .remove
        guard step != 0 else {
            if scope != .both {
                markMatching(model, change, timedOut: nil) { scope.contains($0) }
            } else if select {
                model.selectAll()
            } else {
                model.clearSelection()
            }
            return
        }
        // A step beyond the list is the same as the list's length.
        let bounded = max(-Int(Int32.max), min(step, Int(Int32.max)))
        let cursor = model.cursor - (model.hasParentRow ? 1 : 0)
        markFound(model, change) { items, _, _ in
            var picked: [Int] = []
            var seen = 0
            let every = abs(bounded)
            func visit(_ index: Int) {
                guard scope.contains(items[index]) else {
                    return
                }
                if seen.isMultiple(of: every) { picked.append(index) }
                seen += 1
            }
            if bounded > 0 {
                var index = max(cursor, 0)
                while index < items.count {
                    visit(index)
                    index += 1
                }
            } else {
                var index = min(cursor, items.count - 1)
                while index >= 0 {
                    visit(index)
                    index -= 1
                }
            }
            return picked
        }
    }

    /// Inverts the selection of the entries `scope` lets through; the others keep theirs.
    internal func invert(scope: SelectionScope) {
        let model = source
        // Inverting everything is a pass over bits.
        if scope == .both {
            model.invertSelection()
            return
        }
        // The entries of the scope change their mark and the others keep theirs.
        markFound(model, .replace) { items, marks, _ in
            var indices: [Int] = []
            for index in items.indices where scope.contains(items[index]) != marks.isMarked(at: index) {
                indices.append(index)
            }
            return indices
        }
    }

    /// Restore Selection: the saved marks that are still shown become the selection (a pass
    /// over bits in the model).
    internal func restore() {
        source.restoreSelection()
    }

    /// Selects or unselects everything that is like the item under the cursor.
    ///
    /// The same extension is asked of files only; the same folder matters where a list gathers
    /// entries of several folders (a branch view, a search result).
    internal func similar(to similarity: Similarity, as cursor: FileItem, select: Bool) {
        let model = source
        @Sendable
        func same(_ first: String, _ second: String) -> Bool {
            first.caseInsensitiveCompare(second) == .orderedSame
        }
        let folder = similarity == .path ? cursor.url.deletingLastPathComponent().locationKey : ""
        markMatching(model, select ? .add : .remove, timedOut: nil) { item in
            switch similarity {
            case .ext:
                return !item.isFolder && !cursor.isFolder && same(item.ext, cursor.ext)

            case .name:
                return same(item.baseName, cursor.baseName)

            case .nameAndExt:
                return same(item.name, cursor.name)

            case .path:
                return item.url.deletingLastPathComponent().locationKey == folder
            }
        }
    }

    /// Selects or unselects `count` items from the cursor on and moves the cursor past them;
    /// a negative count works upward.
    internal func step(select: Bool, count: Int) {
        let model = source
        guard count != 0, model.rowCount > 0 else {
            return
        }
        // A count beyond the list is the length of the list; the sum cannot overflow then.
        let bounded = max(-model.rowCount, min(count, model.rowCount))
        let last = max(0, min(model.cursor + (bounded > 0 ? bounded - 1 : bounded + 1), model.rowCount - 1))
        model.setSelected(select, rows: min(model.cursor, last)...max(model.cursor, last))
        model.moveCursor(to: bounded > 0 ? last + 1 : last - 1)
    }
}
