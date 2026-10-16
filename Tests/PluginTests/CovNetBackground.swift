import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// The threads of the background work.
@Suite
internal struct CovNetBackground {
    /// A thread that has had nothing to do for a while ends.
    @Test
    internal func aThreadWithNothingToDoEnds() async {
        await #expect(processExitsWith: .success) {
            let lane = NSObject()
            Background.run(lane: lane) {
                // Nothing to do.
            }
            guard Background.waitUntilIdle(lane: lane, timeout: 120),
                Wait.until(seconds: 120, { Background.threadCount == 0 })
            else { exit(1) }
            exit(0)
        }
    }
}
