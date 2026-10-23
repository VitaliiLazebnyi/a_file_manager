import TestSupport
import Testing

@testable import AFMKernel

/// The handlers of a cancellation flag: when they are called, how often, and from which threads.
@Suite
internal struct CancellationHandlerTests {
    /// A handler runs once, however often the flag is set, and at once on a flag that is set already.
    @Test
    internal func aHandlerIsCalledOnceWhenTheFlagIsSet() {
        let flag = CancellationFlag()
        // The handlers run on this thread, inside the calls below.
        nonisolated(unsafe) var calls = 0
        let registration = flag.onCancel { calls += 1 }
        #expect(calls == 0)
        #expect(!flag.isCancelled)
        flag.cancel()
        flag.cancel()
        #expect(calls == 1)
        #expect(flag.isCancelled)
        _ = registration
        // A flag that is set already calls at once.
        // The handlers run on this thread, inside the calls below.
        nonisolated(unsafe) var late = 0
        let second = flag.onCancel { late += 1 }
        #expect(late == 1)
        _ = second
    }

    /// Letting go of the registration takes the handler off the flag; the others stay.
    @Test
    internal func aReleasedRegistrationIsForgotten() {
        let flag = CancellationFlag()
        // The handlers run on this thread, inside the calls below.
        nonisolated(unsafe) var calls = 0
        var registration: AnyObject? = flag.onCancel { calls += 1 }
        let kept = flag.onCancel { calls += 10 }
        #expect(registration != nil)
        registration = nil
        flag.cancel()
        #expect(calls == 10)
        _ = kept
    }

    /// Setting the flag on one thread while handlers are added and dropped on another calls
    /// each handler that was there at that moment, once.
    @Test
    internal func theFlagIsSetFromOtherThreadsWhileHandlersComeAndGo() {
        let flag = CancellationFlag()
        let calls = Shared(0)
        let registered = Shared(0)
        let done = Signal<Bool>()
        OtherThread.start {
            // Set while handlers are coming and going: after a good number has been registered.
            let isUnderWay = Wait.until { registered.value >= 200 }
            flag.cancel()
            done.set(isUnderWay)
        }
        var registrations: [AnyObject] = []
        while !flag.isCancelled {
            registrations.append(flag.onCancel { calls.modify { $0 += 1 } })
            registered.modify { $0 += 1 }
            if registrations.count > 64 {
                registrations.removeFirst(32)
            }
        }
        #expect(done.wait() == true)
        // Whatever was registered when the flag was set was called, each handler once.
        #expect(calls.value >= 1)
        #expect(calls.value <= 65)
    }
}
