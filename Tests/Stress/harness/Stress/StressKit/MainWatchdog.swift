internal import Darwin
internal import Foundation

/// Pings the main dispatch queue every 2 ms from a thread of its own and records how long the main
/// thread took to answer.
///
/// An answer later than 8 ms is a stall. A stall that lasts 100 ms gets the main thread's stack
/// taken while it lasts (the thread is suspended for an instant and its frame pointers are walked),
/// and again at 1 s.
///
/// Unchecked: the phases, the statistics, the stalls and the stack budget are guarded by `lock`.
/// The main thread's port and stack bounds are written once in `start()`, before the watchdog thread
/// that reads them starts; the frame buffer is used by that thread alone.
public final class MainWatchdog: @unchecked Sendable {
    /// The upper bounds of the histogram's buckets, in milliseconds; the last bucket has none.
    public static let bounds: [Double] = [2, 4, 8, 16, 33, 100, 250, 1_000, 5_000]
    /// The one watchdog of the process.
    public static let shared = MainWatchdog()

    /// Guards the phases, the statistics, the stalls and the stack budget.
    private let lock = NSLock()
    /// The phase stalls are counted in now.
    private var phase = "start"
    /// The statistics of each phase.
    private var stats: [String: Stats] = [:]
    /// The phases in the order they began.
    private var order: [String] = []
    /// Every stall.
    private var stalls: [Stall] = []
    /// How many more stacks may be taken.
    private var stackBudget = 400
    /// The main thread's port.
    private var mainThread: thread_t = 0
    /// The lowest address of the main thread's stack.
    private var stackLow: UInt = 0
    /// The address just past the main thread's stack.
    private var stackHigh: UInt = 0
    /// When the watchdog was made.
    private let started = now()
    /// Room for the return addresses of one stack.
    private let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 256)

    /// Starts the watchdog thread.
    @preconcurrency
    @MainActor
    public func start() {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
        mainThread = mach_thread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        stackHigh = top
        stackLow = top - UInt(pthread_get_stacksize_np(pthread_self()))
        let thread = Thread { [self] in
            loop()
        }
        thread.name = "Stress.Watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Ends the current phase and begins the one called `name` (again, when it was there before).
    public func setPhase(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        closePhase()
        phase = name
        var entry = stats[name] ?? Stats()
        if stats[name] == nil {
            order.append(name)
        }
        entry.started = now()
        stats[name] = entry
    }

    /// The phases in order, their statistics and every stall so far.
    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        closePhase()
        stats[phase]?.started = now()
        return Snapshot(order: order, stats: stats, stalls: stalls)
    }

    /// Adds the wall time of the current phase.
    ///
    /// Called with `lock` held.
    private func closePhase() {
        if var current = stats[phase], current.started > 0 {
            current.wall += now() - current.started
            current.started = 0
            stats[phase] = current
        }
    }

    /// The watchdog thread: one ping every 2 ms, for ever.
    private func loop() {
        while true {
            let sent = now()
            let cpuBefore = mainCPU()
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                semaphore.signal()
            }
            var stacks: [[String]] = []
            if semaphore.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
                stacks += mainStack()
                if semaphore.wait(timeout: .now() + .milliseconds(900)) == .timedOut {
                    stacks += mainStack()
                    semaphore.wait()
                }
            }
            let answer = Answer(
                sent: sent,
                milliseconds: (now() - sent) * 1_000,
                cpuMilliseconds: (mainCPU() - cpuBefore) * 1_000
            )
            record(answer, stacks: stacks)
            usleep(2_000)
        }
    }

    /// Counts one answer in the current phase: a stall belongs to the phase in which it ended (the
    /// ping was sent before it began).
    private func record(_ answer: Answer, stacks: [[String]]) {
        let milliseconds = answer.milliseconds
        lock.lock()
        defer { lock.unlock() }
        let label = phase
        if stats[label] == nil {
            order.append(label)
        }
        var entry = stats[label] ?? Stats()
        entry.count(answer)
        stats[label] = entry
        if milliseconds > 8 {
            let stall = Stall(
                sentAt: answer.sent - started,
                milliseconds: milliseconds,
                mainCPUMilliseconds: answer.cpuMilliseconds,
                phase: label,
                stacks: stacks
            )
            stalls.append(stall)
        }
    }

    /// Processor time the main thread has used so far, in seconds.
    private func mainCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
                thread_info(mainThread, thread_flavor_t(THREAD_BASIC_INFO), words, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return 0
        }
        let seconds = Double(info.user_time.seconds) + Double(info.system_time.seconds)
        return seconds + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
    }

    /// The main thread's stack, taken from this thread: one list of frames, or none when the budget
    /// is used up or the thread cannot be stopped.
    private func mainStack() -> [[String]] {
        lock.lock()
        guard stackBudget > 0 else {
            lock.unlock()
            return []
        }
        stackBudget -= 1
        lock.unlock()
        guard thread_suspend(mainThread) == KERN_SUCCESS else {
            return []
        }
        // Nothing here may allocate or take a lock: the main thread may hold any of them.
        let count = walkMainStack()
        thread_resume(mainThread)
        guard count > 0, let symbols = backtrace_symbols(frames, Int32(count)) else {
            return []
        }
        defer { free(symbols) }
        return [(0..<count).map { symbols[$0].map { String(cString: $0) } ?? "?" }]
    }

    /// Writes the return addresses of the suspended main thread into `frames`, from its registers and
    /// frame pointers; returns how many there are.
    private func walkMainStack() -> Int {
        var state = arm_thread_state64_t()
        var size = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(size)) { words in
                thread_get_state(mainThread, ARM_THREAD_STATE64, words, &size)
            }
        }
        guard result == KERN_SUCCESS else {
            return 0
        }
        frames[0] = UnsafeMutableRawPointer(bitPattern: UInt(state.__pc))
        frames[1] = UnsafeMutableRawPointer(bitPattern: UInt(state.__lr))
        var count = 2
        var framePointer = UInt(state.__fp)
        while count < 200, framePointer >= stackLow, framePointer + 16 <= stackHigh, framePointer & 7 == 0 {
            guard let record = UnsafePointer<UInt>(bitPattern: framePointer) else {
                break
            }
            let (next, returnAddress) = (record[0], record[1])
            if returnAddress == 0 {
                break
            }
            frames[count] = UnsafeMutableRawPointer(bitPattern: returnAddress & 0x0000_007f_ffff_ffff)
            count += 1
            if next <= framePointer {
                break
            }
            framePointer = next
        }
        return count
    }

    deinit {
        frames.deallocate()
    }
}
