import AFMKernel
import AppKit

/// A number that can be read on any thread: the newest request, so the work of an overtaken one
/// can be skipped by the queue it waits in. Guarded by `lock`.
private final class LatestNumber: @unchecked Sendable {
    private let lock = NSLock()
    private var number = 0

    var value: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return number
        }
        set {
            lock.lock()
            number = newValue
            lock.unlock()
        }
    }
}

/// Brings the progress of an index that is built on other threads to the main thread, at most one
/// at a time and not more often than every 50 ms. The threads that build hold this object and not
/// the view, so the view is never released by one of them (it would be taken apart on that thread).
///
/// `scheduled` and `last` are guarded by `lock`; `handler` belongs to the main thread.
private final class ProgressCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = false
    private var last = DispatchTime(uptimeNanoseconds: 0)
    /// Set and called on the main thread.
    var handler: (@MainActor () -> Void)?

    /// Called from any thread.
    func signal() {
        lock.lock()
        let schedule = !scheduled
        scheduled = true
        let wait = max(0, 0.05 - Double(DispatchTime.now().uptimeNanoseconds &- last.uptimeNanoseconds) / 1e9)
        lock.unlock()
        guard schedule else { return }
        // (At most 50 ms: `wait` is what is left of them.)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
            lock.lock()
            scheduled = false
            last = DispatchTime.now()
            lock.unlock()
            // The main queue runs its blocks on the main thread.
            MainActor.assumeIsolated { handler?() }
        }
    }
}

/// The queues the work for one document runs on, so that a read that never returns (a share that
/// stopped answering) holds up that document only, not the next file shown.
private final class DocumentQueues: Sendable {
    /// Row fetches: a newer one replaces an older one that is still waiting.
    let rows = DispatchQueue(label: "viewer.rows", qos: .userInitiated)
    /// Looks for a place or a line, and for the text cursor.
    let lookups = DispatchQueue(label: "viewer.lookups", qos: .userInitiated)
}

/// Shows a `TextDocument` row by row: only the rows on screen (and a page around them) are
/// ever read and laid out, whatever the size of the file. The view itself is used on the main
/// thread only; rows are fetched on its own serial queue and the index of a text is built on a
/// background queue, both through the document, which is thread-safe. A request that was
/// overtaken by a newer one is dropped before it runs, or when it returns.
final class TextPagerView: NSView {
    /// How the cursor keys move (spec 10 › Text modes).
    enum Motion {
        case left, right, up, down, pageUp, pageDown, rowStart, rowEnd, fileStart, fileEnd, wordLeft, wordRight
    }

