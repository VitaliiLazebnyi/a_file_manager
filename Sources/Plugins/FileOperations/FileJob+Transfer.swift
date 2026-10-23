import AFMContracts
import AFMKernel
import Foundation
import os

extension FileJob {
    internal func runTransfer(_ result: inout JobResult) {
        guard let target else {
            return
        }
        pool = makePool()
        defersRemovals = isMove && fileSystems.capabilities(for: target.directory).contains(.deferredWrites)
        // Once per folder and run of the program: reading a very large folder takes a moment.
        let isFirstVisit = Self.swept.withLock { swept in
            if swept.count >= 1_024 { swept.removeAll() }
            return swept.insert(target.directory.locationKey).inserted
        }
        if isFirstVisit { Self.sweepStaleTemporaries(in: target.directory) }
        let batch = Batch(count: sources.count)
        do {
            var taken: Set<String> = []
            let slots = slotsInReadOrder()
            batch.isSerial = slots != Array(sources.indices)
            for slot in slots {
                let source = sources[slot]
                try checkCancelled()
                try autoreleasepool {
                    guard try hasSafeName(source, verb: isMove ? .move : .copy) else {
                        return batch.set(slot, .skipped)
                    }
                    var destination = destination(for: source, in: target)
                    if renamesSelfCopies, destination.isSameLocation(as: source) {
                        destination = UniqueName.available(
                            for: destination,
                            in: fileSystems,
                            cancellation: cancellation
                        ) {
                            taken.contains(Self.claimKey($0))
                        }
                        try checkCancelled()
                        taken.insert(Self.claimKey(destination))
                    }
                    let shownTarget = destination
                    report { ["From: \(self.display(source))", "To: \(self.display(shownTarget))"] }
                    guard let item = try topItem(slot, source) else {
                        add(Measure(items: 1))
                        _ = try attempt(.copy, at: source) { throw FileJobError.sourceMissing(self.display(source)) }
                        return batch.set(slot, .skipped)
                    }
                    try transfer(
                        item,
                        to: destination,
                        from: options.filter.base,
                        batch: batch,
                        slot: slot,
                        isTopLevel: true,
                        depth: 0
                    )
                }
            }
        } catch {
            result.cancelled = true
            // The workers stop with the job, and so does a progress window that holds them back.
            halt()
        }
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
            if let target = outcome.target { result.lastTarget = target }
        }
    }

    /// The order the sources are worked through: as they are (by name), unless their file
    /// system reads them better in another (`readOrder(of:)`: an archive that is one stream
    /// gives its files in the order they lie in it).
    ///
    /// Local files are never asked about.
    private func slotsInReadOrder() -> [Int] {
        let slots = Array(sources.indices)
        guard sources.count > 1, let first = sources.first, !first.isFileURL, let target,
            let from = try? fileSystems.provider(for: first), let to = try? fileSystems.provider(for: target.directory),
            from !== to,
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

    // MARK: Copy and move

    /// Copies or moves one item with everything below it; its outcome goes to `batch`.
    /// `position` is where the copy filter stands in the folder that holds the item;
    /// `isTopLevel` is true for the job's own sources, whose targets are checked against them.
    /// `tree` is the job's own source that the item lies below (nil for such a source itself): a
    /// move that takes the item away afterwards walks down from there (`remove(_:below:)`).
    internal func transfer(
        _ listed: FileItem,
        to destination: URL,
        from position: CopyFilter.Position,
        batch: Batch,
        slot: Int,
        isTopLevel: Bool = false,
        tree: URL? = nil,
        depth: Int
    ) throws {
        try checkCancelled()
        let item = followsLinks ? resolvingLink(listed) : listed
        if item.isRealDirectory {
            guard let inside = options.filter.entering(item.name, from: position) else {
                add(measuredBefore(item))
                batch.set(slot, .skipped)
                return
            }
            guard depth < depthLimit else {
                add(measuredBefore(item))
                _ = try attempt(isMove ? .move : .copy, at: item.url) {
                    throw FileJobError.nestedTooDeep(self.display(item.url))
                }
                batch.set(slot, .skipped)
                return
            }
            batch.set(
                slot,
                try transferFolder(
                    item,
                    to: destination,
                    position: inside,
                    isTopLevel: isTopLevel,
                    tree: tree,
                    depth: depth
                )
            )
            return
        }
        guard options.filter.admitsFile(item.name, at: position) else {
            add(Measure(items: 1, bytes: item.size))
            batch.set(slot, .skipped)
            return
        }
        try transferFile(item, to: destination, batch: batch, slot: slot, tree: tree)
    }

    /// Decides what happens to one file, here and now, and has it done: by the pool when the
    /// file is small and there is one, else on the spot.
    private func transferFile(_ item: FileItem, to destination: URL, batch: Batch, slot: Int, tree: URL?) throws {
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
        var plan: Plan?
        let planned = try attempt(isMove ? .move : .copy, at: item.url, target: destination) {
            plan = try self.plan(for: item, at: destination, ownOutput: collides || batch.isShared) {
                batch.produced.contains(Self.claimHash($0))
            }
            return true
        }
        guard planned, let decided = plan else {
            add(Measure(items: 1, bytes: item.size))
            if planned { record(isMove ? .move : .copy, item.url, destination, .skipped) }
            batch.set(slot, .skipped)
            return
        }
        let target = decided.target
        batch.produced.insert(Self.claimHash(target))
        // Asked here, on the job thread, once per source folder; the workers only use the answer.
        let origin = originMark(of: item.url.deletingLastPathComponent(), copiedTo: target)
        let work = { @Sendable () throws -> Outcome in
            let flight = Flight()
            flight.origin = origin
            defer { self.land(flight, Measure(items: 1, bytes: item.size)) }
            var removesSource = false
            let arrived = try self.attempt(self.verb(of: decided), at: item.url, target: target) {
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
            if removesSource, self.isStillTheSource(target, of: item.url) {
                // Never reached as far as anyone knows: the plan refuses a target that is the
                // source. But a source is removed only when what was written is another file.
                return Outcome(finished: true, emptied: false, target: target)
            }
            if removesSource, self.defersRemovals {
                // The copy is not durable yet; the original goes after the commit.
                self.postponeRemoval(of: item.url, isFolder: false, tree: tree)
            } else if removesSource {
                // A move between volumes has copied the file; taking the original away is a step
                // of its own, so that a Retry here does not copy a second time. A locked
                // original is asked about, as it is when it is deleted.
                let removed = try self.attempt(.delete, at: item.url) {
                    try self.removing(item, at: item.url) { try self.remove(item.url, below: tree) }
                }
                if !removed {
                    return Outcome(finished: false, emptied: false, target: target)
                }
            }
            return Outcome(finished: true, emptied: self.isMove, target: target)
        }
        guard let pool, !batch.isSerial, item.size <= Self.smallFileLimit, !decided.isRename,
            !renamesInPlace(item.url, target, batch)
        else {
            batch.set(slot, try work())
            return
        }
        pool.slots.wait()
        pool.start(in: batch.group) {
            do {
                batch.set(slot, try work())
            } catch {
                // Abort or Cancel in a question a worker asked: the whole job ends.
                self.halt()
                batch.setCancelled()
            }
        }
    }

    /// A move inside one file system is a rename when the system can do it; that is quick and
    /// stays on the job thread.
    ///
    /// On local disks that holds only within one volume: between two volumes a move is a copy and a
    /// removal, which the pool takes. The items of a batch share their two folders, so the volumes
    /// are looked at once per batch.
    private func renamesInPlace(_ source: URL, _ destination: URL, _ batch: Batch) -> Bool {
        guard isMove, let from = try? fileSystems.provider(for: source),
            let to = try? fileSystems.provider(for: destination),
            from === to
        else { return false }
        if let known = batch.staysOnVolume {
            return known
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
        return stays
    }

    internal func verb(of plan: Plan) -> OperationRecord.Verb {
        if case .append = plan {
            return .append
        }
        return isMove ? .move : .copy
    }
}
