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
/// - at low priority (`.utility`, until a panel waits for the result), and not at all while a file job runs, while the panel is
///   still reading, or while the window is not the active one (the owner decides that and
///   passes no target then);
/// - a folder that was read less than `freshEnough` ago is not read again, one that could
///   not be read is left alone for `pauseAfterError`, and so is, for `pauseWhenNotKept`, one
///   whose listing the cache did not keep: reading it again would only be thrown away again;
/// - a folder with more entries than the cache keeps of one folder is given up as soon as
///   that is known, and not tried again for `pauseWhenTooLarge`.
/// One listing per rest of the cursor is all it ever asks of the server; it never descends.
///
/// **Threading.** The object and all its state belong to the main thread. The read runs on a
/// thread of its location's lane (`Background`), shares only its `Reading` (whose shared part
/// is behind a lock) and the (thread-safe) cache with the main thread, and reports back on
/// the main thread.
@MainActor
final class ReadAhead {
    /// How long the cursor has to rest on a folder before it is read.
    static let dwell: TimeInterval = 0.4
    /// A remembered listing younger than this is good enough: the folder is not read again.
    static let freshEnough: TimeInterval = 30
    /// A folder that could not be read is not tried again for this long.
    static let pauseAfterError: TimeInterval = 60
    /// A folder whose listing was read but not remembered is not read ahead again for this long.
    static let pauseWhenNotKept: TimeInterval = 60
    /// A folder with more entries than the cache takes is not read ahead again for this long.
    static let pauseWhenTooLarge: TimeInterval = 60 * 60
    /// A reading that has delivered nothing for this long is taken to wait for a server that
    /// does not answer: a panel does not wait for it but reads for itself.
    static let stalledAfter: TimeInterval = 10
    /// A reading that was told to stop and has not come back after this long is left behind.
    static let abandonAfter: TimeInterval = 30
    /// Settings key of the on/off switch (a Boolean, on when absent).
    static let settingsKey = "listingCache.readAhead"

    /// A folder to read, the way the panel would read it.
    struct Target: Equatable {
        let location: URL
        let showHidden: Bool
        let order: ListOrder

        /// Order aside: the same folder read the same way.
        func isSameReading(as other: Self) -> Bool {
            showHidden == other.showHidden && location.isSameLocation(as: other.location)
        }
    }

    typealias Outcome = Result<PanelLoading.Whole, any Error>

    /// A reading a panel has taken over (`join`).
    struct Joined {
        /// Registers who gets the result, on the main thread.
        let receive: @MainActor (@escaping @MainActor (Outcome) -> Void) -> Void
        /// The panel no longer wants the result (it moved on). A reading nobody waits for and
        /// the cursor does not rest on is told to stop.
        let leave: @MainActor () -> Void
    }

    /// Unchecked: what is marked "main thread only" is touched there alone, and what is
    /// shared with the reading thread is guarded by `lock`.
    private final class Reading: @unchecked Sendable {
        let target: Target
        let cancellation = CancellationFlag()
        // Main thread only.
        var waiting: [@MainActor (Outcome) -> Void] = []
        /// How many panels wait for the result.
        var waiters = 0
        /// When the reading was told to stop.
        var cancelledAt: TimeInterval?

        // Shared with the reading thread, behind the lock.
        private let lock = NSLock()
        private var joined = false
        private var givenUp = false
        private var lastProgress = ProcessInfo.processInfo.systemUptime
        private var thread: pthread_t?
        private var boost: pthread_override_t?

        init(target: Target) { self.target = target }

        /// A panel waits for the result: the reading is no longer the cursor's to cancel.
        var isJoined: Bool {
            lock.lock()
            defer { lock.unlock() }
            return joined
        }
        /// The folder turned out to be larger than the cache takes, and nobody waited for it.
        var wasGivenUp: Bool {
            lock.lock()
            defer { lock.unlock() }
            return givenUp
        }

        /// Reading thread, when it starts.
        func began() {
            lock.lock()
            thread = pthread_self()
            lastProgress = ProcessInfo.processInfo.systemUptime
            if joined { raise() }
            lock.unlock()
        }

        /// Reading thread, when it is done.
        func finished() {
            lock.lock()
            if let boost { pthread_override_qos_class_end_np(boost) }
            (boost, thread) = (nil, nil)
            lock.unlock()
        }

        /// Reading thread: `count` entries have arrived. Returns false when the reading is to
        /// be given up: it has more entries than will be remembered and no panel waits for it.
        func progress(_ count: Int, limit: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            lastProgress = ProcessInfo.processInfo.systemUptime
            if count > limit, !joined { givenUp = true }
            return !givenUp
        }

        /// Main thread: a panel takes the reading over. False when it was given up meanwhile.
        /// Somebody waits for it now, so it goes on at the user's priority.
        func join() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !givenUp else { return false }
            joined = true
            raise()
            return true
        }

        /// Main thread: no panel waits any more.
        func unjoin() {
            lock.lock()
            joined = false
            lock.unlock()
        }

