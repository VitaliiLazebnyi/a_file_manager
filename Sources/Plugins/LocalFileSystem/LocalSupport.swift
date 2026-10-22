import AFMKernel
import Foundation

/// Lets another thread end a system call this thread is blocked in (an `open`, `read` or
/// `write` on a share that has stopped answering), by a signal that does nothing except
/// interrupt the call.
///
/// Used by the local readers and writers for `interrupt()`, and by the opening calls for the
/// `CancellationFlag` they are given.
///
/// The signal is only ever sent to a thread that has announced, with `begin()`, that it is
/// inside one call; a signal that comes a moment too early is sent again until the call is
/// over. **Thread-safe**; `interrupt()` returns at once. All state is guarded by `lock`.
internal final class Interruption: @unchecked Sendable {
    /// Runs `work` once `delay` seconds have passed, on another thread.
    internal typealias Schedule = @Sendable (_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Void

    /// A handler that does nothing, installed without `SA_RESTART`: the call it interrupts
    /// returns `EINTR` instead of carrying on.
    ///
    /// (Installing a handler for a valid signal does not fail.).
    private static let installed: Void = {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in }
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        sigaction(SIGURG, &action, nil)
    }()

    private let lock = NSLock()
    private var thread: pthread_t?
    private var interrupted = false
    /// Where the signal is sent again: the local file system's clock.
    private let schedule: Schedule

    internal var isInterrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }

    /// An interruption that sends its signal again on the local file system's clock.
    internal convenience init() {
        self.init { delay, work in LocalClock.queue.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    /// An interruption that sends its signal again where `schedule` says (tests count the times).
    internal init(schedule: @escaping Schedule) {
        self.schedule = schedule
    }

    /// The calling thread is about to make a call that may wait.
    ///
    /// False when `interrupt` was called already: the call is not to be made.
    internal func begin() -> Bool {
        Self.installed
        // Some threads (those of Swift's concurrency pool) have it blocked, and then it would not arrive.
        var signals = sigset_t()
        sigemptyset(&signals)
        sigaddset(&signals, SIGURG)
        pthread_sigmask(SIG_UNBLOCK, &signals, nil)
        lock.lock()
        defer { lock.unlock() }
        if interrupted {
            return false
        }
        thread = pthread_self()
        return true
    }

    internal func end() {
        lock.lock()
        thread = nil
        lock.unlock()
    }

    internal func interrupt() {
        lock.lock()
        interrupted = true
        let target = thread
        if let target { pthread_kill(target, SIGURG) }
        lock.unlock()
        if target != nil { resend(attempt: 1) }
    }

    /// The call may not have been entered yet when the first signal arrived.
    private func resend(attempt: Int) {
        guard attempt <= 50 else {
            return
        }
        schedule(0.1) { [self] in
            lock.lock()
            let target = thread
            if let target { pthread_kill(target, SIGURG) }
            lock.unlock()
            if target != nil { resend(attempt: attempt + 1) }
        }
    }

    /// Runs `call` (one system call, returning a negative number and setting `errno` on
    /// failure), again after an `EINTR` that nobody asked for.
    ///
    /// Throws `userCancelled` once interrupted. Returns the result, or a negative number with
    /// `errno` set.
    internal func run(_ call: () -> Int) throws -> Int {
        var (result, code): (Int, Int32)
        repeat {
            guard begin() else { throw CocoaError(.userCancelled) }
            result = call()
            code = errno
            end()
            if result < 0, code == EINTR, isInterrupted { throw CocoaError(.userCancelled) }
        } while result < 0 && code == EINTR
        errno = code
        return result
    }
}

/// The mounted file systems, as the kernel lists them.
///
/// Reading the list never touches a mounted disk (`MNT_NOWAIT`), so it is safe to ask on any thread
/// about a path on a share that has stopped answering. Kept for a moment and then read again. All
/// state is guarded by `lock`.
internal final class MountTable: @unchecked Sendable {
    internal static let shared = MountTable()

    internal struct Mount {
        internal let path: String
        /// A disk of this Mac.
        ///
        /// False for shares, and for automounted paths, which look local and fetch their contents
        /// from a server on first use.
        internal let isLocal: Bool
    }

    private let lock = NSLock()
    private var mounts: [Mount] = []
    private var read: UInt64 = 0
    private static let lifetime: UInt64 = 2_000_000_000

    /// Called with the lock held.
    private func refresh() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard read == 0 || now &- read > Self.lifetime else {
            return
        }
        mounts = Self.readMounts()
        read = now
    }

    /// The start-up disk, on which every path lies that lies on no other mount.
    internal static let root = Mount(path: "/", isLocal: true)

    /// The mount a path lies on (by its text: the path is not looked at on disk).
    internal func mount(containing path: String) -> Mount {
        lock.lock()
        refresh()
        let current = mounts
        lock.unlock()
        return current.first { mount in path == mount.path || path.hasPrefix(mount.path + "/") } ?? Self.root
    }

    internal func isLocal(_ path: String) -> Bool { mount(containing: path).isLocal }

    private static func readMounts() -> [Mount] {
        // (A failure, -1, counts as none.)
        let count = max(getfsstat(nil, 0, MNT_NOWAIT), 0)
        var buffer = [Darwin.statfs](repeating: Darwin.statfs(), count: Int(count) + 8)
        let size = Int32(buffer.count * MemoryLayout<statfs>.stride)
        let filled = max(getfsstat(&buffer, size, MNT_NOWAIT), 0)
        let mounts = buffer.prefix(Int(filled))
            .map { info -> Mount in
                var info = info
                let path = withUnsafeBytes(of: &info.f_mntonname) {
                    String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
                }
                let type = withUnsafeBytes(of: &info.f_fstypename) {
                    String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
                }
                let isLocal =
                    info.f_flags & UInt32(MNT_LOCAL) != 0 && info.f_flags & UInt32(MNT_AUTOMOUNTED) == 0
                    && type != "autofs"
                return Mount(path: path, isLocal: isLocal)
            }
        // The deepest mount first, so that the first that contains a path is the one it is on;
        // the start-up disk is `root`.
        return mounts.filter { $0.path != "/" }.sorted { $0.path.utf8.count > $1.path.utf8.count }
    }
}

