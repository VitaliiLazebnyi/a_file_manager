import AFMKernel
import Foundation

/// The free space the system can make on demand, measured now and then behind the scenes.
extension LocalFileSystem {
    /// What the system would free on demand on one volume: the free space it reports for
    /// important uses, less the space that is plainly free.
    internal struct SpareMeasurement {
        /// The difference; nil where the system has no such figure.
        internal var bytes: Int64?
        /// When it was measured, or when the measurement under way was begun, in nanoseconds of
        /// uptime.
        internal var measured: UInt64
        /// A new measurement is under way.
        internal var isMeasuring: Bool
        /// Of which volume: a different one mounted at the same place starts afresh.
        internal let volume: fsid_t
    }

    /// How old a measurement may be before the next question has it taken again.
    internal static let spareSpaceAge: UInt64 = 3_000_000_000
    /// A measurement that has taken this long is taken for lost (the disk does not answer).
    internal static let spareSpaceLoss: UInt64 = 30_000_000_000

    /// The free space as the Finder states it, which counts what the system can clear away.
    ///
    /// That figure takes the system some fifteen milliseconds, every time, so only the first
    /// question about a volume waits for it. Every later one is answered at once: the plainly free
    /// space, which is quick to get and follows every change, plus the difference as it was last
    /// measured. When that measurement is more than a few seconds old it is taken again behind the
    /// scenes, and if the difference has changed, `FileSystemRegistry.volumeInfoDidChange` says so
    /// on the main thread: whoever shows the figure asks again and now gets the right one. So an
    /// answer is never waited for, and never stays wrong for longer than one measurement takes.
    internal func freeForImportantUsage(on url: URL, mountPoint: String, fsid: fsid_t, available: Int64?) -> Int64? {
        func measure(_ url: URL) -> Int64? {
            let important =
                if let freeSpace = probes.freeSpace {
                    freeSpace(url.path).important
                } else {
                    (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                        .volumeAvailableCapacityForImportantUsage
                }
            // A share says 0: it does not know.
            return important.flatMap { $0 > 0 ? $0 : nil }
        }
        guard let available else {
            return measure(url)
        }
        let now = DispatchTime.now().uptimeNanoseconds
        spareLock.lock()
        // What was measured of another volume that once was mounted here is of no use.
        if let known = spareSpace[mountPoint], known.volume.val.0 != fsid.val.0 || known.volume.val.1 != fsid.val.1 {
            spareSpace[mountPoint] = nil
        }
        guard let known = spareSpace[mountPoint] else {
            spareLock.unlock()
            let important = measure(url)
            spareLock.lock()
            spareSpace[mountPoint] = SpareMeasurement(
                bytes: important.map { $0 - available },
                measured: DispatchTime.now().uptimeNanoseconds,
                isMeasuring: false,
                volume: fsid
            )
            spareLock.unlock()
            return important
        }
        let isDue =
            (now &- known.measured > Self.spareSpaceAge && !known.isMeasuring)
            || (known.isMeasuring && now &- known.measured > Self.spareSpaceLoss)
        if isDue {
            spareSpace[mountPoint]?.isMeasuring = true
            spareSpace[mountPoint]?.measured = now
        }
        spareLock.unlock()
        if isDue {
            BlockingCalls.run { [weak self] in self?.measureSpareSpace(on: mountPoint, volume: fsid) }
        }
        return known.bytes.flatMap { available + $0 > 0 ? available + $0 : nil }
    }

    /// Takes the measurement again and announces a difference that is no longer the one the
    /// answers were worked out from.
    ///
    /// Blocks; runs on a background queue.
    private func measureSpareSpace(on mountPoint: String, volume fsid: fsid_t) {
        var volume = URL(fileURLWithPath: mountPoint, isDirectory: true)
        volume.removeAllCachedResourceValues()
        var figures: (available: Int64?, important: Int64?)?
        if let freeSpace = probes.freeSpace {
            figures = freeSpace(mountPoint)
        } else if let values = try? volume.resourceValues(forKeys: [
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ]) {
            figures = (values.volumeAvailableCapacity.map(Int64.init), values.volumeAvailableCapacityForImportantUsage)
        }
        spareLock.lock()
        let before = spareSpace[mountPoint]?.bytes
        var after: Int64?
        if let figures, let available = figures.available {
            after = figures.important.flatMap { $0 > 0 ? $0 : nil }.map { $0 - available }
            spareSpace[mountPoint] = SpareMeasurement(
                bytes: after,
                measured: DispatchTime.now().uptimeNanoseconds,
                isMeasuring: false,
                volume: fsid
            )
        } else {
            // Nothing to be learned now (the volume has gone): the next question measures again.
            spareSpace[mountPoint] = nil
        }
        spareLock.unlock()
        guard after != before else {
            return
        }
        DispatchQueue.main.async { [volume] in
            NotificationCenter.default.post(
                name: FileSystemRegistry.volumeInfoDidChange,
                object: self,
                userInfo: [FileSystemRegistry.volumeRootKey: volume]
            )
        }
    }
}
