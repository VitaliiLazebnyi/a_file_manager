import AFMContracts
import AFMKernel
import AppKit

/// Following the models: what a panel does when a tab's list, marks or cursor change, and
/// when tabs are opened, closed or switched.
extension PanelViewController {
    /// The kernel's commands.
    internal var commands: CommandRegistry { kernel.commands }

    /// Commands act on the source panel, so a click in this panel makes it the source first.
    internal func performFocused(_ command: CommandID, _ argument: CommandArgument) {
        focus()
        commands.perform(command, argument)
    }

    /// Runs the command that stands for a standard editing action (Cmd+C and the like).
    internal func perform(_ role: EditingRole) {
        if let command = commands.command(with: role) {
            commands.perform(command, .nothing)
        }
    }

    /// Hears of the changes of every tab; those of the active one are drawn.
    internal func observeModels() {
        for tab in tabs.tabs {
            tab.onChange = { [weak self, weak tab] change in
                guard let self, let tab, tab === model else {
                    return
                }
                modelChanged(change)
            }
        }
    }

    /// A tab was opened, closed or activated.
    internal func tabsChanged() {
        observeModels()
        let open = Set(tabs.tabs.map(ObjectIdentifier.init))
        dropWhatBelongsToClosedTabs(keeping: open)
        // Text typed a moment ago into the tab that was left belongs to that tab: it is applied there now.
        if let typing = pendingQuickFilterTyping, typing.tab !== model {
            if open.contains(ObjectIdentifier(typing.tab)) {
                flushPendingQuickFilter()
            } else {
                dropPendingQuickFilter()
            }
        }
        giveCopiedTabsTheirDisplayFilter()
        guard isViewLoaded else {
            return
        }
        let tabSwitched = shownTab !== model
        redraw()
        guard tabSwitched else {
            return
        }
        // A tab that was never shown is read now; one that was in the background may be out of date.
        // One that is being read already is not asked again.
        if model.isListed {
            reload(model, focus: nil, quietly: true, markDirty: false, changedAt: nil, completion: nil)
        } else if loads[ObjectIdentifier(model)] == nil {
            loadRestored(model.directory, in: model)
        }
        announceLocation()
        host?.panelCursorDidChange(self)
    }

    /// Tells the host where the panel is, unless that is where it was told last: a folder
    /// that is merely read again is not a new place, and whoever follows the panels (a quick
    /// view, the history of places) must not take it for one.
    internal func announceLocation() {
        let shown = (tab: ObjectIdentifier(model), location: model.directory.locationKey)
        if let announced, announced.tab == shown.tab, announced.location == shown.location {
            return
        }
        announced = shown
        host?.panelDidChangeLocation(self)
    }

    /// A tab was dragged to another place in the strip.
    internal func moveTab(from index: Int, to destination: Int) {
        guard !commands.isBlocked() else {
            commands.onRejected()
            return
        }
        tabs.moveTab(from: index, to: destination)
    }

    /// The active tab changed: its list, its marks or its cursor.
    private func modelChanged(_ change: PanelModel.Change) {
        guard isViewLoaded else {
            return
        }
        switch change {
        case .contents:
            // A quick filter whose folder was left is taken away, which reports the next change.
            if dropStaleQuickFilter(of: model) {
                return
            }
            // A reading in progress goes on in the order the list has now.
            loads[ObjectIdentifier(model)]?.order.value = model.wantedSort
            redraw()

        case .selection:
            redrawSelection()
            host?.panelSelectionDidChange(self)

        case .cursor:
            showCursor(forceScroll: true)
            if viewMode == .brief {
                updateStatus()
            }
        }
        host?.panelCursorDidChange(self)
    }

    /// What belongs to a tab that is gone goes with it (and must not meet a new tab that happens to
    /// get the same address).
    ///
    /// Whoever waits for its reading hears that it came to nothing.
    private func dropWhatBelongsToClosedTabs(keeping open: Set<ObjectIdentifier>) {
        for (tab, load) in loads where !open.contains(tab) {
            load.flag.cancel()
            load.supersede()
        }
        loads = loads.filter { open.contains($0.key) }
        for tab in Array(waitingCompletions.keys) where !open.contains(tab) {
            flushWaitingCompletions(of: tab)
        }
        for (tab, stop) in rereadTimers where !open.contains(tab) {
            stop()
        }
        rereadTimers = rereadTimers.filter { open.contains($0.key) }
        lastRead = lastRead.filter { open.contains($0.key) }
        for (tab, flag) in sizeCalculations where !open.contains(tab) {
            flag.cancel()
        }
        sizeCalculations = sizeCalculations.filter { open.contains($0.key) }
        quickFilters = quickFilters.filter { open.contains($0.key) }
        filterJobs = filterJobs.filter { open.contains($0.key) }
        volumeAskAgain.formIntersection(open)
        for (tab, flag) in volumeAsking where !open.contains(tab) {
            flag.cancel()
        }
        volumeAsking = volumeAsking.filter { open.contains($0.key) }
        for tab in Array(openedFrom.keys) where !open.contains(tab) {
            dropSnapshot(of: tab)
        }
        dirty = dirty.filter { open.contains($0.key) }
        if let shown = shownCursor, !open.contains(shown.tab) {
            shownCursor = nil
        }
    }

    /// A tab opened while a quick filter is on is a copy of that tab, filter included, but has
    /// no quick filter of its own (each tab has its own): it gets the display filter below
    /// the quick one, so it is not left with a filter nothing shows and Esc cannot take away.
    private func giveCopiedTabsTheirDisplayFilter() {
        for tab in tabs.tabs where quickFilters[ObjectIdentifier(tab)] == nil {
            guard let title = tab.filter?.title,
                let source = quickFilters.values.first(where: {
                    !$0.text.isEmpty && $0.title == title && $0.directory.isSameLocation(as: tab.directory)
                })
            else {
                continue
            }
            setFilter(source.base, of: tab, narrowing: false)
        }
    }

    /// Reads the folder of a tab that has not shown anything yet (one restored from the last
    /// session).
    ///
    /// A folder that is gone is replaced by its nearest parent that can be read, as for the panels
    /// on start-up, and not complained about on every visit; only when nothing can be read at all
    /// the error is reported.
    private func loadRestored(_ location: URL, in tab: PanelModel) {
        let parent = (try? kernel.fileSystems.provider(for: location))?.parent(of: location)
        let next = parent.flatMap { $0.isSameLocation(as: location) ? nil : $0 }
        load(location, in: tab, focus: nil, history: .keep, reportFailure: next == nil) { [weak self] succeeded in
            guard let self, !succeeded, let next, !tab.isListed, loads[ObjectIdentifier(tab)] == nil else {
                return
            }
            loadRestored(next, in: tab)
        }
    }
}
