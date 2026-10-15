import AFMContracts
import AFMKernel
import AppKit

/// Reading a tab's folder again: when asked, when it was reported changed, and once more for a
/// change that came while it could not be read (spec 03 › Panel anatomy, "Reading again").
extension PanelViewController {
    /// Reads the active tab's folder again (`PanelHandle.reload`); `completion` is called when
    /// it has been read, also when that happens later or is another reading's doing.
    internal func reload(focus: String?, quietly: Bool, completion: (@MainActor () -> Void)?) {
        reload(model, focus: focus, quietly: quietly, markDirty: true, changedAt: nil, completion: completion)
    }

    /// The folder of the active tab was reported changed at `time` (of the system's uptime),
    /// perhaps a while ago: it is read again quietly, unless a reading that began after the
    /// change is under way already.
    internal func reloadForChange(at time: TimeInterval) {
        reload(model, focus: nil, quietly: true, markDirty: true, changedAt: time, completion: nil)
    }

    /// Reads `tab`'s folder again, with the cursor on `focus`. `quietly`: nothing is announced
    /// or redrawn unless the folder changed. `markDirty`: a quiet reload that is turned away
    /// because the tab is being read or renamed, or was read a moment ago, is made up for when
    /// that is over (the folder may have changed since the reading began). `changedAt`: when the
    /// change that asks for this was noticed, if not now. `completion` is called when the folder
    /// has been read, also when that happens later or is another reading's doing.
    internal func reload(
        _ tab: PanelModel,
        focus: String?,
        quietly: Bool,
        markDirty: Bool,
        changedAt: TimeInterval?,
        completion: (@MainActor () -> Void)?
    ) {
        guard !isShutDown else {
            if let completion {
                MainLoop.queue(completion)
            }
            return
        }
        if quietly {
            guard !putsOffQuietReload(of: tab, markDirty: markDirty, changedAt: changedAt, completion: completion) else {
                return
            }
        } else if putsOffLoudReload(of: tab, completion: completion) {
            return
        }
        guard tab.isListed else {
            load(tab.directory, in: tab, focus: focus, history: .keep, reportFailure: !quietly) { _ in completion?() }
            return
        }
        let reading = beginLoad(for: tab, movingTo: nil, quiet: quietly) { _ in completion?() }
        let source = source(of: tab.directory, for: tab)
        let (flag, order) = (reading.flag, tab.wantedSort)
        Background.storage(
            "list",
            at: source.location,
            work: { Self.reread(source, order: order, cancellation: flag) },
            then: { [weak self] outcome in self?.reread(tab, as: reading, gave: outcome, focus: focus) }
        )
    }

    /// Reads a tab once more if its folder changed while it was read or renamed, or too soon
    /// after it was read; whoever waits for that is told when there is nothing left to read.
    internal func rereadIfDirty() {
        rereadIfDirty(model)
    }

    /// The same for `tab`.
    internal func rereadIfDirty(_ tab: PanelModel) {
        let id = ObjectIdentifier(tab)
        guard let locations = dirty[id] else {
            if loads[id] == nil {
                flushWaitingCompletions(of: id)
            }
            return
        }
        guard loads[id] == nil else {
            return
        }
        guard locations.contains(tab.directory.locationKey) else {
            // The tab has left the folder the change was in.
            dirty[id] = nil
            flushWaitingCompletions(of: id)
            return
        }
        guard renameField == nil, !commands.isBlocked() else {
            return
        }
        if let pause = waitBeforeQuietRead(of: id) {
            scheduleReread(of: tab, after: pause)
            return
        }
        reload(tab, focus: nil, quietly: true, markDirty: true, changedAt: nil, completion: nil)
    }

    /// Abandons every read and calculation in progress, for good: the window goes away.
    /// Whoever waits for one of them hears that it came to nothing.
    internal func cancelLoading() {
        isShutDown = true
        let abandoned = Array(loads.values)
        abandoned.forEach { $0.flag.cancel() }
        sizeCalculations.values.forEach { $0.cancel() }
        loads = [:]
        sizeCalculations = [:]
        rereadTimers.values.forEach { $0() }
        rereadTimers = [:]
        dirty = [:]
        typeFind?.cancel()
        volumeAsking.values.forEach { $0.cancel() }
        (volumeAsking, volumeAskAgain) = ([:], [])
        abandoned.forEach { $0.supersede() }
        for id in Array(waitingCompletions.keys) {
            flushWaitingCompletions(of: id)
        }
    }

    /// Stops the folder-size calculations of `tab`.
    internal func cancelSizeCalculations(of tab: PanelModel) {
        sizeCalculations.removeValue(forKey: ObjectIdentifier(tab))?.cancel()
    }

    /// Tells whoever waits for a reading of the tab `id` that there is nothing left to read.
    internal func flushWaitingCompletions(of id: ObjectIdentifier) {
        guard let waiting = waitingCompletions.removeValue(forKey: id) else {
            return
        }
        waiting.forEach { $0() }
    }

    /// Reads a folder again, on its lane's thread. A folder that vanished is replaced by its
    /// nearest readable parent. The listing is sorted here and, like every complete one, handed
    /// to the cache; what is remembered of a folder that is gone or cannot be read is forgotten.
    private nonisolated static func reread(
        _ source: PanelLoading.Source,
        order: ListOrder,
        cancellation flag: CancellationFlag
    ) -> Result<PanelLoading.Whole?, any Error> {
        guard !flag.isCancelled else {
            return .success(nil)
        }
        let outcome = Result {
            try PanelLoading.readWhole(source, order: order, climbing: true, cancellation: flag, progress: nil)
        }
        let whole = try? outcome.get()
        if !flag.isCancelled, whole?.listing.directory.isSameLocation(as: source.location) != true {
            source.cache.forget(source.location)
        }
        return outcome
    }

