import AFMKernel
import Foundation

/// Reads the folder the cursor rests on before it is opened, into the listing cache, so that
/// Enter shows it at once.
///
/// **This produces network traffic the user did not ask for, so it is kept modest:**
/// - only for folders on volumes that are not local (a network share), never on local disks,
///   where reading is fast anyway;
/// - only after the cursor has rested on the folder for `dwell`, so moving through a list
///   reads nothing;
/// - one folder at a time: a second read never starts while one is still on its way, even one
///   that was already told to stop (unless that one has not come back for `abandonAfter`: it
///   then waits for something that will never answer, and is left behind);
/// - at low priority (`.utility`, until a panel waits for the result), and not at all while a
///   file job runs, while the panel is still reading, or while the window is not the active
///   one (the owner decides that and passes no target then);
/// - a folder that was read less than `freshEnough` ago is not read again, one that could
///   not be read is left alone for `pauseAfterError`, and so is, for `pauseWhenNotKept`, one
///   whose listing the cache did not keep: reading it again would only be thrown away again;
/// - a folder with more entries than the cache keeps of one folder is given up as soon as
///   that is known, and not tried again for `pauseWhenTooLarge`.
/// One listing per rest of the cursor is all it ever asks of the server; it never descends.
///
/// **Threading.** The object and all its state belong to the main thread. The read runs on a
/// thread of its location's lane (`Background`), shares only its `ReadAheadReading` (whose
/// shared part is behind a lock) and the (thread-safe) cache with the main thread, and reports
/// back on the main thread.
@MainActor
internal final class ReadAhead {
    /// A folder to read, the way the panel would read it.
    internal struct Target: Equatable, Sendable {
        /// The folder.
        internal let location: URL
        /// Whether hidden entries are listed.
        internal let showHidden: Bool
        /// The order the listing is sorted in.
        internal let order: ListOrder

        /// Order aside: the same folder read the same way.
        internal func isSameReading(as other: Self) -> Bool {
            showHidden == other.showHidden && location.isSameLocation(as: other.location)
        }
    }

    /// A reading a panel has taken over (`join`).
    internal struct Joined {
        /// Registers who gets the result, on the main thread.
        internal let receive: @MainActor (@escaping @MainActor (Outcome) -> Void) -> Void
        /// The panel no longer wants the result (it moved on).
        ///
        /// A reading nobody waits for and the cursor does not rest on is told to stop.
        internal let leave: @MainActor () -> Void
    }

    /// What a reading brings: the folder read to its end, or why it could not be read.
    internal typealias Outcome = Result<PanelLoading.Whole, any Error>

    /// How long the cursor has to rest on a folder before it is read.
    internal static let dwell: TimeInterval = 0.4
    /// A remembered listing younger than this is good enough: the folder is not read again.
    internal static let freshEnough: TimeInterval = 30
    /// A folder that could not be read is not tried again for this long.
    internal static let pauseAfterError: TimeInterval = 60
    /// A folder whose listing was read but not remembered is not read ahead again for this long.
    internal static let pauseWhenNotKept: TimeInterval = 60
    /// A folder with more entries than the cache takes is not read ahead again for this long.
    internal static let pauseWhenTooLarge: TimeInterval = 60 * 60
    /// A reading that has delivered nothing for this long is taken to wait for a server that
    /// does not answer: a panel does not wait for it but reads for itself.
    internal static let stalledAfter: TimeInterval = 10
    /// A reading that was told to stop and has not come back after this long is left behind.
    internal static let abandonAfter: TimeInterval = 30
    /// Settings key of the on/off switch (a Boolean, on when absent).
    internal static let settingsKey = "listingCache.readAhead"
    /// The most folders that are left alone at a time; beyond that the oldest pauses go.
    internal static let pauseLimit = 256

    /// The one reading on its way; stays set until its thread has come back, also after it was
    /// cancelled, which is what keeps it to one at a time.
    internal private(set) var reading: ReadAheadReading?
    /// Folders that are not read ahead for now, by location, with the time (of the system's
    /// uptime) from which they may be again.
    internal private(set) var pauses: [String: TimeInterval] = [:]
    private let fileSystems: FileSystemRegistry
    private let cache: ListingCache
    /// What the cursor rests on now, if it may be read ahead.
    private var resting: Target?
    /// Counts the rests, so a timer that was overtaken knows it.
    private var rest = 0

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Reads with `fileSystems` into `cache`.
    internal init(fileSystems: FileSystemRegistry, cache: ListingCache) {
        self.fileSystems = fileSystems
        self.cache = cache
    }

    /// Tells where the cursor rests now: a folder that may be read ahead, or nil for anything else
    /// (a file, `[..]`, a local volume, a busy panel, an inactive window, a running job).
    ///
    /// Called on every change; the same target again means the cursor is still resting.
    internal func cursorRests(on target: Target?) {
        guard target != resting else {
            return
        }
        resting = target
        rest += 1
        // The cursor went elsewhere: what was being read for it is not wanted any more.
        if let reading, !reading.isJoined, target.map({ !$0.isSameReading(as: reading.target) }) ?? true {
            cancel(reading)
        }
        if target != nil {
            startDwell()
        }
    }

