import Foundation
import TestSupport
import Testing

@testable import AFMShell

/// The program's own threads: the pool for computing and the lanes for the file systems.
@MainActor
@Suite(.serialized)
internal struct AppBackgroundTests {
    /// More computations than the pool has threads wait for a free one, and all of them run.
    @Test
    internal func workBeyondThePoolsThreadsWaitsAndRunsAllTheSame() async {
        let count = 2 * max(2, ProcessInfo.processInfo.activeProcessorCount) + 1
        let gate = DispatchSemaphore(value: 0)
        let started = Shared(0)
        let finished = Shared(0)
        for _ in 0..<count {
            Background.compute {
                started.change { $0 += 1 }
                gate.wait()
                finished.change { $0 += 1 }
            }
        }
        // The pool is full: the rest waits, and nothing has finished.
        #expect(await AppWait.until { started.value >= 2 })
        #expect(started.value < count && finished.value == 0)
        for _ in 0..<count {
            gate.signal()
        }
        #expect(await AppWait.until { finished.value == count })
    }

    /// A lane of background or utility work runs at that class.
    @Test
    internal func aLaneRunsAtTheQualityItWasAskedFor() async {
        var classes: [String: qos_class_t] = [:]
        for (name, qos) in [("background", QualityOfService.background), ("utility", .utility)] {
            let place = URL(fileURLWithPath: "/lane/\(name)")
            Background.storage("quality", at: place, qos: qos, work: { qos_class_self() }, then: { classes[name] = $0 })
        }
        #expect(await AppWait.until { classes.count == 2 })
        #expect(classes == ["background": QOS_CLASS_BACKGROUND, "utility": QOS_CLASS_UTILITY])
    }

    /// Letting go of a value empties the variable; nothing happens to one that is empty.
    @Test
    internal func releasingEmptiesTheVariable() {
        var data: Data? = Data(count: 1_000)
        Background.release(&data)
        #expect(data == nil)
        Background.release(&data)
        #expect(data == nil)
    }
}
