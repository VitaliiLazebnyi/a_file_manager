import AFMKernel
import TestSupport
import Testing

/// The check that state is used on the main thread: quiet there, a fault elsewhere.
@Suite
internal struct CovSmallMainThreadTests {
    /// On the main thread the check passes without even naming the state; on another thread it
    /// names the state for its fault.
    @Test
    internal func theCheckSpeaksOnlyOffTheMainThread() async {
        let named = Shared(0)
        @Sendable
        func name() -> String {
            named.modify { $0 += 1 }
            return "The test's state"
        }
        await MainActor.run { MainThread.assert(name()) }
        #expect(named.value == 0)
        #expect(OtherThread.result { MainThread.assert(name()) } != nil)
        #expect(named.value == 1)
    }
}
