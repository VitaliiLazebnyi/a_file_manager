import AFMKernel
import AppKit

/// The Brief and Thumbnails views to the accessibility interface (VoiceOver, the UI tests): a
/// list like the table of the Full view (`PanelViewController.makeListArea`), whose children are
/// the cells, each named as the list writes it, the cursor's cell the selected one.
///
/// The view has no subview per entry, so it makes an element for each cell on screen, and only
/// for those: a folder of a hundred thousand entries costs no more than one of a hundred. The
/// elements are made again when the list is drawn and what they show has changed.
extension FileGridView {
    /// What the elements of the cells show: which cells, laid out how, with the cursor where.
    internal struct AccessibleCells: Equatable {
        /// The cells on screen.
        internal let rows: Range<Int>
        /// The cursor's row.
        internal let cursor: Int
        /// Where the cells are.
        internal let geometry: GridGeometry
    }

    /// Makes the elements of the cells on screen again, unless they show what they showed.
    internal func updateAccessibilityCells(of model: PanelModel) {
        let shown = AccessibleCells(rows: visibleRows, cursor: model.cursor, geometry: geometry)
        guard shown != accessibleCells else {
            return
        }
        accessibleCells = shown
        let cells = shown.rows.map { row in
            let cell = NSAccessibilityElement()
            cell.setAccessibilityRole(.cell)
            cell.setAccessibilityLabel(GridCellPainter.caption(for: model.item(atRow: row)))
            // In the list's own space, so that the element follows the window when it moves; that
            // space counts from the bottom, as if the list were not drawn from the top down.
            let frame = geometry.frame(of: row)
            cell.setAccessibilityFrameInParentSpace(
                NSRect(x: frame.minX, y: bounds.height - frame.maxY, width: frame.width, height: frame.height)
            )
            cell.setAccessibilitySelected(row == model.cursor)
            cell.setAccessibilityParent(self)
            return cell
        }
        cellElements = Dictionary(uniqueKeysWithValues: zip(shown.rows, cells))
        setAccessibilityChildren(cells)
        setAccessibilitySelectedChildren(cells.filter { $0.isAccessibilitySelected() })
    }
}
