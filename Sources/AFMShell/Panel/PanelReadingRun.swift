import AFMKernel
import Foundation

/// One reading of a location into a tab, piece by piece (`PanelViewController.load`): it takes
/// the pieces the reading sends, in the order they come, and ends the reading.
///
/// A directory that does not answer for a while is entered anyway: the panel shows its path,
/// an empty list and a busy indicator, and fills up as the entries arrive. Should the reading
/// fail, the panel goes back to where it was.
///
/// Main thread only. The run holds the panel weakly: a panel that goes away while its reading
/// is out is not kept alive by it.
@MainActor
internal final class PanelReadingRun {
    /// What the run reads, and for whom.
    internal struct Request {
        /// The location to read.
        internal let location: URL
        /// The tab that shows it.
        internal let tab: PanelModel
        /// Where the cursor goes; nil for where the listing puts it.
        internal let focus: String?
        /// How the visit goes into the tab's history.
        internal let history: PanelModel.HistoryEffect
        /// Whether a failure is reported to the user.
        internal let reportsFailure: Bool
    }

    private weak var panel: PanelViewController?
    private let request: Request
    private let load: PanelLoad
    private let id: ObjectIdentifier
    /// The folder the tab showed when the reading began.
    private let previousDirectory: URL
    /// Nothing has arrived yet: the folder is entered empty when that goes on for long.
    private var nothingArrivedYet = true
    /// Pieces and the end are taken in the order they come.
    ///
    /// A piece that has to be sorted first, in the background, holds back whatever comes after it.
    private var behind: [() -> Void] = []
    private var isHolding = false

    /// Whether this is still the tab's reading: one that was overtaken by a newer one is dropped.
    private var isCurrent: Bool { panel?.loads[id] === load }

    /// A run of `request` for `panel`, which is `load` of the tab.
    internal init(_ request: Request, of panel: PanelViewController, load: PanelLoad) {
        self.panel = panel
        self.request = request
        self.load = load
        id = ObjectIdentifier(request.tab)
        previousDirectory = request.tab.directory
    }

    /// Enters the folder empty, after `PanelLoading.emptyOpenDelay`, when nothing has arrived
    /// by then.
    internal func enterEmptyIfSlow() {
        MainLoop.after(PanelLoading.emptyOpenDelay) { [weak self] in self?.enterEmpty() }
    }

    /// A piece arrived (main thread).
    internal func receive(_ piece: PanelLoading.Piece) {
        inOrder { [self] in take(piece) }
    }

    /// The reading ended, with `error` when it failed (main thread).
    internal func finish(_ error: (any Error)?) {
        inOrder { [self] in end(error) }
    }

    /// Enters the folder empty, unless something arrived meanwhile or the reading is over.
    private func enterEmpty() {
        guard let panel, nothingArrivedYet, isCurrent,
            let provider = try? panel.kernel.fileSystems.provider(for: request.location)
        else {
            return
        }
        let tab = request.tab
        if tab.isOpening, let before = panel.openedFrom[id] {
            // The tab was entered already, by a reading this one overtook. That visit showed
            // nothing and is taken back first, so it does not stay in the history as a
            // place the panel has been; the way back remains the one it was.
            panel.restore(tab, to: before, quickFilter: panel.openedFromFilter[id])
        } else {
            panel.openedFrom[id] = tab.snapshot()
            panel.openedFromFilter[id] = panel.quickFilters[id]
        }
        panel.dropQuickFilter(of: tab, unlessIn: request.location)
        tab.open(
            request.location,
            parent: provider.parent(of: request.location),
            root: provider.root(of: request.location),
            history: request.history
        )
    }

    /// Runs `step` now, or after the piece that holds the line.
    private func inOrder(_ step: @escaping () -> Void) {
        if isHolding {
            behind.append(step)
        } else {
            step()
        }
    }

    /// The piece that held the line is taken: what waited behind it goes on.
    private func releaseHeld() {
        while !isHolding, !behind.isEmpty {
            behind.removeFirst()()
        }
    }

