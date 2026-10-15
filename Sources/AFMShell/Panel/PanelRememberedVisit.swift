import AFMKernel
import Foundation

/// Show old, refresh behind: a visit of a location the listing cache remembers.
///
/// The tab shows that listing at once, in place of an empty "Reading…", and the location is read
/// afresh in the background. The fresh listing is applied with `PanelModel.update(with:)`, which
/// keeps cursor, selection and calculated folder sizes and changes the list only where it differs.
/// Until then the list can be used, but the model is not complete, so commands that mean
/// "everything" wait. If the fresh reading fails, the tab goes back to where it came from, as after
/// any failed reading, and the remembered listing is dropped.
///
/// Main thread only. The visit holds the panel weakly.
@MainActor
internal final class PanelRememberedVisit {
    private weak var panel: PanelViewController?
    private let request: PanelReadingRun.Request
    private let load: PanelLoad
    private let id: ObjectIdentifier
    private let cache: ListingCache
    /// What the tab goes back to when the fresh reading fails: not an empty folder some
    /// reading entered and gave up on.
    private let before: PanelModel.Snapshot
    /// The quick filter that comes back with `before`.
    private let quickBefore: QuickFilter?
    /// The remembered listing is in the list.
    private var isShown = false
    /// The remembered listing is on its way into the list (a long one, from the background).
    private var isBeingShown = false
    /// The fresh reading has ended.
    private var hasEnded = false
    /// The fresh listing is there (and perhaps on its way into the list): the remembered
    /// one is of no use any more.
    private var freshHasCome = false
    /// The item the cursor should go to that the remembered listing did not have.
    private var focusStillWanted: String?

    /// Whether this is still the tab's reading.
    private var isCurrent: Bool { panel?.loads[id] === load }
    /// Whether the remembered listing may still be shown: the reading is the tab's, has not ended
    /// and the fresh listing has not come.
    private var isStillWanted: Bool { isCurrent && !hasEnded && !freshHasCome }

    /// A visit for `request` of `panel`, which is `load` of the tab; a failure takes the tab
    /// back to `before`, with the quick filter `quickBefore`.
    private init(
        _ request: PanelReadingRun.Request,
        of panel: PanelViewController,
        load: PanelLoad,
        before: PanelModel.Snapshot,
        quickBefore: QuickFilter?
    ) {
        self.panel = panel
        self.request = request
        self.load = load
        id = ObjectIdentifier(request.tab)
        cache = panel.kernel.listingCache
        self.before = before
        self.quickBefore = quickBefore
        focusStillWanted = request.focus
    }

    /// Shows `entry`, the remembered listing of `request.location`, in the tab and reads the
    /// location afresh behind it. `completion` hears whether the fresh reading worked.
    internal static func start(
        _ request: PanelReadingRun.Request,
        from entry: ListingCache.Entry,
        in panel: PanelViewController,
        completion: ((Bool) -> Void)?
    ) {
        let tab = request.tab
        // Should this very folder be on its way already (read ahead), that reading is the fresh one.
        let joined = panel.host?.panel(panel, joinReadingOf: request.location, showHidden: tab.showHidden)
        // Where a failure leads back to: not an empty folder some reading entered and gave up on.
        let tabID = ObjectIdentifier(tab)
        let entered = tab.isOpening ? panel.openedFrom[tabID] : nil
        let filterBefore = entered != nil ? panel.openedFromFilter[tabID] : panel.quickFilters[tabID]
        let visit = PanelRememberedVisit(
            request,
            of: panel,
            load: panel.beginLoad(for: tab, movingTo: request.location, quiet: false, completion: completion),
            before: entered ?? tab.snapshot(),
            quickBefore: filterBefore
        )
        if let joined {
            panel.leave(joined, whenOvertaken: visit.load)
        }
        visit.present(entry, sortedIfNeeded: tab.wantedSort)
        if let joined {
            joined.receive { outcome in visit.finish(outcome.map { Optional($0) }) }
        } else {
            visit.readAfresh(panel.source(of: request.location, for: tab))
        }
    }

    /// Shows the remembered listing, sorted in `order` in the background first when it was
    /// remembered in another.
    private func present(_ entry: ListingCache.Entry, sortedIfNeeded order: ListOrder) {
        guard entry.order != order else {
            present(entry)
            return
        }
        let (location, showHidden) = (request.location, request.tab.showHidden)
        Background.compute(
            work: { [cache] in cache.entry(for: location, showHidden: showHidden, sortedBy: order) },
            then: { [self] entry in
                if let entry {
                    present(entry)
                }
            }
        )
    }

    /// Shows the remembered listing, unless the fresh one got there first or the reading ended.
    private func present(_ entry: ListingCache.Entry) {
        guard let panel, isStillWanted else {
            return
        }
        let tab = request.tab
        // Remembered in another order than the list has (now): a long one is sorted in the
        // background, then shown, unless the fresh listing gets there first.
        if entry.order != tab.wantedSort, entry.listing.items.count >= PanelViewController.backgroundSortThreshold {
            present(entry, sortedIfNeeded: tab.wantedSort)
            return
        }
        panel.dropSnapshot(of: id)
        panel.dropQuickFilter(of: tab, unlessIn: entry.listing.directory)
        guard entry.listing.items.count >= PanelViewController.backgroundSortThreshold else {
            tab.showRemembered(entry.listing, focus: request.focus, history: request.history, presorted: entry.order)
            shown()
            return
        }
        // A long one is made ready in the background (the filter over every entry, the index of
        // names the cursor is found by, the totals) and only taken over here; unless the fresh
        // listing gets there first, or the reading ends.
        isBeingShown = true
        let (listing, focus, history) = (entry.listing, request.focus, request.history)
        let change = PanelListChange(
            of: tab,
            count: listing.items.count,
            while: { [weak self] in self?.isStillWanted ?? false },
            by: { basis in
                PanelModel.prepare(
                    basis,
                    showRemembered: listing,
                    focus: focus,
                    history: history,
                    presorted: entry.order
                )
            }
        )
        panel.apply(change) { [self] outcome in
            isBeingShown = false
            if outcome != nil {
                shown()
            }
        }
    }

