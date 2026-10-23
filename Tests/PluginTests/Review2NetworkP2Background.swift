import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// The background work of one server never waits behind that of another (second pass: the
/// cause of network tests that failed when they ran beside a test with a server that is dead).
@Suite
internal struct Review2NetworkP2Background {
    /// A lane whose work never ends runs only its share, and another lane's work gets through.
    @Test
    internal func aLaneThatIsStuckHoldsUpOnlyItself() {
        // Two lanes: of the object that names a lane only its identity counts.
        let (stuck, free) = (NSObject(), NSObject())
        let release = DispatchSemaphore(value: 0)
        let started = Shared<[Int]>([])
        // Far more pieces than the lane may run at once, none of which ends by itself.
        let pieces = Background.mostPerLane * 4
        for index in 0..<pieces {
            Background.run(lane: stuck) {
                started.modify { $0.append(index) }
                release.wait()
            }
        }
        // The other lane's work gets through all the same, however long this takes to be seen.
        let done = DispatchSemaphore(value: 0)
        for _ in 0..<5 { Background.run(lane: free) { done.signal() } }
        for _ in 0..<5 { #expect(done.wait(timeout: .now() + 300) == .success) }
        #expect(Background.waitUntilIdle(lane: free, timeout: Wait.ceiling))
        // Of the stuck lane only so many run, and the wait for it says it is not done.
        #expect(started.value.count <= Background.mostPerLane)
        #expect(!Background.waitUntilIdle(lane: stuck, timeout: 0.2))
        #expect(Background.threadCount <= Background.mostThreads)
        // Let go, every piece runs, in the order it was queued within what ran together.
        for _ in 0..<pieces { release.signal() }
        #expect(Background.waitUntilIdle(lane: stuck, timeout: Wait.ceiling))
        #expect(started.value.sorted() == Array(0..<pieces))
    }

    /// Readers left hanging on a dead server do not keep a healthy server's connection from coming back.
    @Test
    internal func aDeadServerDoesNotKeepAnotherServersConnectionFromComingBack() throws {
        // One server that never sends a byte of a file, with readers dropped in the middle:
        // each waits in the background for an answer that does not come.
        var dead = TestFTPServer.Options()
        dead.stallRETR = true
        let stalled = try FTPFixture(dead) { values in
            values.parallelConnections = 8
            values.timeout = 600
        }
        try stalled.box.file("srv/f.bin", "zzzz")
        var abandoned: [AdoptOutcome] = []
        for _ in 0..<8 {
            var reader: (any FileReader)? = try stalled.fileSystem.read(stalled.url("/f.bin"))
            let pending = reader
            abandoned.append(AdoptOutcome { _ = try pending?.read(upToCount: 10) })
            #expect(adoptWait { stalled.server.commands.filter { $0.hasPrefix("RETR") }.count == abandoned.count })
            reader?.interrupt()
            reader = nil
        }
        // Meanwhile another server is used as usual, and its connection comes back at once.
        let fixture = try FTPFixture { $0.parallelConnections = 1 }
        try Data(repeating: 7, count: 2_000_000).write(to: fixture.box.url("srv/big.bin"))
        for _ in 0..<4 {
            let reader = try fixture.fileSystem.read(fixture.url("/big.bin"))
            #expect(try reader.read(upToCount: 100)?.count == 100)
            reader.close()
            #expect(fixture.settle(), "the connection of a healthy server waited behind a dead one")
        }
        #expect(try fixture.names("/") == ["big.bin"])
        stalled.center.disconnectAll()
        stalled.server.stop()
        for outcome in abandoned { #expect(outcome.ended()) }
    }
}
