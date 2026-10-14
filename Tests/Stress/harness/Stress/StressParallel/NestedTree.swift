internal import AFMKernel
internal import Darwin
internal import Dispatch
internal import Foundation

/// The nested tree of `Parallel.map` calls, and what it must add up to.
internal enum NestedTree {
    /// How many times leaves hopped to the main thread.
    internal static let mainSyncs = ManagedAtomicCounter()

    /// A 64-bit mix (splitmix64's finalizer).
    internal static func mix(_ value: UInt64) -> UInt64 {
        var mixed = value &+ 0x9E37_79B9_7F4A_7C15
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    /// What the tree below `path` adds up to, computed without `Parallel`.
    internal static func expected(depth: Int, width: Int, path: UInt64) -> UInt64 {
        if depth == 0 {
            return mix(path) & 0xFFFF
        }
        var sum: UInt64 = 0
        for index in 0..<width {
            sum &+= expected(depth: depth - 1, width: width, path: mix(path &* 31 &+ UInt64(index)))
        }
        return sum &+ (mix(path) & 0xFF)
    }

    /// The tree below `path`, each level one `Parallel.map`.
    internal static func tree(depth: Int, width: Int, path: UInt64, _ behaviour: Behaviour) -> UInt64 {
        if depth == 0 {
            leaf(path, behaviour)
            return mix(path) & 0xFFFF
        }
        let children = (0..<width).map { mix(path &* 31 &+ UInt64($0)) }
        let parts = Parallel.map(children) { tree(depth: depth - 1, width: width, path: $0, behaviour) }
        // The order of the results must be the order of the input.
        return parts.reduce(0, &+) &+ (mix(path) & 0xFF)
    }

    /// What a leaf does besides computing its value.
    private static func leaf(_ path: UInt64, _ behaviour: Behaviour) {
        let kind = mix(path ^ 0xABCD) % 100
        if behaviour.sleeps, kind < 4 {
            usleep(useconds_t(500 + mix(path) % 3_000))
        }
        if behaviour.callsStat, kind >= 4, kind < 10 {
            var info = stat()
            _ = stat("/usr/lib", &info)
        }
        if behaviour.mainSync, kind >= 10, kind < 11, !Thread.isMainThread {
            DispatchQueue.main.sync { mainSyncs.add() }
        }
    }
}
