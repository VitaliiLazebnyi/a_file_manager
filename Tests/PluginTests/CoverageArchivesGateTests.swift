import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The gate that lets one write of an archive run at a time, and the renames that write at
/// once without waiting behind a long write.
///
/// A waiter of a high priority lends it to the thread that holds the gate in the same step as
/// it begins to wait; the holder sees its own priority rise. That is how these tests know that
/// a waiter waits, without a clock.
@Suite
internal struct CoverageArchivesGateTests {
    /// The scheduling priority of the calling thread, overrides included.
    private static func ownPriority() -> Int32 {
        var info = thread_extended_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { fields in
                thread_info(
                    pthread_mach_thread_np(pthread_self()),
                    thread_flavor_t(THREAD_EXTENDED_INFO),
                    fields,
                    &count
                )
            }
        }
        return status == KERN_SUCCESS ? info.pth_priority : -1
    }

    /// Takes the gate on a low-priority thread of its own and holds it until a waiter of a
    /// higher priority has come, then lets go. `held` is set once it holds the gate,
    /// `released` (true when a waiter came) once it let go.
    private static func holding(_ gate: FlushGate, long: Bool) -> (held: Signal<Bool>, released: Signal<Bool>) {
        let (held, released) = (Signal<Bool>(), Signal<Bool>())
        let thread = Thread {
            try? gate.lock(long: long, cancellation: nil)
            let base = ownPriority()
            held.set(true)
            let came = Wait.until { ownPriority() > base }
            gate.unlock()
            released.set(came)
        }
        thread.qualityOfService = .utility
        thread.start()
        _ = held.wait()
        return (held, released)
    }

    /// Takes the gate on a thread of its own with the given priority and gives it back at once;
    /// the result tells whether it got it.
    private static func taking(
        _ gate: FlushGate,
        priority: QualityOfService,
        _ take: @escaping @Sendable (FlushGate) -> Bool
    ) -> Signal<Bool> {
        let result = Signal<Bool>()
        let thread = Thread {
            let taken = take(gate)
            if taken {
                gate.unlock()
            }
            result.set(taken)
        }
        thread.qualityOfService = priority
        thread.start()
        return result
    }

    /// Checks that a rename that comes while a long write holds the gate returns at once without it.
    @Test
    internal func aRenameThatComesWhileALongWriteRunsDoesNotWait() {
        let gate = FlushGate()
        #expect(gate.lock(long: true, before: .distantFuture))
        #expect(Self.taking(gate, priority: .userInitiated) { $0.lockUnlessLong() }.wait() == false)
        gate.unlock()
        #expect(gate.lockUnlessLong())
        gate.unlock()
    }

    /// Checks that a rename waits for another rename and then takes the gate.
    @Test
    internal func aRenameWaitsForAnotherRename() {
        let gate = FlushGate()
        let holder = Self.holding(gate, long: false)
        #expect(Self.taking(gate, priority: .userInitiated) { $0.lockUnlessLong() }.wait() == true)
        #expect(holder.released.wait() == true)
    }

    /// Checks that a long write which takes the gate while a rename waits for another rename
    /// does not keep the rename waiting until it ends.
    @Test
    internal func aRenameDoesNotWaitBehindALongWriteThatOvertakesIt() throws {
        let gate = FlushGate()
        try gate.lock(long: false, cancellation: nil)
        let rename = Self.taking(gate, priority: .userInitiated) { $0.lockUnlessLong() }
        // A long write that waits beside it and keeps the gate until the rename has answered.
        let (longTook, release) = (Signal<Bool>(), Signal<Bool>())
        OtherThread.start {
            try? gate.lock(long: true, cancellation: nil)
            longTook.set(true)
            _ = release.wait()
            gate.unlock()
        }
        gate.unlock()
        // Whichever of the two takes the gate first, the rename answers without the long
        // write having ended: it either wrote or left the write to the timer.
        #expect(rename.wait() != nil)
        release.set(true)
        #expect(longTook.wait() == true)
    }

    /// Checks that a wait without a cancellation lasts until the gate is free, and then takes it.
    @Test
    internal func aWaitTakesTheGateWhenItIsFreed() {
        let gate = FlushGate()
        let holder = Self.holding(gate, long: true)
        let waiting = Self.taking(gate, priority: .userInitiated) { waiter in
            (try? waiter.lock(long: true, cancellation: nil)) != nil
        }
        #expect(waiting.wait() == true)
        #expect(holder.released.wait() == true)
    }

    /// Checks that a wait with a cancellation ends, without the gate, once the flag is set.
    @Test
    internal func aWaitWithACancellationEndsWhenItIsSet() throws {
        let gate = FlushGate()
        try gate.lock(long: true, cancellation: nil)
        let flag = CancellationFlag()
        let waiting = Self.taking(gate, priority: .userInitiated) { waiter in
            (try? waiter.lock(long: true, cancellation: flag)) != nil
        }
        flag.cancel()
        #expect(waiting.wait() == false)
        gate.unlock()
    }

    /// Checks that a wait with a cancellation that is never set takes the gate once it is free.
    @Test
    internal func aWaitWithACancellationTakesTheGateWhenItIsFreed() {
        let gate = FlushGate()
        let holder = Self.holding(gate, long: true)
        let flag = CancellationFlag()
        let waiting = Self.taking(gate, priority: .userInitiated) { waiter in
            (try? waiter.lock(long: true, cancellation: flag)) != nil
        }
        #expect(waiting.wait() == true)
        #expect(holder.released.wait() == true)
    }

    /// Checks that a wait with a deadline gives up at the deadline, and takes a gate freed before it.
    @Test
    internal func aWaitWithADeadlineEndsAtTheDeadline() throws {
        let gate = FlushGate()
        try gate.lock(long: true, cancellation: nil)
        let hasty = Self.taking(gate, priority: .userInitiated) { waiter in
            waiter.lock(long: true, before: Date(timeIntervalSinceNow: 0.01))
        }
        #expect(hasty.wait() == false)
        gate.unlock()
        let holder = Self.holding(gate, long: true)
        let patient = Self.taking(gate, priority: .userInitiated) { $0.lock(long: true, before: .distantFuture) }
        #expect(patient.wait() == true)
        #expect(holder.released.wait() == true)
    }

    /// Checks that a waiter of a low priority, which has no priority to lend, gets the gate too.
    @Test
    internal func aWaiterOfLowPriorityGetsTheGate() throws {
        let gate = FlushGate()
        try gate.lock(long: true, cancellation: nil)
        let waiting = Self.taking(gate, priority: .background) { (try? $0.lock(long: false, cancellation: nil)) != nil }
        gate.unlock()
        #expect(waiting.wait() == true)
    }
}
