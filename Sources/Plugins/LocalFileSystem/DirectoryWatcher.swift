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
final class DirectoryWatcher {
    /// The streams this process holds. The system gives one process 512 of them and refuses
    /// the next one without a word (`FSEventStreamStart` answers false and nothing is
    /// logged), so a program that lets streams pile up ends with folders nobody watches.
    /// Counted here so that this can be seen: by tests, and in a run with
    /// `AFM_WATCHER_CENSUS` set, which prints the figures when the process ends.
    enum Census {
        private static let lock = NSLock()
        private static var (now, most, refused) = (0, 0, 0)
        private static let printsAtExit: Void = {
            guard getenv("AFM_WATCHER_CENSUS") != nil else { return }
            atexit {
                let figures = DirectoryWatcher.Census.figures
                fputs("AFM_WATCHER_CENSUS live=\(figures.live) peak=\(figures.peak) refused=\(figures.refused)\n", stderr)
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
    private final class Gate {
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
    private final class Watch {
        /// Resolved path as reported by the system → the directory the caller asked for.
        let watched: [String: URL]
        /// The lengths of the resolved paths: most reports are rejected on length alone,
        /// before any string is made of them.
        private let lengths: Set<Int>
        let queue: DispatchQueue
        let streamQueue: DispatchQueue
        let onChange: ([URL]) -> Void
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

        /// When everything below the watched folders counts: their paths as bytes, to be
        /// compared with the start of each reported path. Nil when only the folders' own
        /// contents count.
        private let trees: [(path: [UInt8], key: String)]?

        init(watched: [String: URL], recursive: Bool, queue: DispatchQueue, streamQueue: DispatchQueue, gate: Gate,
             onChange: @escaping ([URL]) -> Void) {
            (self.watched, self.queue, self.streamQueue, self.gate, self.onChange) = (watched, queue, streamQueue, gate, onChange)
            lengths = Set(watched.keys.map { $0.utf8.count })
            trees = recursive ? watched.keys.map { (Array($0.utf8), $0) } : nil
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
        func report(count: Int, paths: UnsafePointer<UnsafePointer<CChar>>, flags: UnsafePointer<FSEventStreamEventFlags>) {
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
                if let trees {
                    // A change anywhere below a watched folder is a change of that folder's tree.
                    for tree in trees where changed[tree.key] == nil && length >= tree.path.count {
                        let isBelow = length == tree.path.count || tree.path.count == 1 || bytes[tree.path.count] == CChar(UInt8(ascii: "/"))
                        if isBelow, memcmp(bytes, tree.path, tree.path.count) == 0 { changed[tree.key] = watched[tree.key] }
                    }
                    continue
                }
                guard lengths.contains(length) else { continue }
                let path = String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self), count: length),
                                  as: UTF8.self)
                if let directory = watched[path] { changed[path] = directory }
            }
            if isRescan { changed = watched }
            guard !changed.isEmpty else { return }
            lock.lock()
            guard !stopped, !gate.isStopped else {
                lock.unlock()
                return
            }
            pending.merge(changed) { first, _ in first }
            let mustSchedule = !isScheduled
            isScheduled = true
            let now = DispatchTime.now()
            let wanted = now.uptimeNanoseconds + UInt64((isRescan ? Watch.rescanDelay : Watch.delay) * 1e9)
            let earliest = lastDelivery == 0 ? 0 : lastDelivery + UInt64(Watch.minimumGap * 1e9)
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
    private final class Core {
        let queue: DispatchQueue
        let onChange: ([URL]) -> Void
        let isRecursive: Bool
        // Not at the lowest classes: while the program (or the machine) keeps every core busy
        // with work of a higher class, queues of the utility class may get no thread for a
        // long time, and a panel would then not hear of changes for as long. Setting a stream
        // up is a few steps; sifting reports is a look at the length of each path.
        let control = DispatchQueue(label: "AFM.DirectoryWatcher.control", qos: .userInitiated)
        let streamQueue = DispatchQueue(label: "AFM.DirectoryWatcher", qos: .default)
        let gate = Gate()

        // Only touched on `control`.
        private var desired: [URL] = []
        /// What `realpath` said about a folder as asked for (nil: it could not be resolved,
        /// which is remembered for a few seconds only), and when.
        private var resolutions: [String: (real: String?, at: UInt64)] = [:]
        private var stream: FSEventStreamRef?
        private var watch: Watch?
        private var watched: [String: URL] = [:]
        /// The pause before a stream that could not be made is tried again, and whether a try is on its way.
        private var retryDelay = Core.firstRetry
        private var isRetryPending = false
        private static let firstRetry = 0.5, longestRetry = 30.0

        /// How long a failed resolution counts, and how long the stream waits for a slow one.
        private static let failureLifetime: UInt64 = 5_000_000_000
        private static let resolutionPatience = 2.0

        init(queue: DispatchQueue, recursive: Bool, onChange: @escaping ([URL]) -> Void) {
            (self.queue, self.onChange, isRecursive) = (queue, onChange, recursive)
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
            let wanted = Set(desired.map { DirectoryWatcher.trimmed($0.path) })
            let now = DispatchTime.now().uptimeNanoseconds
            resolutions = resolutions.filter { wanted.contains($0.key) }
            let missing = wanted.filter { path in
                guard let known = resolutions[path] else { return true }
                return known.real == nil && now &- known.at > Core.failureLifetime
            }
            guard !missing.isEmpty else { return reconcile() }
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
            control.asyncAfter(deadline: .now() + Core.resolutionPatience) { [self] in reconcile() }
        }

        /// Makes the stream match what is wanted and has been resolved.
        private func reconcile() {
            guard !gate.isStopped else { return }
            let pairs = desired.compactMap { directory -> (String, URL)? in
                let key = DirectoryWatcher.trimmed(directory.path)
                guard let known = resolutions[key] else { return nil }
                return (known.real ?? key, directory)
            }
            let resolved = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
            guard resolved != watched else { return }
            tearDown()
            guard !resolved.isEmpty else { return }
            let watch = Watch(watched: resolved, recursive: isRecursive, queue: queue, streamQueue: streamQueue, gate: gate, onChange: onChange)
            // The stream holds its own reference to the state, taken and given back through these.
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(watch).toOpaque(),
                retain: { info in
                    if let info { _ = Unmanaged<Watch>.fromOpaque(info).retain() }
                    return info
                },
                release: { info in
                    if let info { Unmanaged<Watch>.fromOpaque(info).release() }
                },
                copyDescription: nil)
            // Plain C strings and not a bridged array: below the home folder or the root there
            // are thousands of reports a second, and only a few name a watched folder.
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                guard let info else { return }
                Unmanaged<Watch>.fromOpaque(info).takeUnretainedValue()
                    .report(count: count, paths: paths.assumingMemoryBound(to: UnsafePointer<CChar>.self), flags: flags)
            }
            let flags = UInt32(kFSEventStreamCreateFlagWatchRoot)
            guard let stream = FSEventStreamCreate(nil, callback, &context, Array(resolved.keys) as CFArray,
                                                   FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else {
                // Not remembered as watched: the next request tries again, and so does this.
                Census.wasRefused()
                return retryLater()
            }
            FSEventStreamSetDispatchQueue(stream, streamQueue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                Census.wasRefused()
                return retryLater()
            }
            Census.started()
            (self.stream, self.watch, watched) = (stream, watch, resolved)
            retryDelay = Core.firstRetry
        }

        /// The system did not give a stream (it has only so many for all programs together,
        /// and they may all be taken for a while): without one the folders would stay
        /// unwatched until somebody asks for another set. Tried again after a pause that
        /// grows, for as long as the watcher lives.
        private func retryLater() {
            guard !isRetryPending, !gate.isStopped else { return }
            isRetryPending = true
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, Core.longestRetry)
            control.asyncAfter(deadline: .now() + delay) { [self] in
                isRetryPending = false
                reconcile()
            }
        }

        private func tearDown() {
            watch?.stop()
            watch = nil
            watched = [:]
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            // A report that is being sifted at this moment is finished before the stream goes.
            streamQueue.sync {}
            FSEventStreamRelease(stream)
            self.stream = nil
            Census.ended()
        }
    }

    private let core: Core

    /// `onChange` receives the watched folders whose contents changed, on `queue`. With
    /// `recursive`, a watched folder is reported for a change anywhere below it as well.
    init(queue: DispatchQueue = .main, recursive: Bool = false, onChange: @escaping ([URL]) -> Void) {
        core = Core(queue: queue, recursive: recursive, onChange: onChange)
    }

    deinit { core.stop() }

    /// Replaces the set of watched folders. Only their direct contents are reported, unless
    /// the watcher was made `recursive`. Returns at once; the stream follows in the background.
    func watch(_ directories: [URL]) {
        core.request(directories)
    }

    func stop() {
        core.stop()
    }

    /// May wait for the file system: never on the caller's thread.
    private static func resolve(_ path: String) -> String? {
        // realpath, because the system reports /private/tmp where Foundation says /tmp.
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return trimmed(String(cString: real))
    }

    private static func trimmed(_ path: String) -> String {
        path.utf8.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
