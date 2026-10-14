import Foundation
import Testing

@testable import AFMKernel

/// Parallel work called from the main thread (review 2, K044).
@MainActor
@Suite(.serialized)
internal struct ParallelOnMainTests {
    /// Every piece of a call on the main thread, nested calls included, knows that the main
    /// thread waits for it; once the call returns, nothing holds it up.
    @Test
    internal func piecesOfACallOnTheMainThreadKnowThatItWaitsForThem() {
        guard Thread.isMainThread else {
            return
        }
        let inside = Parallel.map(Array(0..<256)) { _ -> Bool in
            // Nested calls belong to the same wait.
            let nested = Parallel.map([1, 2, 3]) { _ in Parallel.isHoldingUpMainThread }
            return nested.allSatisfy(\.self) && Parallel.isHoldingUpMainThread
        }
        let allKnow = inside.allSatisfy(\.self)
        #expect(allKnow)
        #expect(!Parallel.isHoldingUpMainThread)
    }
}
