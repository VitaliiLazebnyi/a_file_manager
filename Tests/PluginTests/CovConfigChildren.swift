import Foundation
import Testing

@testable import ConfigurationPlugin

/// The programs a chain of user commands waits for, and how they end.
@Suite
internal struct CovConfigChildren {
    /// A program a chain waits for ends when the chain is stopped; ended by a signal, it has no exit status.
    @Test
    internal func aWaitedForProgramEndsWhenTheChainStops() async throws {
        let pid =
            try ChildProcess.spawn(
                executable: "/bin/sleep",
                arguments: ["600"],
                environment: [:],
                directory: "/"
            )
            .get()
        let table = ChildTable()
        let ending: ChildProcess.Ending = await withCheckedContinuation { continuation in
            table.watch(pid, waitedFor: true) { continuation.resume(returning: $0) }
            table.terminateWaitedFor()
        }
        #expect(ending.status == nil)
    }
}
