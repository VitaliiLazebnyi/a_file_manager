import Darwin.C
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// The start and the end of a child where the system fails: out of memory before the start, a
/// signal during the wait for the end, a child that someone else collected.
@Suite
internal struct SweepChildProcessTests {
    /// The system's calls, with the waits answered from `answers` in order.
    private static func calls(answering answers: [(result: pid_t, error: Int32)]) -> ChildProcess.SystemCalls {
        let left = Shared(answers)
        var calls = ChildProcess.SystemCalls.system
        calls.wait = { _, status, _ in
            status = 0
            var next: (result: pid_t, error: Int32) = (0, 0)
            left.modify { if !$0.isEmpty { next = $0.removeFirst() } }
            return next
        }
        return calls
    }

    /// A start for which the system has no memory left fails with the system's error, whichever
    /// of the two preparations it refuses.
    @Test
    internal func aStartWithoutMemoryFailsWithTheSystemsError() {
        var noActions = ChildProcess.SystemCalls.system
        noActions.initActions = { _ in ENOMEM }
        var noAttributes = ChildProcess.SystemCalls.system
        noAttributes.initAttributes = { _ in ENOMEM }
        for calls in [noActions, noAttributes] {
            // `errno` says something else: the error is the one the call returned.
            errno = ENOENT
            let started = ChildProcess.spawn(
                executable: "/usr/bin/true",
                arguments: [],
                environment: [:],
                directory: "/",
                calls: calls
            )
            guard case .failure(let failure) = started else {
                Issue.record("started: \(started)")
                continue
            }
            #expect(failure.code == ENOMEM)
        }
    }

    /// A wait that a signal broke off is asked again; a child that someone else collected is
    /// reported as ended without a status, once.
    @Test
    internal func aChildCollectedElsewhereIsReportedOnce() {
        // Running at the first look; then a signal, then gone.
        let calls = Self.calls(answering: [(0, 0), (-1, EINTR), (-1, ECHILD)])
        let endings = Shared<[Int32?]>([])
        // A process that does not end while the test runs: this one.
        let watch = ChildProcess.Watch(pid: getpid(), calls: calls) { ending in
            endings.modify { $0.append(ending.status) }
        }
        watch.start()
        #expect(endings.value.isEmpty)
        watch.reap(waiting: true)
        #expect(endings.value == [nil])
        // Told again (the system's report after the first look found it): reported once only.
        watch.reap(waiting: true)
        #expect(endings.value == [nil])
    }
}