/// What a symbolic link leads to.
internal struct LinkTarget {
    internal var isDirectory: Bool
    internal var isRegular: Bool
    /// The size of the target when it is a regular file.
    internal var size: Int64
    internal var isSpecial: Bool { !isDirectory && !isRegular }
}

/// Finds out where links lead without letting a link into a share that does not answer hold
/// up a listing.
///
/// A target on a disk of this Mac is asked for at once; one anywhere else is asked for on a thread
/// of its own and waited for for a moment only. A few such questions may be stuck for good (each
/// holds a thread until the share answers); past that limit links into places that are not local
/// are no longer followed. All state is guarded by `lock`.
internal final class LinkResolver: @unchecked Sendable {
    internal static let shared = LinkResolver()

    private let lock = NSLock()
    private var inFlight = 0
    /// How many questions into places that are not disks of this Mac may be under way at once.
    internal static let limit = 8
    private let patience: TimeInterval
    /// Asks the system where a link leads (`stat`); it may wait for as long as the volume does.
    private let lookup: @Sendable (String) -> LinkTarget?

    /// Asks the system, and waits a moment and a half for a place that is not a disk of this Mac.
    internal convenience init() {
        self.init(patience: 1.5, lookup: Self.lookup)
    }

    /// `lookup` and `patience` stand in for the system and its moment when a test makes a share
    /// that does not answer.
    internal init(patience: TimeInterval, lookup: @escaping @Sendable (String) -> LinkTarget?) {
        (self.patience, self.lookup) = (patience, lookup)
    }

