import AFMKernel
import CoreServices
import Foundation

/// Reports changes made by other programs to the watched folders, about half a second after
/// they happen (spec 03 › Watching the file system).
///
/// The system reports every change anywhere below a watched folder, which for the home
/// folder or a whole disk is a great deal. Those reports arrive on a queue of the watcher's
/// own and are sifted there; only a change in one of the watched folders themselves is
/// passed on to the caller's queue, and then in lumps: a burst of reports becomes one call.
///
/// **No call here waits for the file system.** `watch(_:)` only records what is wanted; the
/// folders are resolved (`realpath` asks the disk, and a stalled share does not answer) and
/// the stream is made and started on queues of the watcher's own, so the caller may be the
/// main thread.
final class DirectoryWatcher: Sendable {
    /// The streams this process holds. The system gives one process 512 of them and refuses
    /// the next one without a word (`FSEventStreamStart` answers false and nothing is
    /// logged), so a program that lets streams pile up ends with folders nobody watches.
    /// Counted here so that this can be seen: by tests, and in a run with
    /// `AFM_WATCHER_CENSUS` set, which prints the figures when the process ends.
    enum Census {
        private static let lock = NSLock()
        /// Guarded by `lock`.
        nonisolated(unsafe) private static var (now, most, refused) = (0, 0, 0)
        private static let printsAtExit: Void = {
            guard getenv("AFM_WATCHER_CENSUS") != nil else { return }
            atexit {
                let figures = DirectoryWatcher.Census.figures
                fputs(
                    "AFM_WATCHER_CENSUS live=\(figures.live) peak=\(figures.peak) refused=\(figures.refused)\n",
                    stderr
                )
            }
        }()

        /// Streams that run now, the most that ran at one time, and how often the system refused one.
        static var figures: (live: Int, peak: Int, refused: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (now, most, refused)
        }

        static func started() {
            _ = printsAtExit
            lock.lock()
            now += 1
            most = max(most, now)
            lock.unlock()
        }

        static func ended() {
            lock.lock()
            now -= 1
            lock.unlock()
        }

        static func wasRefused() {
            _ = printsAtExit
            lock.lock()
            refused += 1
            lock.unlock()
        }
    }

    /// Set once the watcher is stopped or has gone: reports still under way are dropped.
    /// All state is guarded by `lock`.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false

