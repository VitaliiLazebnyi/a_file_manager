import Darwin
import Foundation

// Shared measuring tools of the stress harnesses: a main-thread watchdog, thread and memory
// counters, a run-loop pump and a hang guard.

public func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

/// Number of threads of this process.
public func threadCount() -> Int {
    var list: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
    for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[index]) }
    vm_deallocate(
        mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.size))
    return Int(count)
}

/// The threads of this process by name, with how many there are of each ("unnamed" for those without one).
public func threadNames() -> String {
    var list: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return "?" }
    var names: [String: Int] = [:]
    for index in 0..<Int(count) {
        var name = [CChar](repeating: 0, count: 128)
        if let thread = pthread_from_mach_thread_np(list[index]) { pthread_getname_np(thread, &name, name.count) }
        let text = String(cString: name)
        names[text.isEmpty ? (index == 0 ? "main" : "unnamed") : text, default: 0] += 1
        mach_port_deallocate(mach_task_self_, list[index])
    }
    vm_deallocate(
        mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.size))
    return names.sorted { $0.key < $1.key }.map { "\($0.value) x \($0.key)" }.joined(separator: ", ")
}

/// How many threads have a name that begins with `prefix` (and does not end with `except`).
public func threadCount(named prefix: String, except: String = "\u{0}") -> Int {
    var list: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
    var found = 0
    for index in 0..<Int(count) {
        var name = [CChar](repeating: 0, count: 128)
        if let thread = pthread_from_mach_thread_np(list[index]) { pthread_getname_np(thread, &name, name.count) }
        let text = String(cString: name)
        if text.hasPrefix(prefix), !text.hasSuffix(except) { found += 1 }
        mach_port_deallocate(mach_task_self_, list[index])
    }
    vm_deallocate(
        mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.size))
    return found
}

/// Peak resident size so far, in megabytes.
public func peakRSSMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576
}

/// Current physical footprint, in megabytes.
public func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

/// Processor time used by the process so far (user + system), seconds.
public func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec)
        + Double(usage.ru_stime.tv_usec) / 1e6
}

public func loadAverage() -> Double {
    var loads = [Double](repeating: 0, count: 3)
    getloadavg(&loads, 3)
    return loads[0]
}

public func pad(_ text: String, _ width: Int = 46) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

public func say(_ text: String) {
    FileHandle.standardOutput.write((text + "\n").data(using: .utf8)!)
}

/// Runs the main run loop (timers, sources, the main dispatch queue) until the condition holds.
/// Main thread only. Returns false on timeout.
@discardableResult
public func pump(upTo seconds: Double = 60, until condition: () -> Bool) -> Bool {
    let deadline = now() + seconds
    while !condition() {
        if now() > deadline { return false }
        CFRunLoopRunInMode(.defaultMode, 0.002, true)
    }
    return true
}

public func pump(for seconds: Double) {
    let deadline = now() + seconds
    while now() < deadline { CFRunLoopRunInMode(.defaultMode, 0.002, true) }
}

/// Pings the main dispatch queue every 2 ms from a thread of its own and records how long the
/// main thread took to answer. An answer later than 8 ms is a stall. A stall that lasts 100 ms
/// gets the main thread's stack taken while it lasts (the thread is suspended for an instant
/// and its frame pointers are walked), and again at 1 s.
public final class MainWatchdog {
    public struct Stall {
        public let at: Double
        public let milliseconds: Double
        /// Processor time the main thread used during the stall: near `milliseconds` when it was
        /// working, near zero when it was blocked or had no core.
        public let mainCPUMilliseconds: Double
        public let phase: String
        public let stacks: [[String]]
    }

    public struct Stats {
        public var pings = 0
        public var over8 = 0
        public var over100 = 0
        public var over1000 = 0
        public var maxMs = 0.0
        public var maxCPUMs = 0.0
        public var stallMs = 0.0
        public var stallCPUMs = 0.0
        public var histogram = [Int](repeating: 0, count: MainWatchdog.bounds.count + 1)
        public var wall = 0.0
        public var started = 0.0
    }

    public static let bounds: [Double] = [2, 4, 8, 16, 33, 100, 250, 1_000, 5_000]
    public static let shared = MainWatchdog()

