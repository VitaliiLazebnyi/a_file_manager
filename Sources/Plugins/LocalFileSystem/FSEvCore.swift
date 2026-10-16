import AFMKernel
import CoreServices
import Foundation

/// Everything that is done to streams, on `control`. Held by the closures that are
/// still to run, so the watcher itself may go away at any moment.
///
/// Unchecked: what changes is only touched on `control`, one block at a time; the rest is
/// fixed in `init`.
internal final class FSEvCore: @unchecked Sendable {
    /// The pause before a stream that could not be made is tried again: the first, and the longest.
    private static let firstRetry = 0.5, longestRetry = 30.0
    /// How long a failed resolution counts, and how long the streams wait for a slow one.
    private static let failureLifetime: UInt64 = 5_000_000_000
    private static let resolutionPatience = 2.0

    /// Where `onChange` is called.
    internal let queue: DispatchQueue
    /// Receives the watched folders whose contents changed.
    internal let onChange: @Sendable ([URL]) -> Void
    /// Where everything is done to streams. Not at the lowest classes: while the program (or
    /// the machine) keeps every core busy with work of a higher class, queues of the utility
    /// class may get no thread for a long time, and a panel would then not hear of changes
    /// for as long. Setting a stream up is a few steps; sifting reports is a look at the
    /// length of each path.
    internal let control = DispatchQueue(label: "AFM.DirectoryWatcher.control", qos: .userInitiated)
    /// Where the reports arrive and are sifted.
    internal let streamQueue = DispatchQueue(label: "AFM.DirectoryWatcher", qos: .default)
    /// Set when the watcher stops.
    internal let gate = FSEvGate()
    /// What makes the streams.
    internal let system: FSEvSystem

    // Only touched on `control`.
    private var desired: [URL] = []
    /// What `realpath` said about a folder as asked for (nil: it could not be resolved,
    /// which is remembered for a few seconds only), and when.
    private var resolutions: [String: (real: String?, at: UInt64)] = [:]
    /// One stream for each watched folder (see `FSEvSystem` for why not one for all).
    private var streams: [FSEventStreamRef] = []
    private var watch: FSEvWatch?
    private var watched: [String: URL] = [:]
    /// The pause before a stream that could not be made is tried again, and whether a try is on its way.
    private var retryDelay = FSEvCore.firstRetry
    private var isRetryPending = false

    /// The folders the streams watch now, once what was asked before has been done.
    internal var watchedFolders: Set<URL> { control.sync { Set(watched.values) } }

    /// Calls `onChange` on `queue`; `system` makes the streams.
    internal init(queue: DispatchQueue, system: FSEvSystem, onChange: @escaping @Sendable ([URL]) -> Void) {
        (self.queue, self.system, self.onChange) = (queue, system, onChange)
    }

    /// May wait for the file system: never on the caller's thread.
    private static func resolve(_ path: String) -> String? {
        // realpath, because the system reports /private/tmp where Foundation says /tmp.
        // (A real path has no slash at the end.)
        guard let real = realpath(path, nil) else {
            return nil
        }
        defer { free(real) }
        return String(cString: real)
    }

    /// Watches `directories` from now on, instead of what was asked for before.
    internal func request(_ directories: [URL]) {
        control.async { [self] in
            guard !gate.isStopped else {
                return
            }
            desired = directories
            resolve()
        }
    }

    /// Ends the streams, for good.
    internal func stop() {
        gate.stop()
        control.async { [self] in tearDown() }
    }

    /// A started stream for each of `folders`, all handing their reports to `state`; none
    /// when the process has too few descriptors to spare, or the system does not make or
    /// start one of them (the ones made already are ended again).
    private func startedStreams(for state: FSEvWatch, folders: [String]) -> [FSEventStreamRef] {
        let cost = folders.reduce(0) { $0 + FSEvDescriptors.cost(of: $1) }
        guard system.spareDescriptors() - cost >= FSEvDescriptors.reserve else {
            return []
        }
        var made: [FSEventStreamRef] = []
        for folder in folders {
            guard let stream = startedStream(for: state, folder: folder) else {
                made.forEach(end)
                return []
            }
            made.append(stream)
        }
        return made
    }

