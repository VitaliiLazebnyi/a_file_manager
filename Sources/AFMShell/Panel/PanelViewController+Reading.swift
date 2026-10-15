import AFMContracts
import AFMKernel
import AppKit

/// Reading folders into the tabs (`PanelHandle.show`), and making the changes of a list that
/// grow with it in the background.
extension PanelViewController {
    /// True while the active tab's folder is being read.
    internal var isLoading: Bool { loads[ObjectIdentifier(model)] != nil }

    /// Lets go of a long list the change brought, in the background, once everything that
    /// carried it across the threads (the block that runs now, with what it holds) is gone.
    private static func letGo(of fresh: [FileItem]) {
        guard fresh.count >= backgroundSortThreshold else {
            return
        }
        // `release` empties the variable it is given.
        var last = Optional(fresh)
        MainLoop.queue { Background.release(&last) }
    }

    /// Gives the panel the keyboard, which makes it the source (`PanelHandle`).
    internal func focus() {
        view.window?.makeFirstResponder(listView)
        host?.panelDidBecomeActive(self)
    }

    /// Shows `location` in the active tab (`PanelHandle.show`).
    internal func show(
        _ location: URL,
        focus: String?,
        history: PanelModel.HistoryEffect,
        completion: (@MainActor (Bool) -> Void)?
    ) {
        load(
            PanelReadingRun.Request(
                location: location,
                tab: model,
                focus: focus,
                history: history,
                reportsFailure: true
            ),
            completion: completion
        )
    }

    /// Reads the location of `request` in the background and shows it in its tab, piece by piece
    /// when it takes long.
    ///
    /// A failure leaves the tab as it was, and is reported when the request says so. `completion`
    /// hears whether it worked. A location the listing cache remembers is shown at once and read
    /// afresh behind (`PanelRememberedVisit`).
    internal func load(_ request: PanelReadingRun.Request, completion: ((Bool) -> Void)?) {
        guard !isShutDown else {
            if let completion {
                MainLoop.perform { completion(false) }
            }
            return
        }
        let (location, tab) = (request.location, request.tab)
        if let entry = kernel.listingCache.entry(for: location, showHidden: tab.showHidden) {
            PanelRememberedVisit.start(request, from: entry, in: self, completion: completion)
            return
        }
        // The folder under the cursor may be on its way already, read ahead: then the panel
        // waits for that reading instead of asking the file system a second time.
        let joined = host?.panel(self, joinReadingOf: location, showHidden: tab.showHidden)
        let load = beginLoad(for: tab, movingTo: location, quiet: false, completion: completion)
        let run = PanelReadingRun(request, of: self, load: load)
        run.enterEmptyIfSlow()
        if let joined {
            leave(joined, whenOvertaken: load)
            joined.receive { [weak self] outcome in
                // Main thread, when the reading that was taken over has ended.
                switch outcome {
                case .failure(let error):
                    run.finish(error)

                case .success(let whole):
                    self?
                        .sorted(whole, for: tab) { whole in
                            run.receive(
                                PanelLoading.Piece(
                                    listing: whole.listing,
                                    focus: whole.focus,
                                    order: whole.order,
                                    isFirst: true,
                                    isLast: true
                                )
                            )
                            run.finish(nil)
                        }
                }
            }
        } else {
            PanelLoading(source(of: location, for: tab), order: load.order, cancellation: load.flag)
                .start(onPiece: { run.receive($0) }, onEnd: { run.finish($0) })
        }
    }

    /// What reading `location` for `tab` reads, and with what.
    internal func source(of location: URL, for tab: PanelModel) -> PanelLoading.Source {
        PanelLoading.Source(
            location: location,
            showHidden: tab.showHidden,
            fileSystems: kernel.fileSystems,
            cache: kernel.listingCache
        )
    }

    /// Tells the user a folder could not be read, once the code that found out has finished,
    /// from the run loop and after any message that is still on screen (`MainLoop.dialog`): the
    /// alert is modal and runs its own event loop.
    internal func report(_ error: any Error) {
        let interaction = kernel.interaction
        MainLoop.dialog { interaction.report(error, title: "The folder cannot be read!") }
    }

    /// Hands on a listing in the order of `tab`.
    ///
    /// One that is in another order (the order was changed while it was read) is sorted in the
    /// background first, so the main thread only takes over a finished list; should the order
    /// change again meanwhile, once more.
    internal func sorted(
        _ whole: PanelLoading.Whole,
        for tab: PanelModel,
        then receive: @escaping (PanelLoading.Whole) -> Void
    ) {
        let order = tab.wantedSort
        guard whole.order != order else {
            receive(whole)
            return
        }
        Background.compute(
            work: { () -> PanelLoading.Whole in
                let items = Sorter.resort(whole.listing.items, from: whole.order, to: order)
                return PanelLoading.Whole(listing: whole.listing.with(items: items), focus: whole.focus, order: order)
            },
            then: { [weak self] resorted in self?.sorted(resorted, for: tab, then: receive) }
        )
    }

