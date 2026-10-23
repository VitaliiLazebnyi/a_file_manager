import Darwin
import Foundation
import Network
import TestSupport
import Testing

/// What the `AUTH TLS` framer does with Network's calls that the FTP connection never makes:
/// a wakeup does nothing, and what is sent through it goes to the server as it is.
///
/// The program's connections send nothing before the framer steps out of the way and schedule
/// no wakeup, so a framer of the test's own (`ForwardingFramer`) is ready at once and hands
/// Network's calls on to an `FTPAuthTLSFramer`.
@Suite
internal struct CoverageNetworkFramerOutput {
    /// `count` bytes read from `descriptor`; fewer when the other side closed first.
    private static func receive(_ count: Int, from descriptor: Int32) -> Data {
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: count)
        while received.count < count {
            let read = recv(descriptor, &buffer, count - received.count, 0)
            guard read > 0 else {
                break
            }
            received.append(contentsOf: buffer[0..<read])
        }
        return received
    }

    /// A wakeup the framer asked for comes, and bytes sent through it arrive unchanged.
    @Test
    internal func whatIsSentThroughTheFramerArrivesAsItIs() throws {
        let listener = try TestFTPServer.listen()
        defer { close(listener) }
        let accepted = Signal<Int32>()
        OtherThread.start { accepted.set(accept(listener, nil, nil)) }

        let woken = Signal<Bool>()
        let framer = NWProtocolFramer.Options(definition: ForwardingFramer.definition)
        framer[ForwardingFramer.wokenKey] = woken
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(framer, at: 0)
        let port = try #require(NWEndpoint.Port(rawValue: UInt16(TestFTPServer.port(of: listener))))
        let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
        let ready = Signal<Bool>()
        connection.stateUpdateHandler = { state in
            if case .ready = state { ready.set(true) }
        }
        connection.start(queue: DispatchQueue(label: "afm.test.framer"))
        defer { connection.cancel() }
        #expect(ready.wait() == true)
        #expect(woken.wait() == true)

        let peer = try #require(accepted.wait())
        defer { close(peer) }
        let message = Data("NOOP\r\n".utf8)
        let context = NWConnection.ContentContext(
            identifier: "message",
            metadata: [NWProtocolFramer.Message(definition: ForwardingFramer.definition)]
        )
        connection.send(content: message, contentContext: context, completion: .idempotent)
        #expect(Self.receive(message.count, from: peer) == message)
    }
}
