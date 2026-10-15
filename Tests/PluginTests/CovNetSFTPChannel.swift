import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// The SFTP channel: its child process, its pipes, and writers that wait for one another.
@Suite(.enabled(if: FakeSFTPServer.isAvailable))
internal struct CovNetSFTPChannel {
    private let box: Sandbox

    /// A fresh sandbox.
    internal init() throws {
        box = try Sandbox()
    }

    /// A program that cannot be started is a connection that failed.
    @Test
    internal func aProgramThatCannotBeStartedIsAFailedConnection() {
        let channel = SFTPChannel(
            executable: box.url("no-such-program").path,
            arguments: [],
            environment: [:]
        )
        defer { channel.close() }
        let error = #expect(throws: NetworkError.self) {
            try channel.start(timeout: 10, cancellation: nil) { true }
        }
        #expect(CovNetErrorKind(error) == .connectionFailed)
    }

    /// A process that never greets is given up when the time for the login is over, after asking the service.
    @Test
    internal func aProcessThatNeverGreetsIsGivenUp() {
        let channel = SFTPChannel(executable: "/bin/sleep", arguments: ["600"], environment: [:])
        defer { channel.close() }
        let asked = Signal<Bool>()
        let error = #expect(throws: NetworkError.self) {
            try channel.start(timeout: 0.3, cancellation: nil) {
                asked.set(true)
                return true
            }
        }
        #expect(CovNetErrorKind(error) == .timedOut)
        #expect(asked.wait(seconds: 0) == true)
    }

    /// What the caller puts into the environment wins over what this process has.
    @Test
    internal func theCallersEnvironmentWins() throws {
        let channel = try CovNetRawSFTP.channel(
            .home,
            in: box,
            environment: ["HOME": "/afm/elsewhere"],
            writeTimeout: 60
        )
        defer { channel.close() }
        try channel.start(timeout: 30, cancellation: nil) { true }
        #expect(Wait.until { channel.errorMessage == "/afm/elsewhere" })
    }

    /// Of a long error output, the last lines are kept, also of what comes after the dialogue ended.
    @Test(arguments: [CovNetRawSFTP.Scene.chatty, .lastWords])
    internal func ofALongErrorOutputTheLastLinesAreKept(scene: CovNetRawSFTP.Scene) throws {
        let channel = try CovNetRawSFTP.channel(scene, in: box)
        defer { channel.close() }
        try channel.start(timeout: 30, cancellation: nil) { true }
        let said = { channel.errorMessage.hasSuffix("the last word") }
        #expect(Wait.until(said))
        let lines = channel.errorMessage.split(separator: "\n")
        #expect(lines.count == 3 && lines.first?.hasPrefix("line 398 ") == true)
    }

    /// A channel nobody holds goes, also while its process lives on, and what the process still sends is dropped.
    @Test
    internal func aChannelNobodyHoldsGoes() throws {
        var channel: SFTPChannel? = try CovNetRawSFTP.channel(.lingering, in: box)
        try channel?.start(timeout: 30, cancellation: nil) { true }
        weak let gone = channel
        channel = nil
        #expect(gone == nil)
        // Its input was closed on the way: the process sent its last packet to nobody.
        #expect(Wait.until { box.exists("lingered") })
    }

    /// A success where an answer was expected is not that answer.
    @Test
    internal func aSuccessIsNotAnAnswer() {
        var success = SFTPEncoder()
        success.u32(0)
        let error = #expect(throws: NetworkError.self) {
            _ = try SFTPPacket(kind: .status, body: success.data).expect(.handle)
        }
        #expect(CovNetErrorKind(error) == .unexpected)
    }

    /// A request with a flag that is set is not sent.
    @Test
    internal func aRequestWithASetFlagIsNotSent() throws {
        let channel = try CovNetRawSFTP.channel(.home, in: box)
        defer { channel.close() }
        try channel.start(timeout: 30, cancellation: nil) { true }
        let flag = CancellationFlag()
        flag.cancel()
        let error = #expect(throws: NetworkError.self) {
            _ = try channel.send(.realpath, cancellation: flag) { $0.string(".") }
        }
        #expect(CovNetErrorKind(error) == .cancelled)
        #expect(!channel.isClosed)
    }

    /// A request to a closed channel fails at once; one whose answer nobody needs is dropped.
    @Test
    internal func aClosedChannelTakesNoRequests() throws {
        let channel = try CovNetRawSFTP.channel(.home, in: box)
        try channel.start(timeout: 30, cancellation: nil) { true }
        channel.close()
        channel.sendWithoutAnswer(.close) { $0.bytes(Data([1])) }
        let sent = #expect(throws: NetworkError.self) { _ = try channel.send(.realpath) { $0.string(".") } }
        #expect(CovNetErrorKind(sent) == .connectionLost)
        let started = #expect(throws: NetworkError.self) { try channel.start(timeout: 30, cancellation: nil) { true } }
        #expect(CovNetErrorKind(started) == .connectionLost)
    }

    /// Closing a channel while a packet is stuck in the pipe ends the writer, and the writers that wait for it
    /// can be cancelled.
    @Test
    internal func closingEndsAWriterThatIsStuck() throws {
        let channel = try CovNetRawSFTP.channel(.stuck, in: box)
        defer { channel.close() }
        try channel.start(timeout: 30, cancellation: nil) { true }
        let writing = AdoptOutcome { _ = try channel.send(.write) { $0.bytes(Data(count: 1_000_000)) } }
        // The server read the start of the packet and stopped: the writer is in the middle of it.
        #expect(Wait.until { channel.errorMessage == "stuck" })
        let flag = CancellationFlag()
        let waiting = AdoptOutcome { _ = try channel.send(.realpath, cancellation: flag) { $0.string(".") } }
        adoptCancel(flag)
        #expect(waiting.ended() && CovNetErrorKind(waiting.thrown) == .cancelled)
        #expect(!channel.isClosed, "a writer that was cancelled before its first byte leaves the channel open")
        channel.close()
        #expect(writing.ended() && writing.failed)
    }

    /// A writer that waits longer for its turn than a write may take gives the channel up.
    @Test
    internal func aWriterThatWaitsTooLongForItsTurnGivesTheChannelUp() throws {
        let channel = try CovNetRawSFTP.channel(.trickle, in: box, environment: [:], writeTimeout: 3)
        defer { channel.close() }
        try channel.start(timeout: 30, cancellation: nil) { true }
        // Some 25 seconds for the server, which takes it in slowly but steadily.
        let writing = AdoptOutcome { _ = try channel.send(.write) { $0.bytes(Data(count: 5_000_000)) } }
        // The packet is on its way: the writer has the pipe.
        #expect(Wait.until { channel.errorMessage == "taking" })
        let waiting = AdoptOutcome { _ = try channel.send(.realpath) { $0.string(".") } }
        #expect(waiting.ended() && CovNetErrorKind(waiting.thrown) == .timedOut)
        #expect(Wait.until { channel.isClosed })
        #expect(writing.ended() && writing.failed)
    }
}
