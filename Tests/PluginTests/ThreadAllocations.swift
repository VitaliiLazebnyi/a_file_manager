import Foundation

/// What one thread allocates and still holds, counted by that thread alone.
///
/// The allocator's own figures are for the whole process, and the other tests of the
/// process allocate and free tens of megabytes at the same time: with them the reading
/// was once 754 bytes per member and once minus 3,652. Here the allocator's logging hook
/// (`malloc_logger`, the one the system's own tools use) notes every block the measuring
/// thread gets and forgets every block it frees; what is left at the end is asked for
/// its size. Blocks of other threads are not looked at.
///
/// One measurement at a time (`gate`), and none where the hook is not called (under a
/// sanitizer, which brings an allocator of its own): `measure` then answers nil.
internal enum ThreadAllocations {
    /// The shape of the allocator's logging hook: type, zone, two arguments, result, frames to skip.
    internal typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    private static let gate = NSLock()
    private static let capacity = 1 << 22
    // Touched by the measuring thread only, between `begin` and `end`.
    nonisolated(unsafe) private static var table: UnsafeMutablePointer<UInt>?
    nonisolated(unsafe) private static var thread: pthread_t?
    nonisolated(unsafe) private static var (entries, overflowed, calls) = (0, false, 0)
    /// The system's hook, set and cleared by the measuring thread only.
    nonisolated(unsafe) private static let slot: UnsafeMutablePointer<Logger?>? = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2),
        "malloc_logger"
    )?
    .assumingMemoryBound(to: Logger?.self)

    private static let tombstone = UInt.max

    /// Called by the allocator on every thread, for every block; nothing here allocates.
    private static let logger: Logger = { type, _, argument, _, result, _ in
        guard let thread = Self.thread, pthread_equal(pthread_self(), thread) != 0 else {
            return
        }
        Self.calls += 1
        let (allocates, frees) = (type & 2 != 0, type & 4 != 0)
        // A block that is resized: the old address goes, the new one comes.
        if frees { Self.remove(argument) }
        if allocates { Self.insert(result) }
    }

    /// The bytes `body` allocated on this thread and still holds when it returns, with
    /// what it returns; nil for the bytes when they could not be counted.
    internal static func measure<Value>(_ body: () throws -> Value) rethrows -> (bytes: Int?, value: Value) {
        gate.lock()
        defer { gate.unlock() }
        // A sanitizer brings its own allocator: what it would report is not what the
        // program allocates, and the hook's own bookkeeping is nothing it should watch.
        let sanitized = ["__tsan_init", "__asan_init"]
            .contains { (name: String) -> Bool in
                dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) != nil
            }
        guard !sanitized, let slot, slot.pointee == nil else {
            return (nil, try body())
        }
        let blocks = UnsafeMutablePointer<UInt>.allocate(capacity: capacity)
        blocks.initialize(repeating: 0, count: capacity)
        defer { blocks.deallocate() }
        (table, entries, overflowed, calls) = (blocks, 0, false, 0)
        thread = pthread_self()
        slot.pointee = logger
        let value: Value
        do {
            value = try body()
        } catch {
            slot.pointee = nil
            (thread, table) = (nil, nil)
            throw error
        }
        slot.pointee = nil
        (thread, table) = (nil, nil)
        guard calls > 0, !overflowed else {
            return (nil, value)
        }
        var bytes = 0
        for place in 0..<capacity where blocks[place] != 0 && blocks[place] != tombstone {
            bytes += malloc_size(UnsafeRawPointer(bitPattern: blocks[place]))
        }
        return (bytes, value)
    }

    /// The place in the table where the search for `pointer` starts.
    private static func index(of pointer: UInt) -> Int {
        Int(truncatingIfNeeded: (pointer >> 4) &* 0x9E37_79B9_7F4A_7C15) & (capacity - 1)
    }

    /// Notes a block the measuring thread got; past half the table it only notes the overflow.
    private static func insert(_ pointer: UInt) {
        guard let table, pointer != 0 else {
            return
        }
        guard entries < capacity / 2 else {
            overflowed = true
            return
        }
        var place = index(of: pointer)
        while table[place] != 0, table[place] != tombstone { place = (place + 1) & (capacity - 1) }
        entries += 1
        table[place] = pointer
    }

    /// Forgets a block the measuring thread freed (one it did not note is passed over).
    private static func remove(_ pointer: UInt) {
        guard let table, pointer != 0 else {
            return
        }
        var place = index(of: pointer)
        while table[place] != 0 {
            if table[place] == pointer {
                table[place] = tombstone
                entries -= 1
                return
            }
            place = (place + 1) & (capacity - 1)
        }
    }
}
