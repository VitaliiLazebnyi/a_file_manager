import AFMKernel
import Foundation

/// Copy and move: the walk through the sources, and what happens to each file whose turn has come.
extension FileJob {
    /// Copies or moves every source to the target; job thread.
    internal func runTransfer(_ result: inout JobResult) {
        guard let target else {
            return
        }
        pool = makePool()
        defersRemovals = isMove && fileSystems.capabilities(for: target.directory).contains(.deferredWrites)
        Self.sweepOnFirstVisit(target.directory)
        let batch = Batch(count: sources.count)
        do {
            var taken: Set<String> = []
            let slots = slotsInReadOrder()
            batch.isSerial = slots != Array(sources.indices)
            for slot in slots {
                try checkCancelled()
                try autoreleasepool {
                    try transferSource(at: slot, to: target, batch: batch, taken: &taken)
                }
            }
        } catch {
            result.cancelled = true
            // The workers stop with the job, and so does a progress window that holds them back.
            halt()
        }
        finishTransfer(batch, &result)
    }

    /// Waits for the workers, commits and carries out the removals that waited for it, and puts
    /// what was finished into `result`.
    private func finishTransfer(_ batch: Batch, _ result: inout JobResult) {
        // Whatever the pool still copies is waited for, also after a cancel: nothing of the
        // job goes on once `run()` has returned.
        let settled = batch.settled()
        if settled.cancelled { result.cancelled = true }
        if defersRemovals {
            // Every writer is closed now. A job that ended early commits nothing and removes
            // nothing: the sources stay next to copies that may not be durable.
            if !result.cancelled, !isStopping {
                do { try flushDeferred() } catch { result.cancelled = true }
            }
            keepPendingRemovals()
        }
        for (slot, source) in sources.enumerated() {
            guard let outcome = settled.outcomes[slot], outcome.finished, !isKept(source) else { continue }
            result.completed.append(source)
            if let arrived = outcome.target { result.lastTarget = arrived }
        }
    }

    /// Copies or moves the source at `slot` to its place in `target`; its outcome goes to `batch`.
    ///
    /// A copy into the folder it came from (`renamesSelfCopies`) gets a free name that no other
    /// source has `taken` yet.
    private func transferSource(at slot: Int, to target: TargetSpec, batch: Batch, taken: inout Set<String>) throws {
        let source = sources[slot]
        guard try hasSafeName(source, verb: isMove ? .move : .copy) else {
            batch.set(slot, .skipped)
            return
        }
        var destination = destination(for: source, in: target)
        if renamesSelfCopies, destination.isSameLocation(as: source) {
            let claimed = taken
            let isTaken = { (candidate: URL) in claimed.contains(Self.claimKey(candidate)) }
            destination = UniqueName.available(
                for: destination,
                in: fileSystems,
                cancellation: cancellation,
                isTaken: isTaken
            )
            try checkCancelled()
            taken.insert(Self.claimKey(destination))
        }
        let shownTarget = destination
        report { ["From: \(self.display(source))", "To: \(self.display(shownTarget))"] }
        guard let item = try topItem(slot, source) else {
            add(Measure(items: 1))
            _ = try attempt(.copy, at: source, target: nil) { throw FileJobError.sourceMissing(self.display(source)) }
            batch.set(slot, .skipped)
            return
        }
        let place = Place(batch: batch, slot: slot, position: options.filter.base, tree: nil, depth: 0)
        try transfer(item, to: destination, at: place)
    }

    /// The order the sources are worked through: as they are (by name), unless their file
    /// system reads them better in another (`readOrder(of:)`: an archive that is one stream
    /// gives its files in the order they lie in it).
    ///
    /// Local files are never asked about.
    private func slotsInReadOrder() -> [Int] {
        let slots = Array(sources.indices)
        guard sources.count > 1, let first = sources.first, !first.isFileURL, let target,
            let from = try? fileSystems.provider(for: first),
            let onto = try? fileSystems.provider(for: target.directory),
            from !== onto,
            !sources.contains(where: { $0.scheme != first.scheme })
        else { return slots }
        let ordered = from.readOrder(of: sources)
        guard ordered.count == sources.count, ordered != sources else {
            return slots
        }
        var places: [String: [Int]] = [:]
        for slot in slots.reversed() { places[sources[slot].locationKey, default: []].append(slot) }
        var result: [Int] = []
        result.reserveCapacity(slots.count)
        for url in ordered {
            // An answer that is not the same files in another order is not followed.
            guard let slot = places[url.locationKey]?.popLast() else {
                return slots
            }
            result.append(slot)
        }
        return result
    }