    private let lock = NSLock()
    private var phase = "start"
    private var stats: [String: Stats] = [:]
    private var order: [String] = []
    private var stalls: [Stall] = []
    private var running = false
    private var mainThread: thread_t = 0
    private var stackLow: UInt = 0
    private var stackHigh: UInt = 0
    private let started = now()
    private let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 256)
    public var stackBudget = 400

    /// Call on the main thread.
    public func start() {
        precondition(Thread.isMainThread)
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
        mainThread = mach_thread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        stackHigh = top
        stackLow = top - UInt(pthread_get_stacksize_np(pthread_self()))
        running = true
        let thread = Thread { [self] in loop() }
        thread.name = "Stress.Watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    public func setPhase(_ name: String) {
        lock.lock()
        closePhase()
        phase = name
        if stats[name] == nil {
            order.append(name)
            stats[name] = Stats()
        }
        stats[name]!.started = now()
        lock.unlock()
    }

    private func closePhase() {
        if var current = stats[phase], current.started > 0 {
            current.wall += now() - current.started
            current.started = 0
            stats[phase] = current
        }
    }

    private func loop() {
        while running {
            let sent = now()
            let cpuBefore = mainCPU()
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { semaphore.signal() }
            var stacks: [[String]] = []
            if semaphore.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
                if let stack = mainStack() { stacks.append(stack) }
                if semaphore.wait(timeout: .now() + .milliseconds(900)) == .timedOut {
                    if let stack = mainStack() { stacks.append(stack) }
                    semaphore.wait()
                }
            }
            let ms = (now() - sent) * 1_000
            let cpuMs = (mainCPU() - cpuBefore) * 1_000
            lock.lock()
            // A stall belongs to the phase in which it ended (the ping was sent before it began).
            let label = phase
            var entry =
                stats[label]
                ?? {
                    order.append(label)
                    return Stats()
                }()
            entry.pings += 1
            if ms > entry.maxMs {
                entry.maxMs = ms
                entry.maxCPUMs = cpuMs
            }
            if ms > 8 {
                entry.stallMs += ms
                entry.stallCPUMs += cpuMs
            }
            entry.histogram[Self.bounds.firstIndex(where: { ms < $0 }) ?? Self.bounds.count] += 1
            if ms > 8 { entry.over8 += 1 }
            if ms > 100 { entry.over100 += 1 }
            if ms > 1_000 { entry.over1000 += 1 }
            stats[label] = entry
            if ms > 8 {
                stalls.append(
                    Stall(
                        at: sent - started, milliseconds: ms, mainCPUMilliseconds: cpuMs, phase: label, stacks: stacks
                    )
                )
            }
            lock.unlock()
            usleep(2_000)
        }
    }

    /// Processor time the main thread has used so far, in seconds.
    private func mainCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(mainThread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.system_time.seconds) + Double(
            info.user_time.microseconds + info.system_time.microseconds) / 1e6
    }

    /// The main thread's stack, taken from this thread.
    private func mainStack() -> [String]? {
        lock.lock()
        guard stackBudget > 0 else {
            lock.unlock()
            return nil
        }
        stackBudget -= 1
        lock.unlock()
        var count = 0
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return nil }
        // Nothing here may allocate or take a lock: the main thread may hold any of them.
        var state = arm_thread_state64_t()
        var size = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(size)) {
                thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &size)
            }
        }
        if result == KERN_SUCCESS {
            frames[0] = UnsafeMutableRawPointer(bitPattern: UInt(state.__pc))
            count = 1
            frames[1] = UnsafeMutableRawPointer(bitPattern: UInt(state.__lr))
            count = 2
            var fp = UInt(state.__fp)
            while count < 200, fp >= stackLow, fp + 16 <= stackHigh, fp & 7 == 0 {
                let record = UnsafePointer<UInt>(bitPattern: fp)!
                let (next, ret) = (record[0], record[1])
                if ret == 0 { break }
                frames[count] = UnsafeMutableRawPointer(bitPattern: ret & 0x0000_007f_ffff_ffff)
                count += 1
                if next <= fp { break }
                fp = next
            }
        }
        thread_resume(mainThread)
        guard count > 0, let symbols = backtrace_symbols(frames, Int32(count)) else { return nil }
        defer { free(symbols) }
        return (0..<count).map { symbols[$0].map { String(cString: $0) } ?? "?" }
    }

    public func snapshot() -> (order: [String], stats: [String: Stats], stalls: [Stall]) {
        lock.lock()
        defer { lock.unlock() }
        closePhase()
        if stats[phase] != nil { stats[phase]!.started = now() }
        return (order, stats, stalls)
    }

    /// Prints the table of phases, the histogram and the sampled stacks of long stalls.
    public func report(title: String) {
        let (order, stats, stalls) = snapshot()
        say("\n==== MAIN-THREAD WATCHDOG: \(title) ====")
        say(
            "histogram bounds (ms): <" + Self.bounds.map { String(format: "%g", $0) }.joined(separator: " <")
                + " >=5000")
        say(
            "(max cpu = processor time the main thread used during its longest stall; stall ms / cpu ms = sums over all stalls > 8 ms: equal means the main thread was working, cpu much smaller means it was blocked or had no core)"
        )
        say(pad("phase") + "   wall s   pings   >8ms >100ms    >1s    max ms  max cpu  stall ms    cpu ms  histogram")
        var total = Stats()
        for name in order {
            guard let s = stats[name], s.pings > 0 || s.wall > 0 else { continue }
            say(
                pad(name)
                    + String(
                        format: " %8.2f %7d %6d %6d %6d %9.1f %8.1f %9.0f %9.0f  ", s.wall, s.pings, s.over8, s.over100,
                        s.over1000, s.maxMs, s.maxCPUMs, s.stallMs, s.stallCPUMs)
                    + s.histogram.map(String.init).joined(separator: ","))
            total.pings += s.pings
            total.over8 += s.over8
            total.over100 += s.over100
            total.over1000 += s.over1000
            total.maxMs = max(total.maxMs, s.maxMs)
            total.wall += s.wall
            total.stallMs += s.stallMs
            total.stallCPUMs += s.stallCPUMs
        }
        say(
            pad("TOTAL")
                + String(
                    format: " %8.2f %7d %6d %6d %6d %9.1f %8@ %9.0f %9.0f", total.wall, total.pings, total.over8,
                    total.over100, total.over1000, total.maxMs, "" as NSString, total.stallMs, total.stallCPUMs))
        let long = stalls.filter { $0.milliseconds > 100 }
        // For each phase the two longest stalls with different stacks.
        var perPhase: [String: Int] = [:]
        var seen = Set<String>()
        for stall in long.sorted(by: { $0.milliseconds > $1.milliseconds }) where !stall.stacks.isEmpty {
            guard perPhase[stall.phase, default: 0] < 2 else { continue }
            let key =
                stall.phase + "|"
                + stall.stacks[0].prefix(8).map { $0.split(separator: " ", maxSplits: 3).last.map(String.init) ?? $0 }
                .joined()
            guard seen.insert(key).inserted else { continue }
            perPhase[stall.phase, default: 0] += 1
            say(
                String(
                    format:
                        "\n-- stall %.0f ms (main thread cpu %.0f ms) at t=%.2fs in phase '%@'; main thread stack at +100 ms:",
                    stall.milliseconds, stall.mainCPUMilliseconds, stall.at, stall.phase as NSString))
            for line in stall.stacks[0].prefix(34) { say("   " + line) }
            if stall.stacks.count > 1 {
                say("   .. and at +1 s:")
                for line in stall.stacks[1].prefix(26) { say("   " + line) }
            }
        }
    }
}