        var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
        }
    }

    /// What a running stream needs, apart from the watcher: the stream keeps it alive itself,
    /// so a report that is under way when the watcher stops or goes away finds everything
    /// it touches still there.
    ///
    /// Unchecked: what changes is guarded by `lock`; the rest is fixed in `init`.
    private final class Watch: @unchecked Sendable {
        /// Resolved path as reported by the system → the directory the caller asked for.
        let watched: [String: URL]
        /// The lengths of the resolved paths: most reports are rejected on length alone,
        /// before any string is made of them.
        private let lengths: Set<Int>
        let queue: DispatchQueue
        let streamQueue: DispatchQueue
        let onChange: @Sendable ([URL]) -> Void
        private let gate: Gate
        private let lock = NSLock()
        private var stopped = false
        /// What changed and was not passed on yet, and whether a delivery is on its way.
        private var pending: [String: URL] = [:]
        private var isScheduled = false
        private var lastDelivery: UInt64 = 0

        /// A burst of reports is passed on once, this long after its first report; and never
        /// sooner than `minimumGap` after the previous one, however long the burst lasts
        /// (a build running below a watched folder). A report that says "look at everything"
        /// is given longer still.
        static let delay = 0.3, rescanDelay = 1.0, minimumGap = 0.5

        init(
            watched: [String: URL],
            queue: DispatchQueue,
            streamQueue: DispatchQueue,
            gate: Gate,
            onChange: @escaping @Sendable ([URL]) -> Void
        ) {
            (self.watched, self.queue, self.streamQueue, self.gate, self.onChange) = (
                watched, queue, streamQueue, gate, onChange
            )
            lengths = Set(watched.keys.map { $0.utf8.count })
        }

        var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped || gate.isStopped
        }

        func stop() {
            lock.lock()
            stopped = true
            pending = [:]
            lock.unlock()
        }

        /// Called on the stream's queue.
        func report(
            count: Int,
            paths: UnsafePointer<UnsafePointer<CChar>>,
            flags: UnsafePointer<FSEventStreamEventFlags>
        ) {
            let rescanFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
            var changed: [String: URL] = [:]
            var isRescan = false
            for index in 0..<count {
                if flags[index] & rescanFlags != 0 {
                    isRescan = true
                    continue
                }
                let bytes = paths[index]
                var length = Int(strlen(bytes))
                if length > 1, bytes[length - 1] == CChar(UInt8(ascii: "/")) { length -= 1 }
                guard lengths.contains(length) else { continue }
                let path = String(
                    decoding: UnsafeBufferPointer(
                        start: UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self),
                        count: length
                    ),
                    as: UTF8.self
                )
                if let directory = watched[path] { changed[path] = directory }
            }
            if isRescan { changed = watched }
            guard !changed.isEmpty else { return }
            // A report that comes after the stop is dropped by `deliver`.
            lock.lock()
            pending.merge(changed) { first, _ in first }
            let mustSchedule = !isScheduled
            isScheduled = true
            let now = DispatchTime.now()
            let wanted = now.uptimeNanoseconds + UInt64((isRescan ? Self.rescanDelay : Self.delay) * 1e9)
            let earliest = lastDelivery == 0 ? 0 : lastDelivery + UInt64(Self.minimumGap * 1e9)
            lock.unlock()
            guard mustSchedule else { return }
            streamQueue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: max(wanted, earliest))) { self.deliver() }
        }

        private func deliver() {
            lock.lock()
            let directories = Array(pending.values)
            pending = [:]
            isScheduled = false
            lastDelivery = DispatchTime.now().uptimeNanoseconds
            let isStopped = stopped || gate.isStopped
            lock.unlock()
            guard !directories.isEmpty, !isStopped else { return }
            // A report that was on its way when the watcher stopped is dropped.
            queue.async { if !self.isStopped { self.onChange(directories) } }
        }
    }

    /// Everything that is done to streams, on `control`. Held by the closures that are
    /// still to run, so the watcher itself may go away at any moment.
    ///
    /// Unchecked: what changes is only touched on `control`, one block at a time; the rest is
    /// fixed in `init`.
    private final class Core: @unchecked Sendable {
        let queue: DispatchQueue
        let onChange: @Sendable ([URL]) -> Void
        // Not at the lowest classes: while the program (or the machine) keeps every core busy
        // with work of a higher class, queues of the utility class may get no thread for a
        // long time, and a panel would then not hear of changes for as long. Setting a stream
        // up is a few steps; sifting reports is a look at the length of each path.
        let control = DispatchQueue(label: "AFM.DirectoryWatcher.control", qos: .userInitiated)
        let streamQueue = DispatchQueue(label: "AFM.DirectoryWatcher", qos: .default)
        let gate = Gate()
        let system: FSEvSystem

        // Only touched on `control`.
        private var desired: [URL] = []
        /// What `realpath` said about a folder as asked for (nil: it could not be resolved,
        /// which is remembered for a few seconds only), and when.
        private var resolutions: [String: (real: String?, at: UInt64)] = [:]
        /// One stream for each watched folder (see `FSEvSystem` for why not one for all).
        private var streams: [FSEventStreamRef] = []
        private var watch: Watch?
        private var watched: [String: URL] = [:]
        /// The pause before a stream that could not be made is tried again, and whether a try is on its way.
        private var retryDelay = Core.firstRetry
        private var isRetryPending = false
        private static let firstRetry = 0.5, longestRetry = 30.0

        /// How long a failed resolution counts, and how long the stream waits for a slow one.
        private static let failureLifetime: UInt64 = 5_000_000_000
        private static let resolutionPatience = 2.0

        /// The folders the stream watches now, once what was asked before has been done.
        var watchedFolders: Set<URL> { control.sync { Set(watched.values) } }

        init(queue: DispatchQueue, system: FSEvSystem, onChange: @escaping @Sendable ([URL]) -> Void) {
            (self.queue, self.system, self.onChange) = (queue, system, onChange)
        }

        /// A started stream for each of `folders`, all handing their reports to `state`; nil when
        /// the process has too few descriptors to spare, or the system does not make or start one
        /// of them (the ones made already are ended again).
        private func startedStreams(for state: Watch, folders: [String]) -> [FSEventStreamRef]? {
            let cost = folders.reduce(0) { $0 + FSEvDescriptors.cost(of: $1) }
            guard system.spareDescriptors() - cost >= FSEvDescriptors.reserve else { return nil }
            var made: [FSEventStreamRef] = []
            for folder in folders {
                guard let stream = startedStream(for: state, folder: folder) else {
                    for stream in made { end(stream) }
                    return nil
                }
                made.append(stream)
            }
            return made
        }

        /// A stream of the reports about `folder`, running on `streamQueue` and handing them to
        /// `state`; nil when the system makes none or does not start it.
        private func startedStream(for state: Watch, folder: String) -> FSEventStreamRef? {
            // The stream holds its own reference to the state, taken and given back through these.
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(state).toOpaque(),
                retain: { info in
                    if let info { _ = Unmanaged<Watch>.fromOpaque(info).retain() }
                    return info
                },
                release: { info in
                    if let info { Unmanaged<Watch>.fromOpaque(info).release() }
                },
                copyDescription: nil
            )
            // Plain C strings and not a bridged array: below the home folder or the root there
            // are thousands of reports a second, and only a few name a watched folder.
            // (`info` is the context's, which is always set.)
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                Unmanaged<Watch>.fromOpaque(info.unsafelyUnwrapped).takeUnretainedValue()
                    .report(
                        count: count,
                        paths: paths.assumingMemoryBound(to: UnsafePointer<CChar>.self),
                        flags: flags
                    )
            }
            guard let created = system.makeStream(folder, &context, callback) else {
                // The system's clean-up may have closed descriptor 0 (see `FSEvSystem`).
                FSEvDescriptors.fillZero()
                return nil
            }
            FSEventStreamSetDispatchQueue(created, streamQueue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                return nil
            }
            return created
        }

        func request(_ directories: [URL]) {
            control.async { [self] in
                guard !gate.isStopped else { return }
                desired = directories
                resolve()
            }
        }

        func stop() {
            gate.stop()
            control.async { [self] in tearDown() }
        }

        /// Asks for the real path of every folder not yet known, each on its own thread so that
        /// one that hangs holds up nothing but itself. The stream is made as soon as all have
        /// answered, or when the patience is spent without the ones that did not: those join
        /// when they do answer.
        private func resolve() {
            // (A URL's path has no slash at the end.)
            let wanted = Set(desired.map(\.path))
            let now = DispatchTime.now().uptimeNanoseconds
            resolutions = resolutions.filter { wanted.contains($0.key) }
            let missing = wanted.filter { path in
                guard let known = resolutions[path] else { return true }
                return known.real == nil && now &- known.at > Self.failureLifetime
            }
            guard !missing.isEmpty else {
                reconcile()
                return
            }
            let group = DispatchGroup()
            for path in missing {
                resolutions[path] = nil
                group.enter()
                // On a thread of the kernel's own: a share that does not answer keeps it for good.
                BlockingCalls.run { [self] in
                    let real = DirectoryWatcher.resolve(path)
                    control.async { [self] in
                        resolutions[path] = (real, DispatchTime.now().uptimeNanoseconds)
                        group.leave()
                    }
                }
            }
            group.notify(queue: control) { [self] in reconcile() }
            control.asyncAfter(deadline: .now() + Self.resolutionPatience) { [self] in reconcile() }
        }

        /// Makes the stream match what is wanted and has been resolved.
        private func reconcile() {
            guard !gate.isStopped else { return }
            // (A folder still being resolved is left out.)
            let pairs = desired.compactMap { directory in
                resolutions[directory.path].map { ($0.real ?? directory.path, directory) }
            }
            // A path the system cannot take is left out: it would not be watched, and the
            // system's failure would close descriptor 0 (see `FSEvSystem`).
            let resolved = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
                .filter { FSEvDescriptors.fits($0.key) }
            guard resolved != watched else { return }
            tearDown()
            guard !resolved.isEmpty else { return }
            let watch = Watch(watched: resolved, queue: queue, streamQueue: streamQueue, gate: gate, onChange: onChange)
            guard let streams = startedStreams(for: watch, folders: Array(resolved.keys)) else {
                // Not remembered as watched: the next request tries again, and so does this.
                Census.wasRefused()
                retryLater()
                return
            }
            for _ in streams { Census.started() }
            (self.streams, self.watch, watched) = (streams, watch, resolved)
            retryDelay = Self.firstRetry
        }

        /// The system did not give a stream (it has only so many for all programs together,
        /// and they may all be taken for a while): without one the folders would stay
        /// unwatched until somebody asks for another set. Tried again after a pause that
        /// grows, for as long as the watcher lives.
        private func retryLater() {
            // (A watcher stopped meanwhile does not try again: `reconcile` looks at the gate first.)
            guard !isRetryPending else { return }
            isRetryPending = true
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, Self.longestRetry)
            control.asyncAfter(deadline: .now() + delay) { [self] in
                isRetryPending = false
                reconcile()
            }
        }

        private func tearDown() {
            watch?.stop()
            watch = nil
            watched = [:]
            for stream in streams {
                end(stream)
                Census.ended()
            }
            streams = []
        }

        private func end(_ stream: FSEventStreamRef) {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            // A report that is being sifted at this moment is finished before the stream goes.
            streamQueue.sync {}
            FSEventStreamRelease(stream)
        }
    }

    private let core: Core

    /// The folders the stream watches now, once the requests made before have been dealt with
    /// (the folders that are still being resolved are not among them yet).
    internal var watchedFolders: Set<URL> { core.watchedFolders }

    /// `onChange` receives the watched folders whose contents changed, on `queue`.
    /// `system` makes the streams: the system's FSEvents, unless a test gives its own.
    init(queue: DispatchQueue = .main, system: FSEvSystem = .live, onChange: @escaping @Sendable ([URL]) -> Void) {
        core = Core(queue: queue, system: system, onChange: onChange)
    }

    deinit { core.stop() }

    /// Replaces the set of watched folders. Only their direct contents are reported. Returns at
    /// once; the stream follows in the background.
    func watch(_ directories: [URL]) {
        core.request(directories)
    }

    func stop() {
        core.stop()
    }

    /// May wait for the file system: never on the caller's thread.
    private static func resolve(_ path: String) -> String? {
        // realpath, because the system reports /private/tmp where Foundation says /tmp.
        // (A real path has no slash at the end.)
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }
}