    /// The entries of one source folder in the order their file system reads them best; see
    /// `slotsInReadOrder`.
    ///
    /// The order by name stays wherever the file system has no other.
    internal func inReadOrder(_ items: [FileItem], from: any FileSystemProvider) -> [FileItem] {
        guard items.count > 1 else {
            return items
        }
        let urls = items.map(\.url)
        let ordered = from.readOrder(of: urls)
        guard ordered.count == urls.count, ordered != urls else {
            return items
        }
        var places: [String: [Int]] = [:]
        for index in items.indices.reversed() { places[urls[index].locationKey, default: []].append(index) }
        var result: [FileItem] = []
        result.reserveCapacity(items.count)
        for url in ordered {
            guard let index = places[url.locationKey]?.popLast() else {
                return items
            }
            result.append(items[index])
        }
        return result
    }

    /// Copies or moves one item with everything below it; its outcome goes to the batch of `place`.
    ///
    /// The filter's position is where it stands in the folder that holds the item. A move that
    /// takes the item away afterwards walks down from the job's own source the item lies below
    /// (`remove(_:below:)`).
    internal func transfer(_ listed: FileItem, to destination: URL, at place: Place) throws {
        try checkCancelled()
        let item = followsLinks ? resolvingLink(listed) : listed
        if item.isRealDirectory {
            guard let inside = options.filter.entering(item.name, from: place.position) else {
                add(measuredBefore(item))
                place.batch.set(place.slot, .skipped)
                return
            }
            guard place.depth < depthLimit else {
                add(measuredBefore(item))
                _ = try attempt(isMove ? .move : .copy, at: item.url, target: nil) {
                    throw FileJobError.nestedTooDeep(self.display(item.url))
                }
                place.batch.set(place.slot, .skipped)
                return
            }
            place.batch.set(place.slot, try transferFolder(item, to: destination, inside: inside, at: place))
            return
        }
        guard options.filter.admitsFile(item.name, at: place.position) else {
            add(Measure(items: 1, bytes: item.size))
            place.batch.set(place.slot, .skipped)
            return
        }
        try transferFile(item, to: destination, at: place)
    }

    /// Decides what happens to one file, here and now, and has it done: by the pool when the
    /// file is small and there is one, else on the spot.
    private func transferFile(_ item: FileItem, to destination: URL, at place: Place) throws {
        let batch = place.batch
        // Two items of one batch can aim at one name (a mask like `fixed.txt`, equally named
        // files from two folders of a list, names that differ only in letter case on a volume
        // that does not tell them apart): the second must find the first one finished, to see
        // the conflict, and what it then finds is this job's own work (`ownOutput`).
        let collides = batch.produced.contains(Self.claimHash(destination))
        if collides, batch.settled().cancelled { throw Cancelled() }
        if defersRemovals, pendingRemovals.withLock({ deferred.count }) >= deferredBatchSize {
            // A commit meets no file that is still being written under its temporary name.
            pool?.drain()
            try flushDeferred()
        }
        guard let decided = try decide(item, at: destination, ownOutput: collides || batch.isShared, batch: batch)
        else {
            batch.set(place.slot, .skipped)
            return
        }
        batch.produced.insert(Self.claimHash(decided.target))
        // Asked here, on the job thread, once per source folder; the workers only use the answer.
        let origin = originMark(of: item.url.deletingLastPathComponent(), copiedTo: decided.target)
        let tree = place.tree
        guard let pool, !batch.isSerial, item.size <= Self.smallFileLimit, !decided.isRename,
            !renamesInPlace(item.url, decided.target, batch)
        else {
            batch.set(place.slot, try carry(item, decided, origin: origin, tree: tree))
            return
        }
        pool.slots.wait()
        pool.start(in: batch.group) {
            do {
                batch.set(place.slot, try self.carry(item, decided, origin: origin, tree: tree))
            } catch {
                // Abort or Cancel in a question a worker asked: the whole job ends.
                self.halt()
                batch.setCancelled()
            }
        }
    }