    /// For a panel that is asked to show `location`: if exactly that is being read ahead right now,
    /// the panel takes the reading over instead of starting a second one.
    ///
    /// From then on moving the cursor no longer cancels the reading; it runs to its end and its
    /// result is remembered, unless every panel that waited for it has left again (`Joined.leave`).
    ///
    /// A reading that has delivered nothing for `stalledAfter` is not taken over: it is told
    /// to stop, and the panel reads for itself.
    internal func join(_ location: URL, showHidden: Bool) -> Joined? {
        guard let reading, !reading.cancellation.isCancelled, reading.target.showHidden == showHidden,
            reading.target.location.isSameLocation(as: location)
        else {
            return nil
        }
        if reading.isSilent(for: Self.stalledAfter) {
            cancel(reading)
            return nil
        }
        guard reading.join() else {
            return nil
        }
        reading.waiters += 1
        var hasLeft = false
        return Joined(
            receive: { reading.waiting.append($0) },
            leave: { [weak self] in
                guard !hasLeft else {
                    return
                }
                hasLeft = true
                reading.waiters -= 1
                self?.left(reading)
            }
        )
    }

    /// Stops everything, when the window goes away.
    internal func shutDown() {
        resting = nil
        rest += 1
        if let reading {
            cancel(reading)
        }
    }

    /// A panel has left `reading`: when it was the last, the reading is the cursor's again and
    /// goes on only while the cursor rests on its folder.
    private func left(_ reading: ReadAheadReading) {
        guard reading.waiters == 0, self.reading === reading else {
            return
        }
        reading.waiting = []
        reading.unjoin()
        if !(resting.map { $0.isSameReading(as: reading.target) } ?? false) {
            cancel(reading)
        }
    }

    /// Tells a reading to stop, noting when that was first done.
    private func cancel(_ reading: ReadAheadReading) {
        if reading.cancelledAt == nil {
            reading.cancelledAt = now
        }
        reading.cancellation.cancel()
    }

    /// Starts the time the cursor has to rest before its folder is read.
    private func startDwell() {
        let rest = rest
        MainLoop.after(Self.dwell) { [weak self] in
            guard let self, self.rest == rest else {
                return
            }
            dwellEnded()
        }
    }

    /// The cursor has rested long enough: its folder is read, unless something speaks against it.
    private func dwellEnded() {
        guard let target = resting else {
            return
        }
        if let reading {
            // While a reading is on its way nothing starts; when it ends, the dwell starts again.
            // One that was told to stop long ago and still has not come back is left behind.
            guard let stopped = reading.cancelledAt, now - stopped > Self.abandonAfter else {
                return
            }
            self.reading = nil
        }
        if let age = cache.age(of: target.location, showHidden: target.showHidden), age < Self.freshEnough {
            return
        }
        let key = target.location.locationKey
        if let until = pauses[key] {
            if now < until {
                return
            }
            pauses[key] = nil
        }
        start(target)
    }

    /// Leaves a folder alone for a while.
    private func pause(_ location: URL, for time: TimeInterval) {
        let now = now
        if pauses.count >= Self.pauseLimit {
            pauses = pauses.filter { $0.value > now }
            if pauses.count >= Self.pauseLimit {
                pauses = [:]
            }
        }
        pauses[location.locationKey] = now + time
    }

    /// Reads `target` in the background.
    private func start(_ target: Target) {
        let reading = ReadAheadReading(target: target)
        self.reading = reading
        let source = PanelLoading.Source(
            location: target.location,
            showHidden: target.showHidden,
            fileSystems: fileSystems,
            cache: cache
        )
        let limit = cache.limits.maxEntries
        Background.storage("ahead", at: target.location, qos: .utility) { [weak self] in
            // Background thread: reads, sorts and stores; touches nothing of this object.
            reading.began()
            let outcome = Self.read(source, for: reading, limit: limit)
            reading.finished()
            MainLoop.perform { [weak self, outcome] in self?.ended(reading, outcome) }
        }
    }

    /// Reads for `reading`, on its background thread; nil for a reading that was cancelled or
    /// given up.
    private nonisolated static func read(_ source: PanelLoading.Source, for reading: ReadAheadReading, limit: Int)
        -> Outcome?
    {
        do {
            return
                try PanelLoading.readWhole(
                    source,
                    order: reading.target.order,
                    climbing: false,
                    cancellation: reading.cancellation
                ) { reading.progress($0, limit: limit) }
                .map { .success($0) }
        } catch {
            // A file system may end a reading that was told to stop with an error: that is
            // no failure of the folder.
            return reading.cancellation.isCancelled ? nil : .failure(error)
        }
    }

    /// Main thread. `outcome` is nil for a reading that was cancelled or given up.
    private func ended(_ reading: ReadAheadReading, _ outcome: Outcome?) {
        if self.reading === reading {
            self.reading = nil
        }
        let target = reading.target
        switch outcome {
        case .failure:
            pause(target.location, for: Self.pauseAfterError)

        case .success:
            // Read, but not remembered (the cache has its reasons): reading it again while the
            // cursor stays would end the same way.
            if cache.age(of: target.location, showHidden: target.showHidden) == nil {
                pause(target.location, for: Self.pauseWhenNotKept)
            }

        case nil:
            if reading.wasGivenUp {
                pause(target.location, for: Self.pauseWhenTooLarge)
            }
        }
        let waiting = reading.waiting
        reading.waiting = []
        if let outcome {
            for receiver in waiting {
                receiver(outcome)
            }
        }
        // The cursor may have come to rest on another folder meanwhile (or again on this one,
        // after its reading was cancelled): its turn comes now.
        if resting != nil {
            startDwell()
        }
    }

    deinit {
        // Nothing to release: a reading out holds no reference to this object.
    }
}
