import AFMKernel
import AppKit

/// Shows a `TextDocument` row by row: only the rows on screen (and a page around them) are
/// ever read and laid out, whatever the size of the file.
///
/// The view itself is used on the main thread only; rows are fetched on its own serial queue and
/// the index of a text is built on a background queue, both through the document, which is
/// thread-safe. A request that was overtaken by a newer one is dropped before it runs, or when it
/// returns.
///
/// The state below is the view's; its extensions (rows, scrolling, places, keys, mouse, drawing)
/// share it, on the main thread.
internal final class TextPagerView: NSView {
    /// A place the view is to go to: the row of `offset`, `rowsAbove` rows below the top.
    internal struct RevealTarget {
        /// The byte whose row is shown.
        internal var offset: Int64
        /// What is selected there (a found text); nil puts the text cursor at `offset`.
        internal var select: Range<Int64>?
        /// How many rows stay above the row of `offset`.
        internal var rowsAbove: Int
        /// The same text laid out anew: the selection and the text cursor stay as they are.
        internal var keepingSelection: Bool
    }

    /// A document that is being indexed and replaces the shown one as soon as the row of
    /// `offset` is known.
    internal struct PendingDocument {
        /// The text, being indexed.
        internal var document: TextDocument
        /// The byte whose row goes to the top.
        internal var offset: Int64
        /// What is selected there (a found text).
        internal var select: Range<Int64>?
        /// The same bytes laid out anew: what the user sees and is doing stays.
        internal var keep: Bool
    }

    /// The text shown, nil before one is and after `clear()`; set by `show` and `clear` only.
    internal var document: TextDocument?
    /// The selected bytes; what Copy copies.
    internal var selection: Range<Int64>?
    /// Called when the position, the selection or the indexing state changed.
    internal var onStatusChange: () -> Void = {
        // Nothing shows the status until the pane sets this.
    }
    /// Called when the view was resized, so a text wrapped at the window's edge can be cut anew.
    internal var onResize: () -> Void = {
        // Nothing is cut anew until the pane sets this.
    }
    /// Asked for the context menu at a click; nil shows none.
    internal var contextMenu: () -> NSMenu? = { nil }
    /// Ctrl+wheel: the font is to grow (+1) or shrink (-1).
    internal var onZoom: (Int) -> Void = { _ in
        // The font stays until the pane sets this.
    }
    /// The text cursor (spec 10 › Text modes, F6): with it the cursor keys move the cursor and
    /// Shift selects; without it they scroll.
    internal var showsCaret = true { didSet { needsDisplay = true } }
    /// A found text is shown this many rows below the top (the specification's `SearchGoBack`).
    internal var searchGoBack = 3
    /// Where the index of a text is built: the gate shared by every pager, or one of a test's.
    internal var indexGate = ViewerWorkGate.indexBuilds

