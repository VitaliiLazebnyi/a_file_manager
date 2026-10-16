import CoreServices
import Foundation

/// What a running stream needs, apart from the watcher: the stream keeps it alive itself,
/// so a report that is under way when the watcher stops or goes away finds everything
/// it touches still there. All the streams of one watcher share one.
///
/// Unchecked: what changes is guarded by `lock`; the rest is fixed in `init`.
internal final class FSEvWatch: @unchecked Sendable {
    /// A burst of reports is passed on once, this long after its first report; and never
    /// sooner than `minimumGap` after the previous one, however long the burst lasts
    /// (a build running below a watched folder). A report that says "look at everything"
    /// is given longer still.
    internal static let delay = 0.3, rescanDelay = 1.0, minimumGap = 0.5

    /// Resolved path as reported by the system → the directory the caller asked for.
    internal let watched: [String: URL]
    /// Where `onChange` is called.
    internal let queue: DispatchQueue
    /// Where the reports arrive and are sifted.
    internal let streamQueue: DispatchQueue
    /// Receives the watched folders whose contents changed.
    internal let onChange: @Sendable ([URL]) -> Void
    /// The lengths of the resolved paths: most reports are rejected on length alone,
    /// before any string is made of them.
    private let lengths: Set<Int>
    private let gate: FSEvGate
    private let lock = NSLock()
    private var stopped = false
    /// What changed and was not passed on yet, and whether a delivery is on its way.
    private var pending: [String: URL] = [:]
    private var isScheduled = false
    private var lastDelivery: UInt64 = 0

    /// Whether this watch or the whole watcher was stopped.
    internal var isStopped: Bool {
        lock.withLock { stopped || gate.isStopped }
    }

    /// Watches `watched` (resolved path → the folder as asked for).
    internal init(
        watched: [String: URL],
        queue: DispatchQueue,
        streamQueue: DispatchQueue,
        gate: FSEvGate,
        onChange: @escaping @Sendable ([URL]) -> Void
    ) {
        (self.watched, self.queue, self.streamQueue, self.gate, self.onChange) = (
            watched, queue, streamQueue, gate, onChange
        )
        lengths = Set(watched.keys.map(\.utf8.count))
    }

    /// Passes nothing on any more.
    internal func stop() {
        lock.withLock {
            stopped = true
            pending = [:]
        }
    }

    /// The system's reports; called on the stream's queue.
    internal func report(
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
            guard lengths.contains(length) else {
                continue
            }
            let buffer = UnsafeBufferPointer(
                start: UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self),
                count: length
            )
            // (A path that is not UTF-8 names no watched folder.)
            if let path = String(bytes: buffer, encoding: .utf8), let directory = watched[path] {
                changed[path] = directory
            }
        }
        if isRescan { changed = watched }
        guard !changed.isEmpty else {
            return
        }
        schedule(changed, isRescan: isRescan)
    }

    /// Notes what changed, and has it passed on unless a delivery is on its way already.
    private func schedule(_ changed: [String: URL], isRescan: Bool) {
        // A report that comes after the stop is dropped by `deliver`.
        let (mustSchedule, deadline) = lock.withLock {
            pending.merge(changed) { first, _ in first }
            let wasIdle = !isScheduled
            isScheduled = true
            let now = DispatchTime.now()
            let wanted = now.uptimeNanoseconds + UInt64((isRescan ? Self.rescanDelay : Self.delay) * 1e9)
            let earliest = lastDelivery == 0 ? 0 : lastDelivery + UInt64(Self.minimumGap * 1e9)
            return (wasIdle, DispatchTime(uptimeNanoseconds: max(wanted, earliest)))
        }
        guard mustSchedule else {
            return
        }
        streamQueue.asyncAfter(deadline: deadline) { self.deliver() }
    }

    private func deliver() {
        let (directories, wasStopped) = lock.withLock {
            let taken = Array(pending.values)
            pending = [:]
            isScheduled = false
            lastDelivery = DispatchTime.now().uptimeNanoseconds
            return (taken, stopped || gate.isStopped)
        }
        guard !directories.isEmpty, !wasStopped else {
            return
        }
        // A report that was on its way when the watcher stopped is dropped.
        queue.async { if !self.isStopped { self.onChange(directories) } }
    }

    deinit {
        // Nothing to release.
    }
}