    /// A stream of the reports about `folder`, running on `streamQueue` and handing them to
    /// `state`; nil when the system makes none or does not start it.
    private func startedStream(for state: FSEvWatch, folder: String) -> FSEventStreamRef? {
        // The stream holds its own reference to the state, taken and given back through these.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(state).toOpaque(),
            retain: { info in
                if let info { _ = Unmanaged<FSEvWatch>.fromOpaque(info).retain() }
                return info
            },
            release: { info in
                if let info { Unmanaged<FSEvWatch>.fromOpaque(info).release() }
            },
            copyDescription: nil
        )
        // Plain C strings and not a bridged array: below the home folder or the root there
        // are thousands of reports a second, and only a few name a watched folder.
        // (`info` is the context's, which is always set.)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            let target = Unmanaged<FSEvWatch>.fromOpaque(info.unsafelyUnwrapped).takeUnretainedValue()
            target.report(
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

    /// Asks for the real path of every folder not yet known, each on its own thread so that
    /// one that hangs holds up nothing but itself. The streams are made as soon as all have
    /// answered, or when the patience is spent without the ones that did not: those join
    /// when they do answer.
    private func resolve() {
        // (A URL's path has no slash at the end.)
        let wanted = Set(desired.map(\.path))
        let now = DispatchTime.now().uptimeNanoseconds
        resolutions = resolutions.filter { wanted.contains($0.key) }
        let missing = wanted.filter { path in
            guard let known = resolutions[path] else {
                return true
            }
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
                let real = Self.resolve(path)
                control.async { [self] in
                    resolutions[path] = (real, DispatchTime.now().uptimeNanoseconds)
                    group.leave()
                }
            }
        }
        group.notify(queue: control) { [self] in reconcile() }
        control.asyncAfter(deadline: .now() + Self.resolutionPatience) { [self] in reconcile() }
    }

    /// Makes the streams match what is wanted and has been resolved.
    private func reconcile() {
        guard !gate.isStopped else {
            return
        }
        // (A folder still being resolved is left out.)
        let pairs = desired.compactMap { directory in
            resolutions[directory.path].map { ($0.real ?? directory.path, directory) }
        }
        // A path the system cannot take is left out: it would not be watched, and the
        // system's failure would close descriptor 0 (see `FSEvSystem`).
        let resolved = Dictionary(pairs) { first, _ in first }.filter { FSEvDescriptors.fits($0.key) }
        guard resolved != watched else {
            return
        }
        tearDown()
        guard !resolved.isEmpty else {
            return
        }
        let fresh = FSEvWatch(watched: resolved, queue: queue, streamQueue: streamQueue, gate: gate, onChange: onChange)
        let started = startedStreams(for: fresh, folders: Array(resolved.keys))
        guard !started.isEmpty else {
            // Not remembered as watched: the next request tries again, and so does this.
            FSEvCensus.wasRefused()
            retryLater()
            return
        }
        for _ in started { FSEvCensus.started() }
        (streams, watch, watched) = (started, fresh, resolved)
        retryDelay = Self.firstRetry
    }

    /// The system did not give a stream (it has only so many for all programs together,
    /// and they may all be taken for a while): without one the folders would stay
    /// unwatched until somebody asks for another set. Tried again after a pause that
    /// grows, for as long as the watcher lives.
    private func retryLater() {
        // (A watcher stopped meanwhile does not try again: `reconcile` looks at the gate first.)
        guard !isRetryPending else {
            return
        }
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
            FSEvCensus.ended()
        }
        streams = []
    }

    private func end(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        streamQueue.sync {
            // A report that is being sifted at this moment is finished before the stream goes.
        }
        FSEventStreamRelease(stream)
    }

    deinit {
        // Nothing to release: `stop` ends the streams.
    }
}
