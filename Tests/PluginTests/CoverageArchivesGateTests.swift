import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The gate that lets one write of an archive run at a time, and the renames that write at
/// once without waiting behind a long write.
@Suite
internal struct CoverageArchivesGateTests {
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
    internal func aRenameWaitsForAnotherRename() throws {
        let gate = FlushGate()
        try gate.lock(long: false, cancellation: nil)
        let waiting = Self.taking(gate, priority: .userInitiated) { $0.lockUnlessLong() }
        gate.unlock()
        #expect(waiting.wait() == true)
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

    /// Checks that a wait with a cancellation ends, without the gate, once the flag is set.
    @Test
    internal func aWaitWithACancellationEndsWhenItIsSet() throws {
        let gate = FlushGate()
        try gate.lock(long: true, cancellation: nil)
        let flag = CancellationFlag()
        let waiting = Self.taking(gate, priority: .userInitiated) { gate in
            (try? gate.lock(long: true, cancellation: flag)) != nil
        }
        flag.cancel()
        #expect(waiting.wait() == false)
        gate.unlock()
    }

    /// Checks that a wait with a cancellation that is never set takes the gate once it is free.
    @Test
    internal func aWaitWithACancellationTakesTheGateWhenItIsFreed() throws {
        let gate = FlushGate()
        try gate.lock(long: true, cancellation: nil)
        let flag = CancellationFlag()
        let waiting = Self.taking(gate, priority: .userInitiated) { gate in
            (try? gate.lock(long: true, cancellation: flag)) != nil
        }
        gate.unlock()
        #expect(waiting.wait() == true)
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
        let patient = Self.taking(gate, priority: .userInitiated) { $0.lock(long: true, before: .distantFuture) }
        gate.unlock()
        #expect(patient.wait() == true)
    }

    /// Checks that waiters of a low priority (which lend none) and of a high one both get the gate.
    @Test(arguments: [QualityOfService.utility, .userInitiated])
    internal func waitersOfAnyPriorityGetTheGate(priority: QualityOfService) throws {
        let gate = FlushGate()
        try gate.lock(long: true, cancellation: nil)
        let waiting = Self.taking(gate, priority: priority) { (try? $0.lock(long: false, cancellation: nil)) != nil }
        gate.unlock()
        #expect(waiting.wait() == true)
    }
}
