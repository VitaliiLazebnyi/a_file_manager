import AFMKernel
import AppKit

/// The way back to the main thread for everything that may end in a dialog.
///
/// A modal dialog runs an event loop of its own. Started from inside a block of the main
/// dispatch queue, that loop cannot run the blocks queued behind it (the queue is serial and
/// its current block has not returned), so for as long as the dialog is up nothing that was
/// dispatched to the main thread arrives: no piece of a directory, no progress, no timer of
/// the queue. Started from the run loop, the dialog's loop serves the queue like any other.
/// So whatever the shell brings to the main thread and hands on to code that may ask the
/// user something (the end of a reading, of a job, a drop) comes through here.
enum MainLoop {
    /// Runs `block` on the main thread, from the run loop and not from the main dispatch
    /// queue, in every mode a dialog or a menu runs the loop in. Blocks run in the order they
    /// were handed in. Safe to call from any thread.
    static func perform(_ block: @escaping @MainActor @Sendable () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated(block)
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// The same for a block made on the main thread, which may hold what belongs to it: it
    /// waits for its turn in a `MainOwned` box, and runs and is let go of on the main thread.
    @MainActor static func queue(_ block: @escaping @MainActor () -> Void) {
        let owned = MainOwned(block)
        perform { owned.take()?() }
    }

    /// The same after a delay; the returned function calls it off. Main thread only.
    @MainActor @discardableResult
    static func after(_ delay: TimeInterval, _ block: @escaping @MainActor () -> Void) -> () -> Void {
        // The timer is on the main run loop, so it fires on the main thread.
        let timer = Timer(timeInterval: max(0, delay), repeats: false) { _ in MainActor.assumeIsolated(block) }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    /// Blocks that open a dialog, waiting for their turn.
    @MainActor private static var dialogs: [@MainActor () -> Void] = []
    @MainActor private static var dialogIsUp = false

    /// Runs a block that tells or asks the user something with a dialog: from the run loop,
    /// and never while the dialog of an earlier such block is still on screen, so two panels
    /// that fail at the same moment show their messages one after the other and not one on
    /// top of the other. Main thread only.
    @MainActor static func dialog(_ block: @escaping @MainActor () -> Void) {
        dialogs.append(block)
        perform { showNextDialog() }
    }

    @MainActor private static func showNextDialog() {
        guard !dialogIsUp, !dialogs.isEmpty else { return }
        dialogIsUp = true
        dialogs.removeFirst()()
        dialogIsUp = false
        if !dialogs.isEmpty { perform { showNextDialog() } }
    }
}

/// Something that belongs to the main thread, carried through a background thread: it is put
/// in and taken out on the main thread, so it is also let go of there, whichever thread
/// drops the box last. Closures that hold a panel or a model travel this way.
///
/// Unchecked: the value is put in by `init`, before the box is shared, and taken out on the
/// main thread only. `held` is read on the main thread, or by a thread that was started after
/// the box was filled and whose result alone makes the main thread take the value out
/// (`ProgressJobService.run`).
final class MainOwned<Value>: @unchecked Sendable {
    private var value: Value?

    init(_ value: Value) { self.value = value }

    /// Main thread: the value, which stays in the box.
    var held: Value? { value }

    /// Main thread: the value, which leaves the box.
    func take() -> Value? {
        defer { value = nil }
        return value
    }
}

/// The program's own threads for work off the main thread.
///
/// Nothing here uses the system's shared pool (`DispatchQueue.global`): a call into a file
/// system can wait for as long as a dead server or a sleeping disk pleases, and once enough
/// threads of the shared pool wait like that, nothing in the whole program gets a thread any
/// more. Work that may wait on storage therefore runs on threads made for it (the kernel's
/// `BlockingCalls` threads), in lanes: one lane per purpose and location, one call at a time
/// in each. A location that does not answer
/// holds up its own lane and nothing else, and a second call for it never starts before the
/// first has come back. Work that only computes has a small pool of its own.
///
/// Safe to use from any thread: the lanes and the pool are guarded by `lock`.
enum Background {
    private static let lock = NSLock()
    /// The work waiting in each lane that has a thread; a lane without work has no entry.
    nonisolated(unsafe) private static var lanes: [String: [@Sendable () -> Void]] = [:]
    nonisolated(unsafe) private static var computing: [@Sendable () -> Void] = []
    nonisolated(unsafe) private static var computeThreads = 0
    private static let computeLimit = max(2, ProcessInfo.processInfo.activeProcessorCount)

    /// Whether the lane of this purpose and location is at work or has work waiting.
    static func isBusy(_ purpose: String, at location: URL) -> Bool {
        let key = laneKey(purpose, location)
        lock.lock()
        defer { lock.unlock() }
        return lanes[key] != nil
    }

    private static func laneKey(_ purpose: String, _ location: URL) -> String {
        purpose + "|" + location.locationKey
    }

    /// Runs `work`, which may wait on the file system of `location`, in the lane of that
    /// purpose and location: after whatever was handed in for it before. A lane at work has
    /// one of the kernel's threads for calls that block (`BlockingCalls.run`), which are kept
    /// for the next lane when this one is done, so a run of short calls starts no thread each.
    static func storage(
        _ purpose: String,
        at location: URL,
        qos: QualityOfService = .userInitiated,
        _ work: @escaping @Sendable () -> Void
    ) {
        let key = laneKey(purpose, location)
        lock.lock()
        if lanes[key] != nil {
            lanes[key]?.append(work)
            lock.unlock()
            return
        }
        lanes[key] = []
        lock.unlock()
        BlockingCalls.run {
            // The thread is the kernel's and goes back to it as it came. While it is here it
            // bears the lane's name, for whoever looks at what the program is doing.
            let borrowed = Thread.current.name
            Thread.current.name = "afm." + purpose
            defer { Thread.current.name = borrowed }
            let lowered = qos == .utility || qos == .background
            if lowered {
                pthread_set_qos_class_self_np(qos == .background ? QOS_CLASS_BACKGROUND : QOS_CLASS_UTILITY, 0)
            }
            var next: (@Sendable () -> Void)? = work
            while let job = next {
                autoreleasepool { job() }
                lock.lock()
                if lanes[key]?.isEmpty == false {
                    next = lanes[key]?.removeFirst()
                } else {
                    lanes[key] = nil
                    next = nil
                }
                lock.unlock()
            }
            if lowered { pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0) }
        }
    }

    /// The same for work with a result: `work` runs in the lane and must hold nothing that
    /// belongs to the main thread; `then` receives what it returned on the main thread, from
    /// the run loop (`MainLoop`), and is let go of there.
    static func storage<Value: Sendable>(
        _ purpose: String,
        at location: URL,
        qos: QualityOfService = .userInitiated,
        work: @escaping @Sendable () -> Value,
        then: @escaping @MainActor (Value) -> Void
    ) {
        let receiver = MainOwned(then)
        storage(purpose, at: location, qos: qos) {
            let value = work()
            MainLoop.perform { receiver.take()?(value) }
        }
    }

    /// Runs work that only computes (sorting, filtering, searching a list) on the pool.
    static func compute(_ work: @escaping @Sendable () -> Void) {
        lock.lock()
        computing.append(work)
        let starts = computeThreads < computeLimit
        if starts { computeThreads += 1 }
        lock.unlock()
        guard starts else { return }
        start(named: "afm.compute", qos: .userInitiated) {
            while true {
                lock.lock()
                guard !computing.isEmpty else {
                    computeThreads -= 1
                    lock.unlock()
                    return
                }
                let job = computing.removeFirst()
                lock.unlock()
                autoreleasepool { job() }
            }
        }
    }

    /// The same with a result for the main thread (see `storage(_:at:qos:work:then:)`).
    static func compute<Value: Sendable>(
        work: @escaping @Sendable () -> Value,
        then: @escaping @MainActor (Value) -> Void
    ) {
        let receiver = MainOwned(then)
        compute {
            let value = work()
            MainLoop.perform { receiver.take()?(value) }
        }
    }

    /// Starts a thread of the program's own; also for the single pieces of work that get one
    /// each (a file job).
    static func start(named name: String, qos: QualityOfService, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.qualityOfService = qos
        // As much as the system gives the main thread's helpers; sorting and walking trees recurse.
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// Lets go of something large (the list of a folder with a million entries) on a
    /// background thread: freeing it takes long enough to be felt on the main thread. The
    /// variable is emptied here; if nobody else holds the value, it is freed over there.
    static func release<Value>(_ value: inout Value?) {
        guard value != nil else { return }
        let box = ReleaseBox<Value>()
        swap(&box.value, &value)
        compute { box.value = nil }
    }

    /// Unchecked: emptied on the background thread only, after this thread has let go.
    private final class ReleaseBox<Value>: @unchecked Sendable {
        var value: Value?
    }
}

/// Where the volumes of the local file system are mounted and which of them are on this
/// machine. The system answers from what it has in memory, without asking any disk or server
/// (`MNT_NOWAIT`), so this may be asked on the main thread; the answer is kept for a moment,
/// because lists ask for every row they draw. Safe to use from any thread.
enum Mounts {
    struct Volume: Equatable {
        let path: String
        /// False for network shares.
        let isLocal: Bool
    }

    private static let lock = NSLock()
    /// Guarded by `lock`.
    nonisolated(unsafe) private static var cached: (at: TimeInterval, volumes: [Volume])?
    static let lifetime: TimeInterval = 2

    static func volumes() -> [Volume] {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if let cached, now - cached.at < lifetime { return cached.volumes }
        // The system's list lives in a buffer of its own that the next call overwrites; the
        // lock keeps the calls apart.
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        var volumes: [Volume] = []
        if count > 0, let buffer {
            volumes = (0..<Int(count))
                .map { index in
                    let path = withUnsafePointer(to: &buffer[index].f_mntonname) { pointer in
                        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                    }
                    return Volume(path: path, isLocal: buffer[index].f_flags & UInt32(MNT_LOCAL) != 0)
                }
        }
        if volumes.isEmpty { volumes = [Volume(path: "/", isLocal: true)] }
        cached = (now, volumes)
        return volumes
    }

    /// The volume a local path lies on: the one with the longest mount point that is a prefix of it.
    static func volume(of path: String, among volumes: [Volume]) -> Volume? {
        var best: Volume?
        for volume in volumes
        where volume.path == "/" || path == volume.path
            || (path.hasPrefix(volume.path) && path.utf8.count > volume.path.utf8.count
                && path.utf8[path.utf8.index(path.utf8.startIndex, offsetBy: volume.path.utf8.count)] == 0x2F)
        {
            if best == nil || volume.path.utf8.count > best!.path.utf8.count { best = volume }
        }
        return best
    }

    /// Whether a local path lies on a volume of this machine; true where the volume is not known.
    static func isLocal(path: String) -> Bool {
        volume(of: path, among: volumes())?.isLocal ?? true
    }
}

/// Names as they may be shown. A file's name is whatever its file system or a server says it
/// is, line breaks and writing-direction controls included: such a name can hide its real
/// ending behind a second line, or show its letters in another order (`exe.txt` for a name
/// that ends in `.exe`). For display, and only there, every such character is replaced by a
/// sign that can be seen.
enum DisplayText {
    /// `text` with control characters and direction controls made visible. Line breaks and
    /// tabs stay as they are with `keepingLines` (the text of a dialog).
    static func clean(_ text: String, keepingLines: Bool = false) -> String {
        // Nearly every name has none of them; that is found out from its bytes alone.
        let suspicious = text.utf8.contains { byte in
            byte < 0x20 || byte == 0x7F || byte == 0xC2 || byte == 0xD8 || byte == 0xE2
        }
        guard suspicious else { return text }
        var cleaned = String.UnicodeScalarView()
        var changed = false
        for scalar in text.unicodeScalars {
            if let replacement = replacement(for: scalar, keepingLines: keepingLines) {
                cleaned.append(replacement)
                changed = true
            } else {
                cleaned.append(scalar)
            }
        }
        return changed ? String(cleaned) : text
    }

    private static func replacement(for scalar: Unicode.Scalar, keepingLines: Bool) -> Unicode.Scalar? {
        switch scalar.value {
        case 0x0A, 0x09, 0x0D:
            return keepingLines ? nil : Unicode.Scalar(0x2400 + scalar.value)

        case 0x00...0x1F:
            // The "control pictures": ␀ ␁ … ␛.
            return Unicode.Scalar(0x2400 + scalar.value)

        case 0x7F:
            return "\u{2421}"

        case 0x80...0x9F, 0x061C, 0x200E, 0x200F, 0x2028, 0x2029, 0x202A...0x202E, 0x2066...0x2069:
            return "\u{FFFD}"

        default:
            return nil
        }
    }
}