    private(set) var document: TextDocument?
    /// The selected bytes; what Copy copies.
    private(set) var selection: Range<Int64>?
    /// Called when the position, the selection or the indexing state changed.
    var onStatusChange: () -> Void = {}
    /// Called when the view was resized, so a text wrapped at the window's edge can be cut anew.
    var onResize: () -> Void = {}
    /// Asked for the context menu at a click; nil shows none.
    var contextMenu: () -> NSMenu? = { nil }
    /// Ctrl+wheel: the font is to grow (+1) or shrink (-1).
    var onZoom: (Int) -> Void = { _ in }
    /// The text cursor (spec 10 › Text modes, F6): with it the cursor keys move the cursor and
    /// Shift selects; without it they scroll.
    var showsCaret = true { didSet { needsDisplay = true } }
    /// A found text is shown this many rows below the top (the specification's `SearchGoBack`).
    var searchGoBack = 3
    /// Where the index of a text is built: the gate shared by every pager, or one of a test's.
    internal var indexGate = ViewerWorkGate.indexBuilds

    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular) {
        didSet {
            measureFont()
            lines.removeAll()
            updateAfterGeometryChange()
        }
    }

    private let inset: CGFloat = 5
    private var lineHeight: CGFloat = 15
    private var ascent: CGFloat = 12
    private(set) var characterWidth: CGFloat = 7
    private var topRow = 0
    private var horizontalOffset: CGFloat = 0
    private var widestLine: CGFloat = 0
    private var scrollRemainder: CGFloat = 0
    private var zoomRemainder: CGFloat = 0

    /// The rows that are in memory, a contiguous run from `loadedFirst`.
    private var loaded: [DisplayRow] = []
    private var loadedFirst = 0
    private var lines: [Int: CTLine] = [:]
    private var generation = 0 { didSet { latestRows.value = generation } }
    private let latestRows = LatestNumber()
    /// Stops the fetch of rows that is under way (or waiting on a slow file system) when the
    /// next one is asked for, and when the document is dropped.
    private var fetchRequest: LinkedCancellation?
    private var afterLoad: [(TextPagerView) -> Void] = []
    private var queues = DocumentQueues()
    private let progress = ProgressCoalescer()
    /// The offset of the top row when it was last on screen: where a new layout starts if the
    /// top row is not loaded just now.
    private var knownTopOffset: Int64?

    /// The text cursor: a byte offset and the row it is drawn in (the end of a wrapped row and
    /// the start of the next are the same byte).
    private var caret: (offset: Int64, row: Int)?
    private var anchor: Int64?
    private var preferredX: CGFloat?
    /// The text cursor of the document a new layout replaced, until its row is known in the new one.
    private var caretToRestore: Int64?
    private var restoringCaretIn: TextDocument?

    /// A document that is being indexed and replaces the shown one as soon as the row of
    /// `offset` is known.
    private var pending: (document: TextDocument, offset: Int64, select: Range<Int64>?, keep: Bool)?
    /// Counts the requests to go to a place; only the answer to the last one is used. Fetching
    /// rows has its own count (`generation`), so scrolling does not cancel a search result.
    private var revealGeneration = 0 { didSet { latestReveal.value = revealGeneration } }
    private let latestReveal = LatestNumber()
    /// The place the view was last asked to go to, until it got there: carried over to a
    /// document that replaces the shown one in the meantime, and asked for again when the
    /// index has grown far enough.
    private var outstandingReveal: (offset: Int64, select: Range<Int64>?, rowsAbove: Int, keepingSelection: Bool)?
    private var revealWaitsForIndex = false
    /// The same for the look-up of a place or a line.
    private var revealRequest: LinkedCancellation?

    private let verticalScroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 15, height: 100))
    private let horizontalScroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 100, height: 15))

    override init(frame: NSRect) {
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
    required init?(coder _: NSCoder) { nil }

    deinit {
        document?.cancellation.cancel()
        pending?.document.cancellation.cancel()
        fetchRequest?.flag.cancel()
        revealRequest?.flag.cancel()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    // MARK: Documents

    /// Shows `document` with the row of byte `offset` at the top, optionally with a selection
    /// (a found text). The text's rows are indexed in the background, on all cores with
    /// `parallel`; until the wanted row is known the view keeps what it showed before.
    /// `keepingSelection` is for the same bytes laid out anew: the selection stays.
    func show(
        _ document: TextDocument,
        at offset: Int64 = 0,
        select: Range<Int64>? = nil,
        keepingSelection: Bool = false,
        parallel: Bool
    ) {
        pending?.document.cancellation.cancel()
        // The text shown goes on being read for the new layout only if nothing else is waiting
        // for the cores.
        if let shown = self.document, shown !== document, !shown.isIndexComplete { shown.stopIndexing() }
        pending = (document, offset, select, keepingSelection)
        if document.isIndexComplete {
            adoptPendingIfReady()
            return
        }
        // The threads hold the coalescer and the document, not this view.
        let progress = progress
        // Not more builds at a time than the gate allows: a read that cannot be interrupted keeps
        // its thread, and paging through files on such a volume must not strand one thread per file.
        indexGate.submit(
            cancellation: document.indexCancellation,
            refused: {
                document.record(ViewerError.busy)
                progress.signal()
            },
            {
                document.buildIndex(parallel: parallel) { progress.signal() }
            }
        )
    }

    /// Called on the main thread when the indexing threads have news.
    private func indexProgressed() {
        adoptPendingIfReady()
        rowCountChanged()
    }

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
            reveal(
                offset: carried.offset,
                select: carried.select,
                rowsAbove: carried.rowsAbove,
                keepingSelection: carried.keepingSelection
            )
        } else if top > next.document.content.lowerBound || next.select != nil {
            reveal(
                offset: top,
                select: next.select,
                rowsAbove: next.select == nil ? 0 : searchGoBack,
                keepingSelection: next.select == nil
            )
        } else {
            ensureLoaded()
        }
        restoreCaret()
        onStatusChange()
    }

    /// Finds the row of the text cursor kept across a new layout; asked again as the index grows
    /// when its part of the text is not indexed yet.
    private func restoreCaret() {
        guard let offset = caretToRestore, let document, restoringCaretIn !== document else { return }
        restoringCaretIn = document
        queues.lookups.async { [weak self] in
            let row: Int?
            do { row = try document.row(containing: offset, cancellation: document.cancellation) } catch {
                if !document.cancellation.isCancelled { document.record(error) }
                row = nil
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.restoringCaretIn = nil
                guard self.document === document, self.caretToRestore == offset else { return }
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
    func stopReading() {
        pending?.document.cancellation.cancel()
        document?.cancellation.cancel()
        fetchRequest?.flag.cancel()
        revealRequest?.flag.cancel()
    }

    /// Stops everything and shows nothing.
    func clear() {
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

    /// True while a text's rows are still being found.
    var isIndexing: Bool {
        // A text whose reading was stopped is not being indexed any more.
        pending != nil || !(document.map { $0.isIndexComplete || $0.cancellation.isCancelled } ?? true)
    }

    /// The layout of the text shown, or of the one that is to replace it: what a new layout is
    /// compared with.
    var shownLayout: ViewerLayout? { (pending?.document ?? document)?.layout }

    /// How far the indexing is, 0…1.
    var indexingProgress: Double {
        guard let document = pending?.document ?? document, document.length > 0 else { return 1 }
        return Double(document.indexedThrough) / Double(document.length)
    }

    private func rowCountChanged() {
        if revealWaitsForIndex, let waiting = outstandingReveal {
            reveal(
                offset: waiting.offset,
                select: waiting.select,
                rowsAbove: waiting.rowsAbove,
                keepingSelection: waiting.keepingSelection
            )
        }
        updateScrollers()
        if isVisibleRangeMissing { ensureLoaded() }
        if caretToRestore != nil { restoreCaret() }
        onStatusChange()
    }

    // MARK: Metrics

    private func measureFont() {
        let layout = NSLayoutManager()
        lineHeight = ceil(layout.defaultLineHeight(for: font))
        ascent = ceil(font.ascender)
        characterWidth = max(1, ("0" as NSString).size(withAttributes: [.font: font]).width)
    }

    private var textArea: NSRect {
        NSRect(
            x: 0,
            y: 0,
            width: max(0, bounds.width - verticalScroller.frame.width),
            height: max(0, bounds.height - horizontalScroller.frame.height)
        )
    }

    /// Rows that fit completely.
    private var pageRows: Int { max(1, Int((textArea.height - inset) / lineHeight)) }

    /// How many characters of the fixed-width font fit in a row: where a text is wrapped when
    /// it is wrapped at the window's edge.
    var columnsThatFit: Int { max(20, Int((textArea.width - 2 * inset) / characterWidth)) }

    override func layout() {
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

    override func setFrameSize(_ newSize: NSSize) {
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
        ensureLoaded()
        updateScrollers()
        needsDisplay = true
    }

    // MARK: Loading rows

    private var rowCount: Int { document?.rowCount ?? 0 }

    private func row(_ index: Int) -> DisplayRow? {
        let position = index - loadedFirst
        return position >= 0 && position < loaded.count ? loaded[position] : nil
    }

    private var isVisibleRangeMissing: Bool {
        let last = min(rowCount, topRow + pageRows + 1) - 1
        return last >= topRow && (row(topRow) == nil || row(last) == nil)
    }

    /// Fetches the rows on screen and a page on either side, unless they are there already.
    private func ensureLoaded(force: Bool = false) {
        guard let document else { return }
        guard force || isVisibleRangeMissing else {
            runAfterLoad()
            return
        }
        // A text whose reading was stopped keeps what it shows.
        guard !document.cancellation.isCancelled else { return }
        generation += 1
        let wanted = generation
        let first = max(0, topRow - pageRows)
        let count = pageRows * 3 + 2
        let latest = latestRows
        // The fetch that is overtaken stops reading, even where it waits for a server.
        let request = newRequest(replacing: &fetchRequest, for: document)
        queues.rows.async { [weak self] in
            // Overtaken while it waited (the scroller dragged over a slow server): do not read.
            guard latest.value == wanted else { return }
            let rows: [DisplayRow]
            do {
                rows = try autoreleasepool { try document.rows(from: first, count: count, cancellation: request.flag) }
            } catch {
                if !request.flag.isCancelled { document.record(error) }
                rows = []
            }
            DispatchQueue.main.async {
                guard let self, self.generation == wanted, self.document === document else { return }
                // A fetch that was stopped brought nothing: the rows on screen stay.
                guard !request.flag.isCancelled else { return }
                self.loaded = rows
                self.loadedFirst = first
                // The lines of rows that are still shown are kept: making one costs a typesetting.
                self.lines = self.lines.filter { $0.key >= first && $0.key < first + rows.count }
                if let top = self.row(self.topRow) { self.knownTopOffset = top.range.lowerBound }
                self.needsDisplay = true
                self.updateScrollers()
                self.runAfterLoad()
                self.onStatusChange()
            }
        }
    }

    /// The stop for a request that the next one of its kind replaces, and that ends with `document`.
    private func newRequest(replacing old: inout LinkedCancellation?, for document: TextDocument) -> LinkedCancellation
    {
        old?.flag.cancel()
        let request = LinkedCancellation(document.cancellation)
        old = request
        return request
    }

    private func runAfterLoad() {
        let actions = afterLoad
        afterLoad = []
        for action in actions {
            action(self)
        }
    }

    /// Runs `action` with the pager, its document and a row (of the rows there are), scrolling
    /// to the row and loading it first when necessary.
    private func withRow(_ index: Int, _ action: @escaping (TextPagerView, TextDocument, DisplayRow) -> Void) {
        if let document, let row = row(index) {
            action(self, document, row)
            return
        }
        let before = generation
        scrollToShow(index)
        afterLoad.append { pager in
            if let shown = pager.document, let row = pager.row(index) { action(pager, shown, row) }
        }
        // Scrolling asked for the rows already.
        if generation == before { ensureLoaded() }
    }

    // MARK: Scrolling

    private func clampTopRow() {
        topRow = max(0, min(topRow, rowCount - pageRows))
    }

    private func scroll(toRow row: Int) {
        let before = topRow
        topRow = row
        clampTopRow()
        guard topRow != before else { return }
        ensureLoaded()
        updateScrollers()
        needsDisplay = true
        onStatusChange()
    }

    private func scrollToShow(_ row: Int) {
        if row < topRow {
            scroll(toRow: row)
        } else if row >= topRow + pageRows {
            scroll(toRow: row - pageRows + 1)
        }
    }

    private func scrollHorizontally(to offset: CGFloat) {
        horizontalOffset = max(0, min(offset, max(0, widestLine + 2 * inset - textArea.width)))
        updateScrollers()
        needsDisplay = true
    }

    private func updateScrollers() {
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

    @objc private func scrolledVertically() {
        scrollerMoved(verticalScroller.hitPart)
    }

    /// What a click or drag on `part` of the vertical scroller does: a page up or down, or the
    /// place of the knob.
    internal func scrollerMoved(_ part: NSScroller.Part) {
        switch part {
        case .decrementPage: scroll(toRow: topRow - pageRows)
        case .incrementPage: scroll(toRow: topRow + pageRows)
        default: scroll(toRow: Int((verticalScroller.doubleValue * Double(max(0, rowCount - pageRows))).rounded()))
        }
    }

    @objc private func scrolledHorizontally() {
        scrollHorizontally(
            to: CGFloat(horizontalScroller.doubleValue) * max(0, widestLine + 2 * inset - textArea.width)
        )
    }

    override func scrollWheel(with event: NSEvent) {
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

    // MARK: Position

    /// The byte offset of the row at the top: what stays in place when the text is laid out anew.
    var topOffset: Int64 { row(topRow)?.range.lowerBound ?? knownTopOffset ?? document?.content.lowerBound ?? 0 }

    /// The end of the last visible row as a percentage of the file (spec 10 › Position and
    /// zoom item).
    var percent: Double {
        guard let document, document.length > 0 else { return 100 }
        let last = min(rowCount, topRow + pageRows) - 1
        guard let row = row(last) else {
            return rowCount > 0 ? Double(min(rowCount, topRow + pageRows)) / Double(rowCount) * 100 : 100
        }
        return min(100, Double(row.range.upperBound) / Double(document.length) * 100)
    }

    /// The line and the offset the status line names: those of the text cursor, else of the top row.
    var position: (line: Int, offset: Int64)? {
        if let caret, let row = row(caret.row) { return (row.line, caret.offset) }
        return row(topRow).map { ($0.line, $0.range.lowerBound) }
    }

    /// Where the next search starts: behind the start of the selection (the last hit), else at
    /// the text cursor, else at the top of the view. Backwards it is the place to end before.
    func searchStart(backwards: Bool) -> Int64 {
        let unit = Int64(document?.encoding.unitSize ?? 1)
        if let selection { return backwards ? selection.lowerBound : selection.lowerBound + unit }
        return caret?.offset ?? topOffset
    }

    /// Scrolls to the row that holds a byte offset; the row is looked up in the background.
    func reveal(offset: Int64, select: Range<Int64>? = nil, rowsAbove: Int = 0, keepingSelection: Bool = false) {
        guard let document else { return }
        revealGeneration += 1
        let wanted = revealGeneration
        outstandingReveal = (offset, select, rowsAbove, keepingSelection)
        revealWaitsForIndex = false
        // Whether a row that is not found is not there at all, or only not indexed yet.
        let indexWasComplete = document.isIndexComplete
        let latest = latestReveal
        let request = newRequest(replacing: &revealRequest, for: document)
        queues.lookups.async { [weak self] in
            guard latest.value == wanted else { return }
            let row: Int?
            do { row = try document.row(containing: offset, cancellation: request.flag) } catch {
                if !request.flag.isCancelled { document.record(error) }
                row = nil
            }
            DispatchQueue.main.async {
                guard let self, self.revealGeneration == wanted, self.document === document else { return }
                guard let row else {
                    if indexWasComplete {
                        // The offset is beyond the text.
                        self.outstandingReveal = nil
                    } else if document.isIndexComplete {
                        // The index was completed while the row was looked up: ask again, now for good.
                        self.reveal(
                            offset: offset,
                            select: select,
                            rowsAbove: rowsAbove,
                            keepingSelection: keepingSelection
                        )
                    } else {
                        // That part of the text is not indexed yet; `rowCountChanged` asks again.
                        self.revealWaitsForIndex = true
                    }
                    return
                }
                self.outstandingReveal = nil
                if keepingSelection {
                    // The same text laid out anew: only the place changes.
                } else if let select {
                    self.caretToRestore = nil
                    self.selection = select
                    self.caret = (select.lowerBound, row)
                    self.anchor = select.upperBound
                } else {
                    self.caretToRestore = nil
                    self.selection = nil
                    self.caret = self.showsCaret ? (offset, row) : nil
                    self.anchor = nil
                }
                self.topRow = row - rowsAbove
                self.clampTopRow()
                self.ensureLoaded(force: true)
                self.updateScrollers()
                self.needsDisplay = true
                self.onStatusChange()
            }
        }
    }

    func scroll(toPercent percent: Double) {
        guard let document else { return }
        let fraction = min(1, max(0, percent / 100))
        if document.isIndexComplete {
            scroll(toRow: Int((Double(rowCount) * fraction).rounded(.down)))
        } else {
            reveal(offset: document.content.lowerBound + Int64(Double(document.content.count) * fraction))
        }
    }

    /// Scrolls to a line (counted from 1); false is handed to `completion` when there is none.
    func scroll(toLine line: Int, completion: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }) {
        guard let document else { return }
        revealGeneration += 1
        let wanted = revealGeneration
        outstandingReveal = nil
        let latest = latestReveal
        let request = newRequest(replacing: &revealRequest, for: document)
        queues.lookups.async { [weak self] in
            guard latest.value == wanted else { return }
            let row: Int?
            do { row = try document.row(ofLine: line, cancellation: request.flag) } catch {
                if !request.flag.isCancelled { document.record(error) }
                row = nil
            }
            DispatchQueue.main.async {
                guard let self, self.revealGeneration == wanted, self.document === document else { return }
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

    // MARK: Selection

    func selectAll() {
        guard let document else { return }
        selection = document.content.isEmpty ? nil : document.content
        anchor = document.content.lowerBound
        needsDisplay = true
        onStatusChange()
    }

    func clearSelection() {
        selection = nil
        needsDisplay = true
        onStatusChange()
    }

    private func setCaret(_ offset: Int64, row: Int, extending: Bool) {
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

    // MARK: Keys

    /// Moves the text cursor, or scrolls when it is not shown (spec 10 › Text modes).
    func perform(_ motion: Motion, extending: Bool = false) {
        guard let document, rowCount > 0 else { return }
        guard showsCaret else {
            switch motion {
            case .up: scroll(toRow: topRow - 1)
            case .down: scroll(toRow: topRow + 1)
            case .pageUp: scroll(toRow: topRow - pageRows)
            case .pageDown: scroll(toRow: topRow + pageRows)
            case .rowStart, .fileStart: scroll(toRow: 0)
            case .rowEnd, .fileEnd: scroll(toRow: rowCount)
            case .left: scrollHorizontally(to: horizontalOffset - characterWidth * 4)
            case .right: scrollHorizontally(to: horizontalOffset + characterWidth * 4)
            case .wordLeft: scrollHorizontally(to: horizontalOffset - textArea.width / 2)
            case .wordRight: scrollHorizontally(to: horizontalOffset + textArea.width / 2)
            }
            return
        }
        let current = caret ?? (row(topRow)?.range.lowerBound ?? document.content.lowerBound, topRow)
        if motion != .up, motion != .down, motion != .pageUp, motion != .pageDown { preferredX = nil }
        switch motion {
        case .fileStart:
            withRow(0) { pager, _, row in pager.setCaret(row.range.lowerBound, row: 0, extending: extending) }

        case .fileEnd:
            let last = rowCount - 1
            withRow(last) { pager, _, row in pager.setCaret(row.contentEnd, row: last, extending: extending) }

        case .up, .down, .pageUp, .pageDown:
            let step = motion == .up ? -1 : motion == .down ? 1 : motion == .pageUp ? -pageRows : pageRows
            let target = max(0, min(rowCount - 1, current.row + step))
            withRow(current.row) { pager, document, from in
                let x = pager.preferredX ?? pager.xPosition(in: from, of: current.offset, document)
                pager.preferredX = x
                pager.withRow(target) { pager, document, row in
                    pager.setCaret(
                        document.byteOffset(in: row, at: pager.textIndex(in: row, atX: x)),
                        row: target,
                        extending: extending
                    )
                }
            }

        case .rowStart:
            withRow(current.row) { pager, _, row in
                pager.setCaret(row.range.lowerBound, row: row.index, extending: extending)
            }

        case .rowEnd:
            withRow(current.row) { pager, _, row in pager.setCaret(row.contentEnd, row: row.index, extending: extending)
            }

        case .left, .wordLeft:
            withRow(current.row) { pager, document, row in
                if current.offset <= row.range.lowerBound {
                    guard row.index > 0 else { return }
                    pager.withRow(row.index - 1) { pager, document, previous in
                        // The end of a wrapped row is the same byte as the start of the next:
                        // step onto its last character instead.
                        let end =
                            previous.contentEnd < current.offset
                            ? previous.contentEnd
                            : document.byteOffset(in: previous, at: max(0, previous.text.utf16.count - 1))
                        pager.setCaret(end, row: previous.index, extending: extending)
                    }
                    return
                }
                var index = min(document.textIndex(in: row, of: current.offset), row.text.utf16.count)
                if motion == .wordLeft, document.layout != .hex {
                    index = Self.wordStart(before: index, in: row.text)
                } else if document.layout == .hex {
                    pager.setCaret(current.offset - 1, row: row.index, extending: extending)
                    return
                } else {
                    repeat {
                        index -= 1
                    } while index > 0
                        && document.byteOffset(in: row, at: index) == document.byteOffset(in: row, at: index - 1)
                }
                pager.setCaret(document.byteOffset(in: row, at: max(0, index)), row: row.index, extending: extending)
            }

        case .right, .wordRight:
            withRow(current.row) { pager, document, row in
                if current.offset >= row.contentEnd {
                    guard row.index + 1 < pager.rowCount else { return }
                    pager.withRow(row.index + 1) { pager, _, next in
                        pager.setCaret(next.range.lowerBound, row: next.index, extending: extending)
                    }
                    return
                }
                if document.layout == .hex {
                    pager.setCaret(current.offset + 1, row: row.index, extending: extending)
                    return
                }
                let count = row.text.utf16.count
                var index = document.textIndex(in: row, of: current.offset)
                if motion == .wordRight {
                    index = Self.wordStart(after: index, in: row.text)
                } else {
                    repeat {
                        index += 1
                    } while index < count && document.byteOffset(in: row, at: index) == current.offset
                }
                pager.setCaret(document.byteOffset(in: row, at: index), row: row.index, extending: extending)
            }
        }
    }

    private static func isWordUnit(_ unit: UInt16) -> Bool {
        Unicode.Scalar(unit).map { CharacterSet.alphanumerics.contains($0) || $0 == "_" } ?? true
    }

    static func wordStart(after index: Int, in text: String) -> Int {
        let units = Array(text.utf16)
        var index = index
        while index < units.count, isWordUnit(units[index]) { index += 1 }
        while index < units.count, !isWordUnit(units[index]) { index += 1 }
        return index
    }

    static func wordStart(before index: Int, in text: String) -> Int {
        let units = Array(text.utf16)
        var index = min(index, units.count)
        while index > 0, !isWordUnit(units[index - 1]) { index -= 1 }
        while index > 0, isWordUnit(units[index - 1]) { index -= 1 }
        return index
    }

    /// The word around a place in a text, for a double click.
    static func wordRange(around index: Int, in text: String) -> Range<Int> {
        let units = Array(text.utf16)
        guard index < units.count, isWordUnit(units[index]) else { return index..<min(units.count, index + 1) }
        var lower = index
        var upper = index
        while lower > 0, isWordUnit(units[lower - 1]) { lower -= 1 }
        while upper < units.count, isWordUnit(units[upper]) { upper += 1 }
        return lower..<upper
    }

    // MARK: Mouse

    private func line(for row: DisplayRow) -> CTLine {
        if let line = lines[row.index] { return line }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: row.text, attributes: [.font: font, .foregroundColor: NSColor.textColor])
        )
        lines[row.index] = line
        return line
    }

    private func textIndex(in row: DisplayRow, atX x: CGFloat) -> Int {
        max(0, min(row.text.utf16.count, CTLineGetStringIndexForPosition(line(for: row), CGPoint(x: x, y: 0))))
    }

    private func xPosition(in row: DisplayRow, of offset: Int64, _ document: TextDocument) -> CGFloat {
        let index =
            offset >= row.contentEnd && document.layout != .hex
            ? row.text.utf16.count : document.textIndex(in: row, of: offset)
        return CTLineGetOffsetForStringIndex(line(for: row), min(index, row.text.utf16.count), nil)
    }

    /// The row and the place in its text under a point of the view.
    private func hit(_ point: NSPoint) -> (row: DisplayRow, index: Int)? {
        let number = max(topRow, min(rowCount - 1, topRow + Int(floor((point.y - inset) / lineHeight))))
        guard let row = row(number) else { return nil }
        return (row, textIndex(in: row, atX: point.x - inset + horizontalOffset))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let document, let hit = hit(convert(event.locationInWindow, from: nil)) else { return }
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

    override func mouseDragged(with event: NSEvent) {
        guard let document else { return }
        let point = convert(event.locationInWindow, from: nil)
        if point.y < 0 { scroll(toRow: topRow - 1) }
        if point.y > textArea.height { scroll(toRow: topRow + 1) }
        guard let hit = hit(NSPoint(x: point.x, y: max(0, min(point.y, textArea.height - 1)))) else { return }
        setCaret(document.byteOffset(in: hit.row, at: hit.index), row: hit.row.index, extending: true)
    }

    override func menu(for _: NSEvent) -> NSMenu? { contextMenu() }

    /// The text of the row under a point of the window, and the place in it: for the context
    /// menu, which looks for a link there (spec 10 › Context menu rules).
    func text(at windowPoint: NSPoint) -> (text: String, index: Int)? {
        hit(convert(windowPoint, from: nil)).map { ($0.row.text, $0.index) }
    }

    // MARK: Drawing

    override func draw(_: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard let document, let context = NSGraphicsContext.current?.cgContext else { return }
        let area = textArea
        context.saveGState()
        context.clip(to: area)
        var widest: CGFloat = 0
        let originX = inset - horizontalOffset
        let last = min(rowCount, topRow + pageRows + 1)
        var number = topRow
        while number < last {
            defer { number += 1 }
            guard let row = row(number) else { continue }
            let y = inset + CGFloat(number - topRow) * lineHeight
            let line = line(for: row)
            widest = max(widest, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
            if let selection {
                (window?.firstResponder === self
                    ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor)
                    .setFill()
                for range in document.textRanges(in: row, for: selection) {
                    let from = CTLineGetOffsetForStringIndex(line, range.lowerBound, nil)
                    let to = CTLineGetOffsetForStringIndex(line, range.upperBound, nil)
                    // A run that reads right to left has its end left of its start.
                    NSRect(x: originX + min(from, to), y: y, width: max(2, abs(to - from)), height: lineHeight).fill()
                }
                // A selected line end shows as a little more than the text.
                if selection.contains(row.contentEnd), row.contentEnd < row.range.upperBound, document.layout != .hex {
                    let end = CTLineGetOffsetForStringIndex(line, row.text.utf16.count, nil)
                    NSRect(x: originX + end, y: y, width: characterWidth / 2, height: lineHeight).fill()
                }
            }
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: originX, y: y + ascent)
            CTLineDraw(line, context)
            if showsCaret, let caret, caret.row == number {
                NSColor.textColor.setFill()
                NSRect(x: originX + xPosition(in: row, of: caret.offset, document), y: y, width: 1, height: lineHeight)
                    .fill()
            }
        }
        context.restoreGState()
        if abs(widest - widestLine) > 0.5 {
            widestLine = widest
            DispatchQueue.main.async { [weak self] in self?.updateScrollers() }
        }
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }
}
