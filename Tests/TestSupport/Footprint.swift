import Darwin

/// The memory this process holds, as the system counts it against the process.
///
/// That is the "memory" column of Activity Monitor: resident and compressed pages the process
/// owns, without the shared libraries. For benchmarks and tests that memory does not grow.
public enum Footprint {
    /// The footprint now, in bytes; zero when the system does not say.
    public static var current: Int {
        info().map { Int($0.phys_footprint) } ?? 0
    }

    /// The highest footprint the process has had since it started, in bytes; zero when the
    /// system does not say.
    public static var peak: Int {
        info().map { Int($0.ledger_phys_footprint_peak) } ?? 0
    }

    /// The process's virtual-memory figures.
    private static func info() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        // `mach_task_self_` is a global variable, which Swift 6 does not let code read; the trap
        // gives the same port, with one more reference that is given back below.
        let task = task_self_trap()
        defer { mach_port_deallocate(task, task) }
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
                task_info(task, task_flavor_t(TASK_VM_INFO), words, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }
}
