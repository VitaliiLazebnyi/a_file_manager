import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Review round 2, second pass: what the directory of a large archive costs in memory
/// (A051, A076), and that the compact form of it behaves like the plain one.
@Suite struct Review2ArchivesP2Memory {
    let bench: ArchiveBench
    var box: Sandbox { bench.box }

    init() throws {
        bench = try ArchiveBench()
    }

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
    private enum ThreadAllocations {
        typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

        private static let gate = NSLock()
        private static let capacity = 1 << 22
        // Touched by the measuring thread only, between `begin` and `end`.
        private static nonisolated(unsafe) var table: UnsafeMutablePointer<UInt>?
        private static nonisolated(unsafe) var thread: pthread_t?
        private static nonisolated(unsafe) var (entries, overflowed, calls) = (0, false, 0)
        private static let slot: UnsafeMutablePointer<Logger?>? = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")?
            .assumingMemoryBound(to: Logger?.self)

        private static let tombstone = UInt.max

        private static func index(of pointer: UInt) -> Int {
            Int(truncatingIfNeeded: (pointer >> 4) &* 0x9E37_79B9_7F4A_7C15) & (capacity - 1)
        }

        private static func insert(_ pointer: UInt) {
            guard let table, pointer != 0 else { return }
            guard entries < capacity / 2 else {
                overflowed = true
                return
            }
            var place = index(of: pointer)
            while table[place] != 0, table[place] != tombstone { place = (place + 1) & (capacity - 1) }
            entries += 1
            table[place] = pointer
        }

        private static func remove(_ pointer: UInt) {
            guard let table, pointer != 0 else { return }
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

        /// Called by the allocator on every thread, for every block; nothing here allocates.
        private static let logger: Logger = { type, _, argument, _, result, _ in
            guard let thread = ThreadAllocations.thread, pthread_equal(pthread_self(), thread) != 0 else { return }
            ThreadAllocations.calls += 1
            let (allocates, frees) = (type & 2 != 0, type & 4 != 0)
            // A block that is resized: the old address goes, the new one comes.
            if frees { ThreadAllocations.remove(argument) }
            if allocates { ThreadAllocations.insert(result) }
        }

        /// The bytes `body` allocated on this thread and still holds when it returns, with
        /// what it returns; nil for the bytes when they could not be counted.
        static func measure<Value>(_ body: () throws -> Value) rethrows -> (bytes: Int?, value: Value) {
            gate.lock()
            defer { gate.unlock() }
            // A sanitizer brings its own allocator: what it would report is not what the
            // program allocates, and the hook's own bookkeeping is nothing it should watch.
            let sanitized = ["__tsan_init", "__asan_init"].contains(where: { (name: String) -> Bool in
                dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) != nil
            })
            guard !sanitized, let slot, slot.pointee == nil else { return (nil, try body()) }
            let table = UnsafeMutablePointer<UInt>.allocate(capacity: capacity)
            table.initialize(repeating: 0, count: capacity)
            defer { table.deallocate() }
            (self.table, entries, overflowed, calls) = (table, 0, false, 0)
            thread = pthread_self()
            slot.pointee = logger
            let value: Value
            do {
                value = try body()
            } catch {
                slot.pointee = nil
                (thread, self.table) = (nil, nil)
                throw error
            }
            slot.pointee = nil
            (thread, self.table) = (nil, nil)
            guard calls > 0, !overflowed else { return (nil, value) }
            var bytes = 0
            for place in 0..<capacity where table[place] != 0 && table[place] != tombstone {
                bytes += malloc_size(UnsafeRawPointer(bitPattern: table[place]))
            }
            return (bytes, value)
        }
    }

    /// A ZIP as the `zip` program writes it: each member with the exact-time field and the
    /// owner field (24 bytes of extra fields), in folders of a few hundred files.
    private func writeLargeZip(_ name: String, members: Int) throws -> URL {
        let url = box.url(name)
        let output = try OutputFile(creating: url)
        let writer = ZipWriter(output)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<members {
            var record = ZipRecord.new(
                name: "project-\(index / 40_000)/module-\(index / 400)/source-file-\(index).swift", isDirectory: false,
                modified: modified, permissions: 0o644)
            var extra = record.extra
            extra.append(contentsOf: [0x75, 0x78, 11, 0, 1, 4, 0xF5, 1, 0, 0, 4, 0x14, 0, 0, 0])
            record.extra = extra
            try writer.end(try writer.begin(record), record, headerChanged: false)
        }
        try writer.finish()
        try output.close()
        return url
    }

    @Test func aLargeDirectoryCostsAFewHundredBytesPerMember() throws {
        // (Measured alone with 200,064 members: 396 bytes each, 975 before. Fewer here, so the
        // test is quick among the others; the cost per member is the same.)
        let members = 60_000
        let url = try writeLargeZip("large.zip", members: members)
        // What opening the archive leaves allocated, counted on this thread alone (the
        // directory is read by the thread that opens the archive): the other tests of the
        // process, which allocate at the same time, are not in the figure.
        var best: Int?
        var folders = 0
        for _ in 0..<3 {
            let (bytes, archive) = try ThreadAllocations.measure {
                try OpenArchive(
                    archiveURL: url, localURL: url, fetchedCopy: nil, remoteStamp: nil, environment: bench.environment
                )
            }
            folders = archive.entries.count - members
            #expect(archive.entry("project-1/module-149/source-file-59999.swift")?.size == 0)
            #expect(archive.children(of: "project-0/module-7")?.count == 400)
            if let bytes { best = min(best ?? .max, bytes / members) }
        }
        guard let best else {
            // (A sanitizer's allocator does not call the hook.)
            print("A051/A076: not measured, the allocator's logging hook is not available in this build")
            #expect(folders == 2 + 150)
            return
        }
        print(
            "A051/A076: \(best) bytes per member (\(members) members, \(folders) folders); an entry is \(MemoryLayout<ArchiveEntry?>.stride) bytes, "
                + "of which the ZIP record \(MemoryLayout<ZipRecord>.size)")
        #expect(folders == 2 + 150)
        // Measured alone before this round's fix: 975. A reading far below what the entries
        // themselves take would mean nothing was counted.
        #expect(best > 150 && best < 600, "\(best) bytes per member")
    }
}