    /// The remembered listing is in the list: the panel is in the folder now.
    ///
    /// (Watching it is set up in the background, so a share that does not answer holds nothing up
    /// here.)
    private func shown() {
        isShown = true
        // An item that is not in the remembered listing may be in the fresh one.
        if request.tab.cursorItem?.name == request.focus {
            focusStillWanted = nil
        }
        if let panel, request.tab === panel.model {
            panel.announceLocation()
        }
    }

    /// Reads the location afresh in its lane.
    private func readAfresh(_ source: PanelLoading.Source) {
        let (flag, order) = (load.flag, request.tab.wantedSort)
        Background.storage(
            "list",
            at: source.location,
            work: { () -> Result<PanelLoading.Whole?, any Error> in
                // Overtaken while it waited for its turn: the file system is not asked.
                guard !flag.isCancelled else {
                    return .success(nil)
                }
                return Result {
                    try PanelLoading.readWhole(source, order: order, climbing: false, cancellation: flag, progress: nil)
                }
            },
            then: { [self] outcome in finish(outcome) }
        )
    }

    /// The fresh reading has ended.
    private func finish(_ outcome: Result<PanelLoading.Whole?, any Error>) {
        guard isCurrent else {
            return
        }
        switch outcome {
        case .success(let whole?):
            freshHasCome = true
            if isShown {
                update(with: whole)
            } else {
                enter(whole)
            }

        case .success(nil):
            // Stopped, which only a newer reading does; that one has taken over.
            break

        case .failure(let error):
            failed(error)
        }
    }

    /// The fresh listing is compared with the remembered one, filtered, and the marks and the
    /// cursor found in it, in the background for a long list; in whatever order the list is by then.
    private func update(with whole: PanelLoading.Whole) {
        guard let panel else {
            return
        }
        let wanted = focusStillWanted
        let change = PanelListChange(
            of: request.tab,
            bringing: whole.listing.items,
            while: { [weak self] in self?.isCurrent ?? false },
            by: { PanelModel.prepare($0, update: whole.listing, focus: wanted, presorted: whole.order) }
        )
        panel.apply(change) { [self] outcome in
            guard outcome != nil else {
                return
            }
            self.panel?.dropSnapshot(of: id)
            end(nil)
        }
    }

    /// The remembered listing never made it into the list: the fresh one is shown as a
    /// listing is shown after any reading; a long one is entered from the background.
    private func enter(_ fresh: PanelLoading.Whole) {
        guard let panel else {
            return
        }
        let tab = request.tab
        panel.sorted(fresh, for: tab) { [self] whole in
            guard let panel = self.panel, isCurrent else {
                return
            }
            panel.dropSnapshot(of: id)
            panel.dropQuickFilter(of: tab, unlessIn: whole.listing.directory)
            let (focus, history) = (request.focus ?? whole.focus, request.history)
            guard whole.listing.items.count >= PanelViewController.backgroundSortThreshold else {
                tab.show(whole.listing, focus: focus, history: history, presorted: whole.order)
                return end(nil)
            }
            let change = PanelListChange(
                of: tab,
                bringing: whole.listing.items,
                while: { [weak self] in self?.isCurrent ?? false },
                by: { basis in
                    PanelModel.prepare(
                        basis,
                        show: whole.listing,
                        focus: focus,
                        history: history,
                        presorted: whole.order
                    )
                }
            )
            panel.apply(change) { [self] outcome in
                if outcome != nil {
                    end(nil)
                }
            }
        }
    }

    /// The fresh reading failed: the remembered listing is forgotten and the tab goes back to
    /// where it came from.
    private func failed(_ error: any Error) {
        guard let panel else {
            return
        }
        let tab = request.tab
        cache.forget(request.location)
        // (A remembered listing that was still on its way into the list has taken the quick
        // filter off the folder the tab stays in: that comes back as well.)
        if isShown || isBeingShown || tab.isOpening {
            panel.restore(tab, to: before, quickFilter: quickBefore)
        }
        panel.dropSnapshot(of: id)
        end(error)
        // The folder the tab is back in was itself still arriving when it was left (and is
        // read again once; that reading does not come back here).
        if tab.isListed, !tab.isComplete {
            panel.reload(tab, focus: nil, as: .loud, completion: nil)
        }
    }

    /// The visit is over, with `error` when the fresh reading failed.
    private func end(_ error: (any Error)?) {
        guard let panel else {
            return
        }
        panel.loads[id] = nil
        hasEnded = true
        panel.readingEnded(of: request.tab, load, succeeded: error == nil, changed: true)
        if let error, request.reportsFailure {
            panel.report(error)
        }
    }

    deinit {
        // Nothing to release.
    }
}