    /// Nil when the target does not exist (a dangling link) or did not answer in time.
    internal func resolve(_ path: String) -> LinkTarget? {
        if let target = Self.absoluteTarget(of: path), MountTable.shared.isLocal(target) {
            return lookup(path)
        }
        lock.lock()
        guard inFlight < Self.limit else {
            lock.unlock()
            return nil
        }
        inFlight += 1
        lock.unlock()
        /// All state is guarded by `lock`.
        final class Answer: @unchecked Sendable {
            let lock = NSLock()
            var target: LinkTarget?
        }
        let answer = Answer()
        let done = DispatchSemaphore(value: 0)
        // A thread of the kernel's own: one that never comes back is not one of a dispatch queue's few.
        let ask = lookup
        BlockingCalls.run {
            let target = ask(path)
            answer.lock.lock()
            answer.target = target
            answer.lock.unlock()
            self.lock.lock()
            self.inFlight -= 1
            self.lock.unlock()
            done.signal()
        }
        guard done.wait(timeout: .now() + patience) == .success else {
            return nil
        }
        answer.lock.lock()
        defer { answer.lock.unlock() }
        return answer.target
    }

    /// What the link at `path` leads to, as the system says (`stat`); nil when nothing is there.
    internal static func lookup(_ path: String) -> LinkTarget? {
        var st = stat()
        guard stat(path, &st) == 0 else {
            return nil
        }
        let type = st.st_mode & S_IFMT
        return LinkTarget(
            isDirectory: type == S_IFDIR,
            isRegular: type == S_IFREG,
            size: type == S_IFREG ? Int64(st.st_size) : 0
        )
    }

    /// Where the link says it points, as an absolute path, worked out from the text of the
    /// link alone (the target is not looked at).
    ///
    /// Nil when the link cannot be read.
    private static func absoluteTarget(of path: String) -> String? {
        let text: String? = withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(PATH_MAX) + 1) { buffer in
            let length = readlink(path, buffer.baseAddress, Int(PATH_MAX))
            guard length > 0 else {
                return nil
            }
            buffer[length] = 0
            return String(validatingCString: buffer.baseAddress!)
        }
        guard let text else {
            return nil
        }
        var absolute = text
        // By bytes, as the file system reads a path: a `/` with a combining mark after it is
        // one character that is not `/`, and a cut by characters would not see it.
        if text.utf8.first != 0x2F {
            // The folder of the link: everything before its last `/` (nothing for a bare name).
            let directory = Array(path.utf8)
                .split(separator: 0x2F, omittingEmptySubsequences: false)
                .dropLast()
                .joined(separator: [0x2F])
            absolute = String(decoding: Array(directory), as: UTF8.self) + "/" + text
        }
        var parts: [ArraySlice<UInt8>] = []
        for part in Array(absolute.utf8).split(separator: 0x2F) {
            if part.elementsEqual([0x2E]) { continue }
            if part.elementsEqual([0x2E, 0x2E]) { _ = parts.popLast() } else { parts.append(part) }
        }
        return "/" + parts.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "/")
    }
}

/// What the local file system does to the thread it runs on.
extension LocalFileSystem {
    /// Runs `body` with the materialising of files that are only on a server (iCloud Drive,
    /// File Provider) switched off for this thread: a walk that measures a tree must not
    /// make the system download it.
    ///
    /// A folder that is not there yet then counts as nothing.
    internal static func withoutMaterializing<T>(_ body: () -> T) -> T {
        // IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES = 3, IOPOL_MATERIALIZE_DATALESS_FILES_OFF = 1, _DEFAULT = 0
        let kind: Int32 = 3
        let scope = IOPOL_SCOPE_THREAD
        // (The policy of the thread itself can always be read; a failure would mean the default.)
        let previous = max(getiopolicy_np(kind, scope), 0)
        setiopolicy_np(kind, scope, 1)
        defer { setiopolicy_np(kind, scope, previous) }
        return body()
    }
}