    /// Takes a piece into the tab.
    private func take(_ piece: PanelLoading.Piece) {
        guard let panel, isCurrent else {
            return
        }
        let tab = request.tab
        // The reading follows the order of the list; one piece that was made in the order
        // before is skipped, the next one holds the whole list again (and is in the new order).
        load.order.value = tab.wantedSort
        if piece.order != tab.wantedSort, !piece.isFirst, !piece.isLast {
            return
        }
        // The order was changed while this piece was on its way: a long list is put in the
        // new order in the background (the common case, the other direction, is one pass).
        if piece.order != tab.wantedSort, piece.listing.items.count >= PanelViewController.backgroundSortThreshold {
            resortThenTake(piece, to: tab.wantedSort)
            return
        }
        nothingArrivedYet = false
        let isLong = piece.listing.items.count >= PanelViewController.backgroundSortThreshold
        if piece.isFirst {
            showFirst(piece, isLong: isLong, in: panel)
        } else if isLong || tab.listedItems.count >= PanelViewController.backgroundSortThreshold {
            grow(with: piece, in: panel)
        } else {
            tab.extend(to: piece.listing.items, sortedBy: piece.order)
            if piece.isLast {
                tab.finishLoading()
            }
        }
    }

    /// Sorts a long piece into the order `wanted` in the background, then takes it; what comes
    /// after it waits.
    private func resortThenTake(_ piece: PanelLoading.Piece, to wanted: ListOrder) {
        isHolding = true
        // Entries are there, only not in order yet: the folder is not entered empty meanwhile.
        nothingArrivedYet = false
        Background.compute(
            work: { () -> PanelLoading.Piece in
                PanelLoading.Piece(
                    listing: piece.listing.with(
                        items: Sorter.resort(piece.listing.items, from: piece.order, to: wanted)
                    ),
                    focus: piece.focus,
                    order: wanted,
                    isFirst: piece.isFirst,
                    isLast: piece.isLast
                )
            },
            then: { [self] resorted in
                isHolding = false
                take(resorted)
                releaseHeld()
            }
        )
    }

    /// The first piece: the tab is in the folder from its first entries on, not only when the
    /// last has come.
    private func showFirst(_ piece: PanelLoading.Piece, isLong: Bool, in panel: PanelViewController) {
        let tab = request.tab
        panel.dropSnapshot(of: id)
        panel.dropQuickFilter(of: tab, unlessIn: piece.listing.directory)
        // A folder that was read in one go and is long: its first screens are shown at once, as
        // if it were still arriving, and the whole list follows from the background a moment
        // later, so entering it costs the main thread no pass over the list.
        let listing =
            isLong
            ? piece.listing.with(items: Array(piece.listing.items.prefix(PanelLoading.firstPieceLimit))) : piece.listing
        tab.show(
            listing,
            focus: request.focus ?? piece.focus,
            history: request.history,
            complete: !isLong && piece.isLast,
            presorted: piece.order
        )
        if tab === panel.model {
            panel.announceLocation()
        }
        if isLong {
            grow(with: piece, in: panel)
        }
    }

    /// A long list grows in the background: filtering what has come, finding the marked
    /// entries and the cursor's again and counting the totals happen there, and what comes
    /// after this piece waits until the list has taken it.
    private func grow(with piece: PanelLoading.Piece, in panel: PanelViewController) {
        isHolding = true
        let tab = request.tab
        let items = piece.listing.items
        let change = PanelListChange(
            of: tab,
            bringing: items,
            while: { [self] in isCurrent },
            by: { PanelModel.prepare($0, extendingTo: items, sortedBy: piece.order) }
        )
        panel.apply(change) { [self] outcome in
            isHolding = false
            if outcome != nil, piece.isLast {
                tab.finishLoading()
            }
            releaseHeld()
        }
    }

    /// The reading ended.
    private func end(_ error: (any Error)?) {
        guard let panel, isCurrent else {
            return
        }
        let tab = request.tab
        panel.loads[id] = nil
        nothingArrivedYet = false
        if error != nil, tab.isOpening, let before = panel.openedFrom[id] {
            // Nothing could be read: back to the folder the panel came from, whichever
            // reading entered the new one, with the quick filter it had there.
            panel.restore(tab, to: before, quickFilter: panel.openedFromFilter[id])
        }
        panel.dropSnapshot(of: id)
        if error != nil, tab.isListed, !tab.isComplete, tab.directory.isSameLocation(as: previousDirectory) {
            // The tab shows part of a directory whose reading was overtaken by this failed
            // attempt: it is read again (once; that reading does not come back here), so it
            // does not stay half-listed.
            panel.reload(tab, focus: nil, as: .loud, completion: nil)
        } else {
            // An error in the middle of a listing ends it with what has arrived.
            tab.finishLoading()
        }
        panel.readingEnded(of: tab, load, succeeded: error == nil, changed: true)
        if let error, request.reportsFailure {
            panel.report(error)
        }
    }

    deinit {
        // Nothing to release.
    }
}
