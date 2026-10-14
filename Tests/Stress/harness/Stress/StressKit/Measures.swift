internal import Darwin
internal import Foundation

// Shared measuring tools of the stress harnesses: the clock, thread and memory counters, processor
// time and the load. Any thread may call them.

/// Seconds since an arbitrary start, from the monotonic clock.
public func now() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1e9
}

/// Number of threads of this process; -1 when they cannot be listed.
public func threadCount() -> Int {
    forEachThread { _, _ in
        // Counting only.
    }
}

/// The threads of this process by name, with how many there are of each ("unnamed" for those
/// without one, "main" for the first).
public func threadNames() -> String {
    var names: [String: Int] = [:]
    let count = forEachThread { index, name in
        names[name.isEmpty ? (index == 0 ? "main" : "unnamed") : name, default: 0] += 1
    }
    guard count >= 0 else {
        return "?"
    }
    return names.sorted { $0.key < $1.key }.map { "\($0.value) x \($0.key)" }.joined(separator: ", ")
}

/// How many threads have a name that begins with `prefix` and does not end with `except`; -1 when
/// they cannot be listed.
public func threadCount(named prefix: String, except: String = "\u{0}") -> Int {
    var found = 0
    let count = forEachThread { _, name in
        if name.hasPrefix(prefix), !name.hasSuffix(except) {
            found += 1
        }
    }
    return count < 0 ? count : found
}

/// Peak resident size so far, in megabytes.
public func peakRSSMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576
}

/// Current physical footprint, in megabytes; -1 when it cannot be read.
public func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), words, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

/// Processor time used by the process so far (user and system), in seconds.
public func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
    let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    return user + system
}

/// The system's load average over the last minute.
public func loadAverage() -> Double {
    var loads = [Double](repeating: 0, count: 3)
    getloadavg(&loads, 3)
    return loads[0]
}

/// Calls `body` with the index and the name of each thread of this process ("" for a thread
/// without a name) and returns how many there are; -1 when they cannot be listed.
internal func forEachThread(_ body: (Int, String) -> Void) -> Int {
    var list: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else {
        return -1
    }
    for index in 0..<Int(count) {
        var name = [CChar](repeating: 0, count: 128)
        if let thread = pthread_from_mach_thread_np(list[index]) {
            pthread_getname_np(thread, &name, name.count)
        }
        let bytes = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        body(index, String(bytes: bytes, encoding: .utf8) ?? "?")
        mach_port_deallocate(mach_task_self_, list[index])
    }
    let size = vm_size_t(Int(count) * MemoryLayout<thread_t>.size)
    vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), size)
    return Int(count)
}