    /// The plan for a file, with the questions it takes; nil when the file is skipped, which is
    /// then counted and logged.
    private func decide(_ item: FileItem, at destination: URL, ownOutput: Bool, batch: Batch) throws -> Plan? {
        var plan: Plan?
        let planned = try attempt(isMove ? .move : .copy, at: item.url, target: destination) {
            plan = try self.plan(for: item, at: destination, ownOutput: ownOutput) { candidate in
                batch.produced.contains(Self.claimHash(candidate))
            }
            return true
        }
        guard planned, let plan else {
            add(Measure(items: 1, bytes: item.size))
            if planned { record(isMove ? .move : .copy, item.url, destination, .skipped) }
            return nil
        }
        return plan
    }

    /// Carries out the plan for one file and, for a move, takes the source away; any thread of the job.
    ///
    /// `origin` is the mark the copy gets; `tree` is the job's own source the file lies below.
    private func carry(_ item: FileItem, _ decided: Plan, origin: Data?, tree: URL?) throws -> Outcome {
        let target = decided.target
        let flight = Flight()
        flight.origin = origin
        defer { land(flight, Measure(items: 1, bytes: item.size)) }
        var removesSource = false
        let arrived = try attempt(verb(of: decided), at: item.url, target: target) {
            self.advance(flight, to: 0)
            // A Retry after a try that kept its partial file under the real name: that
            // file is the job's own and makes room for the next try.
            self.removePartial(of: flight)
            // A plugin that still holds changes to this file (an archive that is written
            // after a delay) writes them first: what is copied or moved is the file as the
            // user sees it. If that fails the file is not touched, and the user hears why.
            try self.fileSystems.flushPendingWrites(to: item.url, cancellation: self.cancellation)
            removesSource = try self.execute(decided, item, flight)
            return true
        }
        guard arrived else {
            return .skipped
        }
        if removesSource, isStillTheSource(target, of: item.url) {
            // Never reached as far as anyone knows: the plan refuses a target that is the
            // source. But a source is removed only when what was written is another file.
            return Outcome(finished: true, emptied: false, target: target)
        }
        if removesSource, defersRemovals {
            // The copy is not durable yet; the original goes after the commit.
            postponeRemoval(of: item.url, isFolder: false, tree: tree)
        } else if removesSource {
            // A move between volumes has copied the file; taking the original away is a step
            // of its own, so that a Retry here does not copy a second time. A locked
            // original is asked about, as it is when it is deleted.
            let removed = try attempt(.delete, at: item.url, target: nil) {
                try self.removing(item, at: item.url) { try self.remove(item.url, below: tree) }
            }
            if !removed {
                return Outcome(finished: false, emptied: false, target: target)
            }
        }
        return Outcome(finished: true, emptied: isMove, target: target)
    }

    /// A move inside one file system is a rename when the system can do it; that is quick and
    /// stays on the job thread.
    ///
    /// On local disks that holds only within one volume: between two volumes a move is a copy and a
    /// removal, which the pool takes. The items of a batch share their two folders, so the volumes
    /// are looked at once per batch.
    private func renamesInPlace(_ source: URL, _ destination: URL, _ batch: Batch) -> Bool {
        guard isMove, let from = try? fileSystems.provider(for: source),
            let onto = try? fileSystems.provider(for: destination),
            from === onto
        else { return false }
        if batch.knowsVolume {
            return batch.staysOnVolume
        }
        guard source.isFileURL, destination.isFileURL else {
            return true
        }
        let (here, there) = (
            FileIdentity.device(of: source.deletingLastPathComponent()),
            FileIdentity.device(ofNearest: destination.deletingLastPathComponent())
        )
        // Unknown counts as one volume, the way it always was.
        let stays = here == nil || there == nil || here == there
        batch.staysOnVolume = stays
        batch.knowsVolume = true
        return stays
    }

    /// The verb a plan is logged with: an append, or the job's copy or move.
    private func verb(of plan: Plan) -> OperationRecord.Verb {
        if case .append = plan {
            return .append
        }
        return isMove ? .move : .copy
    }
}