/// Stand-ins for what the system says about a volume, so that tests can put a volume that
/// has stopped answering, or a disk of a known size, in the place of a real one.
///
/// Set before the file system is used, never afterwards; nil everywhere in the program itself.
internal struct LocalProbes {
    /// Called with a path just before the system is asked about it in a way that can wait on
    /// the volume: a test blocks here for the paths of its "dead" volume.
    internal var willAsk: (@Sendable (String) -> Void)?
    /// Whether a path is on a disk of this Mac; nil (the closure or its answer) asks the
    /// mount table.
    internal var isLocal: (@Sendable (String) -> Bool?)?
    /// The free space of the volume at a path, plainly free and free for important uses;
    /// nil asks the system.
    internal var freeSpace: (@Sendable (String) -> (available: Int64?, important: Int64?))?
    /// How long a change on a volume that is not a disk of this Mac is waited for after it
    /// was cancelled, in seconds, before the caller goes on without it.
    internal var patienceAfterCancel: TimeInterval = 2
    /// How long a question about a volume (its name, its free space) is waited for before it
    /// is answered from what was last known.
    internal var volumePatience: TimeInterval = 3
    /// How long a reading of the places may take before it is given up, in seconds.
    internal var placesPatience: TimeInterval = 8
    /// Called with every step the system reports while it copies a file (what it copies, and
    /// the stage); true stops the copy there, as the caller's flag would.
    ///
    /// A test cannot choose the moment at which a flag it sets is seen.
    internal var copyStops: (@Sendable (_ what: Int32, _ stage: Int32) -> Bool)?
    /// The home folder whose places are listed; nil is the user's.
    internal var home: URL?
    /// Failures of the system that no test can bring about on a healthy disk of this Mac (a share
    /// that reports a write error only when the file is closed, a volume without bulk reads): for
    /// the name of a system call and the path it is about, the error number it fails with instead
    /// of being made; nil makes the call.
    internal var fault: (@Sendable (_ call: String, _ path: String) -> Int32?)?

    /// Makes the system call `call`, unless `fault` has it fail: the result is then -1, with
    /// `errno` set.
    internal func system<Result: SignedInteger>(_ name: String, _ path: String, _ call: () -> Result) -> Result {
        if let code = fault?(name, path) {
            errno = code
            return -1
        }
        return call()
    }
}

/// One call of the file system that changes something, and the system calls it is made of.
///
/// Each system call that may wait on the volume goes through `run`: it can then be ended by
/// `interruption` (from another thread, when the caller's flag is set), and none is begun once that
/// has happened. What must be done whatever happens (putting a lock back) is called directly
/// instead.
internal final class LocalCall: Sendable {
    internal let interruption = Interruption()
    private let willAsk: (@Sendable (String) -> Void)?

    internal init(_ probes: LocalProbes) {
        willAsk = probes.willAsk
    }

    /// Runs one system call on `path` that returns a negative number and sets `errno` on
    /// failure.
    ///
    /// Returns its result, with `errno` set on failure; throws `userCancelled` once interrupted.
    internal func run(_ path: String, _ call: () -> Int32) throws -> Int32 {
        willAsk?(path)
        return Int32(try interruption.run { Int(call()) })
    }

    /// The same for a call that must not be made a second time when a signal nobody sent
    /// ends it early (a copy that has made its file already): the `EINTR` is the caller's.
    internal func runOnce(_ path: String, _ call: () -> Int32) throws -> Int32 {
        willAsk?(path)
        guard interruption.begin() else { throw CocoaError(.userCancelled) }
        let result = call()
        let code = errno
        interruption.end()
        errno = code
        return result
    }
}