    /// A quiet reload must not disturb a rename in progress, and a directory that is being read
    /// right now is fresh anyway, unless it changed after that reading began; one that was read
    /// a moment ago is read once more when the pause is over, however many changes are reported
    /// until then. Returns true when the reload is put off (or not needed); whoever waits is
    /// told when the reading that makes up for it has ended.
    private func putsOffQuietReload(
        of tab: PanelModel,
        markDirty: Bool,
        changedAt: TimeInterval?,
        completion: (@MainActor () -> Void)?
    ) -> Bool {
        let id = ObjectIdentifier(tab)
        if renameField != nil || loads[id] != nil {
            let isCovered =
                renameField == nil && (loads[id].map { load in changedAt.map { $0 < load.started } ?? false } ?? false)
            if markDirty, !isCovered {
                noteChange(in: tab)
            }
            // Nothing is going to end that could tell whoever waits.
            if loads[id] == nil, dirty[id] == nil {
                completion?()
            } else {
                wait(for: id, completion)
            }
            return true
        }
        guard tab.isListed, let pause = waitBeforeQuietRead(of: id) else {
            return false
        }
        guard markDirty else {
            completion?()
            return true
        }
        noteChange(in: tab)
        wait(for: id, completion)
        scheduleReread(of: tab, after: pause)
        return true
    }

    /// The tab is on its way to another folder. That reading is not thrown over for one of the
    /// folder being left; should it fail and the tab stay, the folder is read then. Returns true
    /// when the reload is put off.
    private func putsOffLoudReload(of tab: PanelModel, completion: (@MainActor () -> Void)?) -> Bool {
        let id = ObjectIdentifier(tab)
        guard let destination = loads[id]?.destination, !destination.isSameLocation(as: tab.directory) else {
            return false
        }
        dirty[id, default: []].insert(tab.directory.locationKey)
        wait(for: id, completion)
        return true
    }

    /// `completion` waits for the next reading of the tab `id` to end.
    private func wait(for id: ObjectIdentifier, _ completion: (@MainActor () -> Void)?) {
        if let completion {
            waitingCompletions[id, default: []].append(completion)
        }
    }

    /// A reading again of `tab` came back with `outcome`: everything that grows with the list is
    /// done in the background for a long one (bringing it into the tab's order, comparing it
    /// with what the tab shows, filtering, finding the marked entries again); the main thread
    /// takes the result, or nothing at all when the folder is as it was.
    private func reread(
        _ tab: PanelModel,
        as reading: PanelLoad,
        gave outcome: Result<PanelLoading.Whole?, any Error>,
        focus: String?
    ) {
        let id = ObjectIdentifier(tab)
        guard loads[id] === reading else {
            return
        }
        guard case .success(let read) = outcome, let whole = read else {
            // Nothing could be read: what the tab shows is all there will be.
            loads[id] = nil
            tab.finishLoading()
            readingEnded(of: tab, reading, succeeded: true, changed: false)
            // Whoever asked for the folder to be read again hears why it was not.
            if case .failure(let error) = outcome, !reading.isQuiet, !reading.flag.isCancelled {
                report(error)
            }
            return
        }
        // The folder was replaced by a parent: what was calculated for it is of no use.
        if !whole.listing.directory.isSameLocation(as: tab.directory) {
            cancelSizeCalculations(of: tab)
        }
        dropQuickFilter(of: tab, unlessIn: whole.listing.directory)
        let change = PanelListChange(
            of: tab,
            bringing: whole.listing.items,
            while: { [weak self] in self?.loads[id] === reading },
            by: { PanelModel.prepare($0, update: whole.listing, focus: focus, presorted: whole.order) }
        )
        apply(change) { [weak self] outcome in
            guard let self, let outcome, loads[id] === reading else {
                return
            }
            loads[id] = nil
            // A folder that is merely read again is no new place; one that was replaced by
            // its parent, or was never announced, is (`announceLocation` knows).
            readingEnded(of: tab, reading, succeeded: true, changed: outcome == .changed)
        }
    }

    /// How long a quiet reading of a tab's folder has to wait still: after a reading there is
    /// a pause of `minimumRereadInterval`, and of twice the time that reading took if that is
    /// longer. Nil when it may start now.
    private func waitBeforeQuietRead(of id: ObjectIdentifier) -> TimeInterval? {
        guard let last = lastRead[id] else {
            return nil
        }
        let wait = last.ended + max(Self.minimumRereadInterval, 2 * last.cost) - ProcessInfo.processInfo.systemUptime
        return wait > 0 ? wait : nil
    }

    /// Looks at a tab again when the pause after its last reading is over.
    private func scheduleReread(of tab: PanelModel, after wait: TimeInterval) {
        let id = ObjectIdentifier(tab)
        guard rereadTimers[id] == nil else {
            return
        }
        rereadTimers[id] = MainLoop.after(wait) { [weak self, weak tab] in
            guard let self else {
                return
            }
            rereadTimers[id] = nil
            if let tab, tabs.tabs.contains(where: { $0 === tab }) {
                rereadIfDirty(tab)
            }
        }
    }

    /// Notes that the folder of a tab may have changed in a way no reading has seen: the one
    /// it shows, and the one a reading under way is taking it to.
    private func noteChange(in tab: PanelModel) {
        let id = ObjectIdentifier(tab)
        dirty[id, default: []].insert(tab.directory.locationKey)
        if let destination = loads[id]?.destination {
            dirty[id]?.insert(destination.locationKey)
        }
    }
}