        /// Whether nothing has arrived for `time`.
        func isSilent(for time: TimeInterval) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return ProcessInfo.processInfo.systemUptime - lastProgress > time
        }

        /// Called with the lock held.
        private func raise() {
            if boost == nil, let thread {
                boost = pthread_override_qos_class_start_np(thread, QOS_CLASS_USER_INITIATED, 0)
            }
        }
    }

    private let fileSystems: FileSystemRegistry
    private let cache: ListingCache
    /// What the cursor rests on now, if it may be read ahead.
    private var resting: Target?
    /// Counts the rests, so a timer that was overtaken knows it.
    private var rest = 0
    /// The one reading on its way; stays set until its thread has come back, also after it was
    /// cancelled, which is what keeps it to one at a time.
    private var reading: Reading?
    /// Folders that are not read ahead for now, by location, with the time (of the system's
    /// uptime) from which they may be again.
    private var pauses: [String: TimeInterval] = [:]
    static let pauseLimit = 256

    init(fileSystems: FileSystemRegistry, cache: ListingCache) {
        self.fileSystems = fileSystems
        self.cache = cache
    }

    /// True while a reading is on its way (also one that was told to stop and has not yet).
    var isReading: Bool { reading != nil }

    /// The number of folders that are left alone for now, for checks.
    var pausedCount: Int { pauses.count }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Tells where the cursor rests now: a folder that may be read ahead, or nil for anything
    /// else (a file, `[..]`, a local volume, a busy panel, an inactive window, a running job).
    /// Called on every change; the same target again means the cursor is still resting.
    func cursorRests(on target: Target?) {
        MainThread.assert("Read-ahead")
        guard target != resting else { return }
        resting = target
        rest += 1
        // The cursor went elsewhere: what was being read for it is not wanted any more.
        if let reading, !reading.isJoined, target.map({ !$0.isSameReading(as: reading.target) }) ?? true {
            cancel(reading)
        }
        if target != nil { startDwell() }
    }

    private func cancel(_ reading: Reading) {
        if reading.cancelledAt == nil { reading.cancelledAt = now }
        reading.cancellation.cancel()
    }

    private func startDwell() {
        let rest = rest
        MainLoop.after(Self.dwell) { [weak self] in
            guard let self, self.rest == rest else { return }
            dwellEnded()
        }
    }

    private func dwellEnded() {
        guard let target = resting else { return }
        if let reading {
            // While a reading is on its way nothing starts; when it ends, the dwell starts again.
            // One that was told to stop long ago and still has not come back is left behind.
            guard let stopped = reading.cancelledAt, now - stopped > Self.abandonAfter else { return }
            self.reading = nil
        }
        if let age = cache.age(of: target.location, showHidden: target.showHidden), age < Self.freshEnough {
            return
        }
        let key = target.location.locationKey
        if let until = pauses[key] {
            if now < until { return }
            pauses[key] = nil
        }
        start(target)
    }

    /// Leaves a folder alone for a while.
    private func pause(_ location: URL, for time: TimeInterval) {
        let now = now
        if pauses.count >= Self.pauseLimit {
            pauses = pauses.filter { $0.value > now }
            if pauses.count >= Self.pauseLimit { pauses = [:] }
        }
        pauses[location.locationKey] = now + time
    }

    private func start(_ target: Target) {
        let reading = Reading(target: target)
        self.reading = reading
        let (fileSystems, cache) = (fileSystems, cache)
        let limit = cache.limits.maxEntries
        Background.storage("ahead", at: target.location, qos: .utility) { [weak self] in
            // Background thread: reads, sorts and stores; touches nothing of this object.
            reading.began()
            var outcome: Outcome?
            do {
                outcome = try PanelLoading.readWhole(
                    target.location, showHidden: target.showHidden, order: target.order,
                    fileSystems: fileSystems, cache: cache, cancellation: reading.cancellation,
                    progress: { reading.progress($0, limit: limit) }
                )
                .map { .success($0) }
            } catch {
                // A file system may end a reading that was told to stop with an error: that is
                // no failure of the folder.
                outcome = reading.cancellation.isCancelled ? nil : .failure(error)
            }
            reading.finished()
            MainLoop.perform { [weak self, outcome] in self?.ended(reading, outcome) }
        }
    }

    /// Main thread. `outcome` is nil for a reading that was cancelled or given up.
    private func ended(_ reading: Reading, _ outcome: Outcome?) {
        if self.reading === reading { self.reading = nil }
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
            if reading.wasGivenUp { pause(target.location, for: Self.pauseWhenTooLarge) }
        }
        let waiting = reading.waiting
        reading.waiting = []
        if let outcome { waiting.forEach { $0(outcome) } }
        // The cursor may have come to rest on another folder meanwhile (or again on this one,
        // after its reading was cancelled): its turn comes now.
        if resting != nil { startDwell() }
    }

    /// For a panel that is asked to show `location`: if exactly that is being read ahead right
    /// now, the panel takes the reading over instead of starting a second one. From then on
    /// moving the cursor no longer cancels the reading; it runs to its end and its result is
    /// remembered, unless every panel that waited for it has left again (`Joined.leave`).
    ///
    /// A reading that has delivered nothing for `stalledAfter` is not taken over: it is told
    /// to stop, and the panel reads for itself.
    func join(_ location: URL, showHidden: Bool) -> Joined? {
        MainThread.assert("Read-ahead")
        guard let reading, !reading.cancellation.isCancelled, reading.target.showHidden == showHidden,
            reading.target.location.isSameLocation(as: location)
        else { return nil }
        if reading.isSilent(for: Self.stalledAfter) {
            cancel(reading)
            return nil
        }
        guard reading.join() else { return nil }
        reading.waiters += 1
        var hasLeft = false
        return Joined(
            receive: { reading.waiting.append($0) },
            leave: { [weak self] in
                guard !hasLeft else { return }
                hasLeft = true
                reading.waiters -= 1
                guard reading.waiters == 0, let self, self.reading === reading else { return }
                reading.waiting = []
                reading.unjoin()
                // The cursor's again: it goes on only while the cursor rests on its folder.
                if !(resting.map { $0.isSameReading(as: reading.target) } ?? false) { cancel(reading) }
            })
    }

    /// Stops everything, when the window goes away.
    func shutDown() {
        resting = nil
        rest += 1
        if let reading { cancel(reading) }
    }
}
