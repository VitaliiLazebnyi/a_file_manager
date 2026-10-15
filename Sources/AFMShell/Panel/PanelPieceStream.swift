import AFMKernel
import Foundation

/// One reading of `PanelLoading.start`, on its background thread: it gathers the batches the
/// file system delivers, sorts them in the order the panel wants (which may change under way)
/// and sends the whole list so far to the main thread as a piece, now and then; the end of
/// the reading follows the last piece.
///
/// Made and used on the reading thread only; what crosses to the main thread are the pieces
/// (values) and the receivers, which stay in their box and are let go of on the main thread.
internal final class PanelPieceStream {
    /// Who hears of the pieces and of the end, on the main thread.
    internal struct Receivers {
        /// Called with each piece.
        internal let onPiece: (PanelLoading.Piece) -> Void
        /// Called once at the end, with the error of a reading that failed.
        internal let onEnd: (any Error?) -> Void
    }

    private let source: PanelLoading.Source
    private let order: PanelLoading.OrderBox
    private let cancellation: CancellationFlag
    private let receivers: MainOwned<Receivers>
    /// What has been sorted so far.
    private var sorted: SortedFileList
    /// What has arrived and is not sorted yet.
    private var pending: [FileItem] = []
    /// The first batch, which tells the folder and its surroundings.
    private var header: PanelLoader.Batch?
    private var sentFirst = false
    private var lastSent = Date()
    /// The pause until the next piece.
    private var interval = PanelLoading.firstPieceDelay

    /// A reading of `source` in the order `order` holds, for `receivers`.
    internal init(
        source: PanelLoading.Source,
        order: PanelLoading.OrderBox,
        cancellation: CancellationFlag,
        receivers: MainOwned<Receivers>
    ) {
        self.source = source
        self.order = order
        self.cancellation = cancellation
        self.receivers = receivers
        sorted = SortedFileList(order: order.value)
    }

    /// Reads to the end.
    ///
    /// A read that failed half-way still delivers what it had; only a listing that arrived whole
    /// and without an error is remembered.
    internal func run() {
        let (started, ticket) = (Date(), source.cache.startReading())
        var failure: (any Error)?
        do {
            try PanelLoader.stream(
                source.location,
                showHidden: source.showHidden,
                fileSystems: source.fileSystems,
                cancellation: cancellation
            ) { batch in receive(batch) }
        } catch {
            failure = error
        }
        let readTime = Date().timeIntervalSince(started)
        // A reading that ends without an error always had its first batch (an empty folder
        // gives an empty one); only a cancelled one has none.
        if !cancellation.isCancelled, failure == nil || sentFirst, let header {
            let piece = send(header, isLast: true)
            if failure == nil {
                source.cache.store(
                    piece.listing,
                    sortedBy: piece.order,
                    showHidden: source.showHidden,
                    readTime: readTime,
                    since: ticket
                )
            }
        }
        MainLoop.perform { [receivers, failure] in receivers.take()?.onEnd(failure) }
    }

    /// A batch has arrived: a piece goes out when the pause since the last one is over.
    ///
    /// Returns false once the reading is to stop.
    private func receive(_ batch: PanelLoader.Batch) -> Bool {
        // The first batch tells the folder and its surroundings.
        let first = header ?? batch
        header = first
        pending += batch.listing.items
        if Date().timeIntervalSince(lastSent) > interval {
            send(first, isLast: false)
        }
        return !cancellation.isCancelled
    }

    /// Sends what has arrived, below `header` (the first batch), as a piece.
    @discardableResult
    private func send(_ header: PanelLoader.Batch, isLast: Bool) -> PanelLoading.Piece {
        // The list was put in another order meanwhile: what has arrived is sorted anew here,
        // in the background, so the panel never has to.
        let wanted = order.value
        if wanted != sorted.order {
            var fresh = SortedFileList(order: wanted)
            fresh.add(sorted.items)
            sorted = fresh
        }
        if !sentFirst, !isLast, pending.count > PanelLoading.firstPieceLimit {
            // Only a part goes into the first piece; the rest waits for the second.
            sorted.add(Array(pending.prefix(PanelLoading.firstPieceLimit)))
            pending.removeFirst(PanelLoading.firstPieceLimit)
        } else {
            sorted.add(pending)
            pending = []
        }
        let piece = PanelLoading.Piece(
            listing: header.listing.with(items: sorted.items),
            focus: header.focus,
            order: sorted.order,
            isFirst: !sentFirst,
            isLast: isLast
        )
        interval = sentFirst ? interval * PanelLoading.intervalGrowth : PanelLoading.secondPieceInterval
        sentFirst = true
        lastSent = Date()
        MainLoop.perform { [receivers, cancellation] in
            if !cancellation.isCancelled {
                receivers.held?.onPiece(piece)
            }
        }
        return piece
    }

    deinit {
        // Nothing to release.
    }
}