/// Changes on volumes that are not disks of this Mac (shares, automounted folders), for
/// callers that hold a `CancellationFlag`.
///
/// A system call into a share whose server has gone can wait for as long as the system
/// likes, and a signal ends it only where the volume was mounted to allow that. So such a
/// change is made on a thread of the kernel's own while the caller waits for it: when the
/// flag is set, the call is sent the signal, waited for for a moment more, and then left
/// behind. The caller gets `userCancelled` and is free; the thread stays with the call until
/// the system lets it go.
///
/// **What that means for the change:** a call that was left behind is not known to have
/// failed. It makes no further system call once it comes back, but the one it was in may
/// still take effect when the server answers again. Whoever cancels takes nothing for done
/// and nothing for undone, as with any cancelled call.
///
/// A volume with several calls left behind is not asked again until one of them returns:
/// further changes there fail at once (`ETIMEDOUT`), instead of costing a thread each.
/// All state is guarded by `lock`.
internal final class RemoteChanges: @unchecked Sendable {
    internal static let shared = RemoteChanges()

    /// The most calls on one volume that may be left behind at a time.
    internal static let limit = 4

    private let lock = NSLock()
    /// Volume → the calls that were left behind and have not come back.
    private var stranded: [String: Int] = [:]

    internal func strandedCalls(on volume: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return stranded[volume] ?? 0
    }

    /// Where the call's thread leaves its result, and learns that nobody waits for it.
    ///
    /// All state is guarded by `lock`.
    private final class Outcome<Value: Sendable>: @unchecked Sendable {
        let lock = NSLock()
        var result: Result<Value, any Error>?
        var isLeftBehind = false
    }

    internal func run<Value: Sendable>(
        on volume: String,
        patience: TimeInterval,
        cancellation: CancellationFlag,
        _ call: LocalCall,
        _ body: @escaping @Sendable (LocalCall) throws -> Value
    ) throws -> Value {
        lock.lock()
        let isDead = (stranded[volume] ?? 0) >= Self.limit
        lock.unlock()
        if isDead {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ETIMEDOUT),
                userInfo: [NSLocalizedDescriptionKey: "The volume at \(volume) does not answer."]
            )
        }
        let box = Outcome<Value>()
        let done = DispatchSemaphore(value: 0)
        BlockingCalls.run { [self] in
            let result = Result { try body(call) }
            box.lock.lock()
            box.result = result
            let wasLeftBehind = box.isLeftBehind
            box.lock.unlock()
            if wasLeftBehind {
                lock.lock()
                if let count = stranded[volume] { stranded[volume] = count > 1 ? count - 1 : nil }
                lock.unlock()
            }
            done.signal()
        }
        func finished() -> Result<Value, any Error>? {
            box.lock.lock()
            defer { box.lock.unlock() }
            return box.result
        }
        // Woken by the end of the call, or by the flag.
        let registration = cancellation.onCancel { done.signal() }
        defer { withExtendedLifetime(registration) {} }
        done.wait()
        if let result = finished() {
            return try result.get()
        }
        // Cancelled. The call has been sent its signal; it gets a moment to come back.
        call.interruption.interrupt()
        _ = done.wait(timeout: .now() + patience)
        box.lock.lock()
        if let result = box.result {
            box.lock.unlock()
            return try result.get()
        }
        // Counted before the call can see that it was left behind, so that its return takes
        // the count down again and never comes first.
        box.isLeftBehind = true
        lock.lock()
        stranded[volume, default: 0] += 1
        lock.unlock()
        box.lock.unlock()
        throw CocoaError(.userCancelled)
    }
}

/// A value that several threads share, behind a lock.
///
/// All state is guarded by `lock`.
internal final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    internal init(_ value: Value) { self.value = value }

    @discardableResult
    internal func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// The local file system's own clock: what has to happen "a moment later" whatever else the
/// program is doing (the second signal to a call that is to be ended, giving up on a
/// question nobody answers).
///
/// Not the system's shared queues: when all their threads are taken by work that waits, nothing put
/// on them runs, and these are the steps that free such threads. Nothing on this queue ever waits
/// for anything.
internal enum LocalClock {
    internal static let queue = DispatchQueue(label: "AFM.LocalFileSystem.clock", qos: .userInitiated)
}
