import AFMKernel
import Foundation

/// The program's own threads for work off the main thread.
///
/// Nothing here uses the system's shared pool (`DispatchQueue.global`): a call into a file
/// system can wait for as long as a dead server or a sleeping disk pleases, and once enough
/// threads of the shared pool wait like that, nothing in the whole program gets a thread any
/// more. Work that may wait on storage therefore runs on threads made for it (the kernel's
/// `BlockingCalls` threads), in lanes: one lane per purpose and location, one call at a time
/// in each. A location that does not answer holds up its own lane and nothing else, and a
/// second call for it never starts before the first has come back. Work that only computes
/// has a small pool of its own.
///
/// Safe to use from any thread: the lanes and the pool are guarded by `lock`.
internal enum Background {
    /// Unchecked: emptied on the background thread only, after this thread has let go.
    private final class ReleaseBox<Value>: @unchecked Sendable {
        /// What is to be freed over there.
        var value: Value?

        deinit {
            // The value goes with the box.
        }
    }

    /// Guards the lanes and the pool.
    private static let lock = NSLock()
    /// The work waiting in each lane that has a thread, guarded by `lock`; a lane without work
    /// has no entry.
    nonisolated(unsafe) private static var lanes: [String: [@Sendable () -> Void]] = [:]
    /// The work waiting for the pool, guarded by `lock`.
    nonisolated(unsafe) private static var computing: [@Sendable () -> Void] = []
    /// The threads of the pool, guarded by `lock`.
    nonisolated(unsafe) private static var computeThreads = 0
    /// The most threads the pool starts.
    private static let computeLimit = max(2, ProcessInfo.processInfo.activeProcessorCount)

    /// Runs `work`, which may wait on the file system of `location`, in the lane of that purpose
    /// and location.
    ///
    /// It runs after whatever was handed in for that lane before. A lane at work has one of the
    /// kernel's threads for calls that block (`BlockingCalls.run`), which are kept for the next
    /// lane when this one is done, so a run of short calls starts no thread each. `qos` is the
    /// thread's quality of service while it serves the lane.
    internal static func storage(
        _ purpose: String,
        at location: URL,
        qos: QualityOfService,
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
        BlockingCalls.run { serve(lane: key, named: "afm." + purpose, qos: qos, from: work) }
    }

    /// The same at the quality of service the user waits for.
    internal static func storage(_ purpose: String, at location: URL, _ work: @escaping @Sendable () -> Void) {
        storage(purpose, at: location, qos: .userInitiated, work)
    }

    /// The same for work with a result.
    ///
    /// `work` runs in the lane and must hold nothing that belongs to the main thread; `then`
    /// receives what it returned on the main thread, from the run loop (`MainLoop`), and is let
    /// go of there.
    internal static func storage<Value: Sendable>(
        _ purpose: String,
        at location: URL,
        qos: QualityOfService,
        work: @escaping @Sendable () -> Value,
        then: @escaping @MainActor (Value) -> Void
    ) {
        let receiver = MainOwned(then)
        storage(purpose, at: location, qos: qos) {
            let value = work()
            MainLoop.perform { receiver.take()?(value) }
        }
    }

    /// The same at the quality of service the user waits for.
    internal static func storage<Value: Sendable>(
        _ purpose: String,
        at location: URL,
        work: @escaping @Sendable () -> Value,
        then: @escaping @MainActor (Value) -> Void
    ) {
        storage(purpose, at: location, qos: .userInitiated, work: work, then: then)
    }

    /// Runs work that only computes (sorting, filtering, searching a list) on the pool.
    internal static func compute(_ work: @escaping @Sendable () -> Void) {
        lock.lock()
        computing.append(work)
        let starts = computeThreads < computeLimit
        if starts {
            computeThreads += 1
        }
        lock.unlock()
        guard starts else {
            return
        }
        start(named: "afm.compute", qos: .userInitiated) {
            while let job = nextComputation() {
                autoreleasepool { job() }
            }
        }
    }

    /// The same with a result for the main thread (see `storage(_:at:qos:work:then:)`).
    internal static func compute<Value: Sendable>(
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
    internal static func start(named name: String, qos: QualityOfService, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.qualityOfService = qos
        // As much as the system gives the main thread's helpers; sorting and walking trees recurse.
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// Lets go of something large (the list of a folder with a million entries) on a background
    /// thread.
    ///
    /// Freeing it takes long enough to be felt on the main thread. The variable is emptied
    /// here; if nobody else holds the value, it is freed over there.
    internal static func release<Value>(_ value: inout Value?) {
        guard value != nil else {
            return
        }
        let box = ReleaseBox<Value>()
        swap(&box.value, &value)
        compute { box.value = nil }
    }

    /// The key of the lane of `purpose` at `location`.
    private static func laneKey(_ purpose: String, _ location: URL) -> String {
        purpose + "|" + location.locationKey
    }

    /// Runs the lane's work, `first` and whatever is handed in behind it, on the calling thread
    /// until the lane is empty.
    ///
    /// The thread is the kernel's and goes back to it as it came. While it is here it bears the
    /// lane's name, for whoever looks at what the program is doing, and the lane's quality of
    /// service.
    private static func serve(
        lane key: String,
        named name: String,
        qos: QualityOfService,
        from first: @Sendable () -> Void
    ) {
        let borrowed = Thread.current.name
        Thread.current.name = name
        defer { Thread.current.name = borrowed }
        let lowered = loweredClass(for: qos)
        if let lowered {
            pthread_set_qos_class_self_np(lowered, 0)
        }
        autoreleasepool { first() }
        while let job = nextInLane(key) {
            autoreleasepool { job() }
        }
        if lowered != nil {
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
        }
    }

    /// The class a lane's thread is lowered to for `qos`; nil for the kernel threads' own.
    private static func loweredClass(for qos: QualityOfService) -> qos_class_t? {
        switch qos {
        case .utility:
            return QOS_CLASS_UTILITY

        case .background:
            return QOS_CLASS_BACKGROUND

        default:
            return nil
        }
    }

    /// The next piece of work of a lane; nil closes the lane.
    private static func nextInLane(_ key: String) -> (@Sendable () -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        guard lanes[key]?.isEmpty == false else {
            lanes[key] = nil
            return nil
        }
        return lanes[key]?.removeFirst()
    }

    /// The next piece of work for a thread of the pool; nil ends the thread.
    private static func nextComputation() -> (@Sendable () -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        guard !computing.isEmpty else {
            computeThreads -= 1
            return nil
        }
        return computing.removeFirst()
    }
}