    /// Makes a change of a tab's list that the model works out from the list as it is
    /// (`PanelModel.prepare`).
    ///
    /// For a long list all of that is done in the background, on all cores, and the main thread
    /// only takes the result over (`PanelModel.apply`, a few milliseconds at a million entries); a
    /// short one is done on the spot. Should the list, its filter or its order have changed while
    /// the work was under way, nothing was done here and the work starts again from the list as it
    /// is now, again in the background.
    ///
    /// `change.isWanted` is asked on the main thread before the result is taken: when it says
    /// no, nothing is changed and `done` hears nil. The lists that go are let go of by the
    /// model, off the main thread.
    ///
    /// The list the change brings may turn out not to be needed (the folder is as it was): then
    /// it is let go of, and that too must not happen here. So one more hold on it is kept until
    /// everything that carried it across the threads is gone, and that last hold is dropped in
    /// the background.
    internal func apply(_ change: PanelListChange, then done: @escaping (PanelModel.Outcome?) -> Void) {
        let (tab, prepare) = (change.tab, change.prepare)
        let basis = tab.basis
        guard max(tab.listedItems.count, change.count) >= Self.backgroundSortThreshold else {
            done(tab.apply(prepare(basis)))
            return
        }
        Background.compute(
            work: { prepare(basis) },
            then: { [weak self] prepared in
                guard let self, change.isWanted() else {
                    Self.letGo(of: change.fresh)
                    return done(nil)
                }
                let outcome = tab.apply(prepared)
                if outcome == .stale {
                    apply(change, then: done)
                } else {
                    Self.letGo(of: change.fresh)
                    done(outcome)
                }
            }
        )
    }

    /// Forgets what a tab showed before it entered a folder; a long list is freed in the background.
    internal func dropSnapshot(of id: ObjectIdentifier) {
        openedFromFilter[id] = nil
        var snapshot = openedFrom.removeValue(forKey: id)
        Background.release(&snapshot)
    }

    /// Takes a tab back to what it showed when `snapshot` was taken, with the quick filter
    /// it had then: the model puts its filter back (`PanelModel.restore`), and the text of
    /// the quick filter, which is kept here, comes back with it.
    internal func restore(_ tab: PanelModel, to snapshot: PanelModel.Snapshot, quickFilter: QuickFilter?) {
        let id = ObjectIdentifier(tab)
        // A filtering under way was for the folder that is left again.
        filterJobs[id] = nil
        quickFilters[id] = quickFilter
        tab.restore(snapshot)
        // Text that was typed and had not reached the list when the snapshot was taken.
        if let quickFilter, tab.filter?.title != quickFilter.title {
            quickFilters[id] = quickFilter
            setFilter(quickFilter.combined, of: tab, narrowing: false)
        }
    }

    /// A reading that was taken over from the read-ahead is left when this reading is overtaken.
    internal func leave(_ joined: ReadAhead.Joined, whenOvertaken load: PanelLoad) {
        let owned = MainOwned(joined)
        load.keeps.append(load.flag.onCancel { MainLoop.perform { owned.take()?.leave() } })
    }

    /// Starts a reading for `tab`, which overtakes the one before.
    ///
    /// Calculations of folder sizes go on unless the tab moves to another folder (`location` is not
    /// where it is; nil for a reading of the folder it shows). A `quiet` reading announces nothing
    /// unless the folder changed.
    internal func beginLoad(
        for tab: PanelModel,
        movingTo location: URL?,
        quiet: Bool,
        completion: ((Bool) -> Void)?
    ) -> PanelLoad {
        let id = ObjectIdentifier(tab)
        if let overtaken = loads[id] {
            overtaken.flag.cancel()
            overtaken.supersede()
        }
        if let location, !location.isSameLocation(as: tab.directory) {
            cancelSizeCalculations(of: tab)
        }
        // Whatever this reading finds is newer than anything that was missed before.
        dirty[id] = nil
        rereadTimers.removeValue(forKey: id)?()
        let load = PanelLoad(order: tab.wantedSort, destination: location, isQuiet: quiet, completion: completion)
        loads[id] = load
        if quiet {
            host?.panelActivityDidChange(self)
        } else {
            host?.panelCursorDidChange(self)
        }
        return load
    }

    /// A reading of `tab` has come to its end, whichever way: the status line, the host and
    /// whoever waited hear of it, and a change that was put off meanwhile gets its turn.
    /// `changed` is false for a quiet reading that found the folder as the tab shows it.
    internal func readingEnded(of tab: PanelModel, _ load: PanelLoad, succeeded: Bool, changed: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        lastRead[ObjectIdentifier(tab)] = (now, now - load.started)
        if tab === model {
            updateStatus()
            announceLocation()
        }
        if load.isQuiet, !changed {
            host?.panelActivityDidChange(self)
        } else {
            host?.panelCursorDidChange(self)
        }
        load.complete(succeeded)
        rereadIfDirty(tab)
    }
}