    /// The font the rows are drawn in; changing it lays out what is shown anew.
    internal var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular) {
        didSet {
            measureFont()
            lines.removeAll()
            updateAfterGeometryChange()
        }
    }

    /// The margin around the text, in points.
    internal let inset: CGFloat = 5
    /// The height of a row in the font, in points.
    internal private(set) var lineHeight: CGFloat = 15
    /// The height of the font above its baseline, in points.
    internal private(set) var ascent: CGFloat = 12
    /// The width of a digit of the font, in points: what the cursor keys scroll by without a text cursor.
    internal private(set) var characterWidth: CGFloat = 7
    /// The row at the top of the view.
    internal var topRow = 0
    /// How far the rows are scrolled to the left, in points.
    internal var horizontalOffset: CGFloat = 0
    /// The width of the widest row drawn last, in points: how far the text can be scrolled sideways.
    internal var widestLine: CGFloat = 0
    /// What the wheel scrolled by that is not a whole row yet, in points.
    internal var scrollRemainder: CGFloat = 0
    /// What Ctrl+wheel turned by that is not a whole step of the font yet.
    internal var zoomRemainder: CGFloat = 0

    /// The rows that are in memory, a contiguous run from `loadedFirst`.
    internal var loaded: [DisplayRow] = []
    /// The row number of the first of `loaded`.
    internal var loadedFirst = 0
    /// The typeset rows by row number; made when a row is first drawn or measured.
    internal var lines: [Int: CTLine] = [:]
    /// Counts the fetches of rows; only the answer to the last one is used.
    internal var generation = 0 { didSet { latestRows.value = generation } }
    /// The count of fetches, readable on the queue that fetches.
    internal let latestRows = LatestNumber()
    /// Stops the fetch of rows that is under way (or waiting on a slow file system) when the
    /// next one is asked for, and when the document is dropped.
    internal var fetchRequest: LinkedCancellation?
    /// What waits for the rows being fetched; run when they arrive.
    internal var afterLoad: [(TextPagerView) -> Void] = []
    /// The queues of the document shown (tests wait for what was handed to them).
    internal var queues = DocumentQueues()
    /// Brings the news of the threads that index to the main thread.
    internal let progress = ProgressCoalescer()
    /// The offset of the top row when it was last on screen: where a new layout starts if the
    /// top row is not loaded just now.
    internal var knownTopOffset: Int64?

    /// The text cursor: a byte offset and the row it is drawn in (the end of a wrapped row and
    /// the start of the next are the same byte).
    internal var caret: (offset: Int64, row: Int)?
    /// Where a selection made with Shift or the mouse started.
    internal var anchor: Int64?
    /// The place in the row the text cursor keeps while it moves up and down, in points.
    internal var preferredX: CGFloat?
    /// The text cursor of the document a new layout replaced, until its row is known in the new one.
    internal var caretToRestore: Int64?
    /// The document whose row of `caretToRestore` is being looked up.
    internal var restoringCaretIn: TextDocument?

    /// The document that replaces the shown one once its wanted row is indexed.
    internal var pending: PendingDocument?
    /// Counts the requests to go to a place; only the answer to the last one is used.
    ///
    /// Fetching rows has its own count (`generation`), so scrolling does not cancel a search
    /// result.
    internal var revealGeneration = 0 { didSet { latestReveal.value = revealGeneration } }
    /// The count of requests to go to a place, readable on the queue that looks the place up.
    internal let latestReveal = LatestNumber()
    /// The place the view was last asked to go to, until it got there: carried over to a
    /// document that replaces the shown one in the meantime, and asked for again when the
    /// index has grown far enough.
    internal var outstandingReveal: RevealTarget?
    /// Whether `outstandingReveal` waits for the index to reach its part of the text.
    internal var revealWaitsForIndex = false
    /// The same for the look-up of a place or a line.
    internal var revealRequest: LinkedCancellation?

    /// The scroller at the right edge: the rows.
    internal let verticalScroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 15, height: 100))
    /// The scroller at the bottom edge: the width of the rows.
    internal let horizontalScroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 100, height: 15))

    /// Rows are counted from the top.
    override internal var isFlipped: Bool { true }
    /// The view takes the keyboard (the cursor keys move in the text).
    override internal var acceptsFirstResponder: Bool { true }
    /// The view fills its bounds with the text background.
    override internal var isOpaque: Bool { true }

    /// True while a text's rows are still being found.
    internal var isIndexing: Bool {
        // A text whose reading was stopped is not being indexed any more.
        pending != nil || !(document.map { $0.isIndexComplete || $0.cancellation.isCancelled } ?? true)
    }

    /// The layout of the text shown, or of the one that is to replace it: what a new layout is
    /// compared with.
    internal var shownLayout: ViewerLayout? { (pending?.document ?? document)?.layout }

    /// How far the indexing is, 0…1.
    internal var indexingProgress: Double {
        guard let indexed = pending?.document ?? document, indexed.length > 0 else {
            return 1
        }
        return Double(indexed.indexedThrough) / Double(indexed.length)
    }

    /// The part of the view the rows are drawn in: all of it but the scrollers.
    internal var textArea: NSRect {
        NSRect(
            x: 0,
            y: 0,
            width: max(0, bounds.width - verticalScroller.frame.width),
            height: max(0, bounds.height - horizontalScroller.frame.height)
        )
    }

    /// Rows that fit completely.
    internal var pageRows: Int { max(1, Int((textArea.height - inset) / lineHeight)) }

    /// How many characters of the fixed-width font fit in a row: where a text is wrapped when
    /// it is wrapped at the window's edge.
    internal var columnsThatFit: Int { max(20, Int((textArea.width - 2 * inset) / characterWidth)) }

    /// The rows of the text shown, as far as they are indexed; 0 without one.
    internal var rowCount: Int { document?.rowCount ?? 0 }

    // MARK: Position

    /// The byte offset of the row at the top: what stays in place when the text is laid out anew.
    internal var topOffset: Int64 {
        row(topRow)?.range.lowerBound ?? knownTopOffset ?? document?.content.lowerBound ?? 0
    }

    /// The end of the last visible row as a percentage of the file (spec 10 › Position and
    /// zoom item).
    internal var percent: Double {
        guard let document, document.length > 0 else {
            return 100
        }
        let last = min(rowCount, topRow + pageRows) - 1
        guard let row = row(last) else {
            return rowCount > 0 ? Double(min(rowCount, topRow + pageRows)) / Double(rowCount) * 100 : 100
        }
        return min(100, Double(row.range.upperBound) / Double(document.length) * 100)
    }

    /// The line and the offset the status line names: those of the text cursor, else of the top row.
    internal var position: (line: Int, offset: Int64)? {
        if let caret, let row = row(caret.row) {
            return (row.line, caret.offset)
        }
        return row(topRow).map { ($0.line, $0.range.lowerBound) }
    }

    /// An empty pager with its two scrollers.
    override internal init(frame: NSRect) {
        super.init(frame: frame)
        for scroller in [verticalScroller, horizontalScroller] {
            scroller.scrollerStyle = .legacy
            scroller.target = self
            scroller.isEnabled = true
            addSubview(scroller)
        }
        verticalScroller.action = #selector(scrolledVertically)
        horizontalScroller.action = #selector(scrolledHorizontally)
        measureFont()
        progress.handler = { [weak self] in self?.indexProgressed() }
    }

    /// Made in code only: an archive gives none.
    internal required init?(coder _: NSCoder) { nil }

    // MARK: Metrics

    private func measureFont() {
        let layout = NSLayoutManager()
        lineHeight = ceil(layout.defaultLineHeight(for: font))
        ascent = ceil(font.ascender)
        characterWidth = max(1, "0".size(withAttributes: [.font: font]).width)
    }

    /// Puts the scrollers at the edges.
    override internal func layout() {
        super.layout()
        placeScrollers()
    }

    private func placeScrollers() {
        let thickness = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        verticalScroller.frame = NSRect(
            x: bounds.width - thickness,
            y: 0,
            width: thickness,
            height: max(0, bounds.height - thickness)
        )
        horizontalScroller.frame = NSRect(
            x: 0,
            y: bounds.height - thickness,
            width: max(0, bounds.width - thickness),
            height: thickness
        )
    }

    /// A new size moves the scrollers, keeps the top row in range and tells `onResize`.
    override internal func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        placeScrollers()
        if changed {
            updateAfterGeometryChange()
            onResize()
        }
    }

    private func updateAfterGeometryChange() {
        clampTopRow()
        ensureLoaded(force: false)
        updateScrollers()
        needsDisplay = true
    }

    // MARK: Events

    /// The wheel scrolls; with Ctrl it zooms the font.
    override internal func scrollWheel(with event: NSEvent) { scroll(byWheel: event) }

    /// A click puts the text cursor there (Shift selects to it); a double click selects a word, a triple
    /// click a row.
    override internal func mouseDown(with event: NSEvent) { click(event) }

    /// A drag selects; above or below the text it scrolls a row at a time.
    override internal func mouseDragged(with event: NSEvent) { drag(event) }

    /// The menu `contextMenu` gives.
    override internal func menu(for _: NSEvent) -> NSMenu? { contextMenu() }

    /// Draws the rows that are in memory, with the selection and the text cursor.
    override internal func draw(_: NSRect) { drawRows() }

    /// Shows that the view has the keyboard: the selection is drawn in the active colour.
    override internal func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    /// Shows that the view lost the keyboard: the selection is drawn in the inactive colour.
    override internal func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    deinit {
        document?.cancellation.cancel()
        pending?.document.cancellation.cancel()
        fetchRequest?.flag.cancel()
        revealRequest?.flag.cancel()
    }
}