/// Ends the process with a `sample` of itself when a step takes longer than allowed.
public final class HangGuard {
    public static let shared = HangGuard()
    private let lock = NSLock()
    private var deadline = Double.infinity
    private var label = ""
    private var started = false
    public var sampleDirectory = FileManager.default.currentDirectoryPath
    /// Called instead of exiting when set (returns true to go on living).
    public var onHang: ((String) -> Bool)?

    public func arm(_ label: String, seconds: Double) {
        lock.lock()
        self.label = label
        deadline = now() + seconds
        let start = !started
        started = true
        lock.unlock()
        guard start else { return }
        let thread = Thread { [self] in
            while true {
                usleep(200_000)
                lock.lock()
                let (limit, name) = (deadline, self.label)
                lock.unlock()
                guard now() > limit else { continue }
                let file =
                    sampleDirectory
                    + "/hang-\(name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "_"))-\(getpid()).sample.txt"
                say("!!!! HANG: '\(name)' exceeded its time limit; threads=\(threadCount()); sampling to \(file)")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                process.arguments = ["\(getpid())", "3", "-file", file]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
                if let onHang, onHang(name) {
                    disarm()
                    continue
                }
                MainWatchdog.shared.report(title: "at hang")
                exit(97)
            }
        }
        thread.name = "Stress.HangGuard"
        thread.start()
    }

    public func disarm() {
        lock.lock()
        deadline = .infinity
        lock.unlock()
    }
}

/// Measures one step: wall time, processor time, memory, threads; names the watchdog phase.
@discardableResult
public func step<T>(_ name: String, limit: Double = 600, _ body: () throws -> T) rethrows -> T {
    MainWatchdog.shared.setPhase(name)
    HangGuard.shared.arm(name, seconds: limit)
    let (t0, c0, th0) = (now(), cpuSeconds(), threadCount())
    let result = try body()
    let wall = now() - t0
    say(
        "STEP " + pad(name)
            + String(
                format: " wall=%8.3fs cpu=%7.2fs threads %d->%d footprint=%.0fMB peakRSS=%.0fMB load=%.1f",
                wall, cpuSeconds() - c0, th0, threadCount(), footprintMB(), peakRSSMB(), loadAverage()))
    HangGuard.shared.disarm()
    return result
}

/// A small deterministic random generator (SplitMix64).
public struct Random: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Waits (off the main thread) until the number of threads falls to `baseline + slack`.
public func waitForThreads(atMost limit: Int, upTo seconds: Double, onMain: Bool = false) -> Int {
    let deadline = now() + seconds
    while threadCount() > limit, now() < deadline {
        if onMain { pump(for: 0.05) } else { usleep(50_000) }
    }
    return threadCount()
}
