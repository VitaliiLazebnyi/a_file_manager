import Foundation

/// The kind of machine the benchmarks run on, which their limits are recorded for.
internal enum Machine {
    /// Model, processor architecture, cores and memory, e.g. `VirtualMac2,1 arm64 8 cores 32 GB`.
    internal static var current: String {
        let memory = number("hw.memsize") >> 30
        return "\(text("hw.model")) \(text("hw.machine")) \(number("hw.ncpu")) cores \(memory) GB"
    }

    /// A text the system reports by name.
    private static func text(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return "?"
        }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else {
            return "?"
        }
        return String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) ?? "?"
    }

    /// A number the system reports by name.
    private static func number(_ name: String) -> Int {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        if sysctlbyname(name, &value, &size, nil, 0) != 0 {
            return 0
        }
        // `hw.ncpu` is 32 bits wide, `hw.memsize` 64: the low bytes are the value either way.
        return size == MemoryLayout<Int32>.size ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }
}
