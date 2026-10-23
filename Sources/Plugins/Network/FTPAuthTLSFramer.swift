import Foundation
import Network

/// Explicit FTPS (`AUTH TLS`, RFC 4217) for `Network.framework`, whose connections cannot switch
/// to TLS half-way by themselves.
///
/// This protocol sits on top of TCP, reads the server's greeting, sends `AUTH TLS`, and after the
/// `234` puts TLS underneath itself and steps out of the way; the connection reports ready when the
/// handshake is done.
internal final class FTPAuthTLSFramer: NWProtocolFramerImplementation {
    /// The name of the protocol in the connection's stack.
    internal static let label = "afm-ftp-auth-tls"
    /// The protocol, to be put into a connection's options.
    internal static let definition = NWProtocolFramer.Definition(implementation: FTPAuthTLSFramer.self)
    /// The key of the framer option that holds the `NWProtocolTLS.Options` to switch to.
    internal static let tlsKey = "tls"
    /// The key of the framer option that holds the `ExplicitTLSReport`.
    internal static let reportKey = "report"

    private var parser = FTPReplyParser()
    private var askedForTLS = false

    /// A framer for one connection; it keeps nothing of the instance.
    internal init(framer _: NWProtocolFramer.Instance) {
        // Everything it needs comes with the input and the options.
    }

    /// The next whole line that arrived, without its line end; nil while none has.
    ///
    /// One line at a time, so nothing that follows the last reply is taken away.
    private static func nextLine(_ framer: NWProtocolFramer.Instance) -> String? {
        var line: String?
        _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 16_384) { buffer, _ in
            guard let buffer, let end = buffer.firstIndex(of: 0x0A) else {
                return 0
            }
            var bytes = Array(buffer[..<end])
            if bytes.last == 0x0D { bytes.removeLast() }
            line = String(repairingUTF8: bytes)
            return end + 1
        }
        return line
    }

    /// The connection is ready only when the TLS handshake after `AUTH TLS` is done.
    internal func start(framer _: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .willMarkReady }

    /// Nothing waits for a timer.
    internal func wakeup(framer _: NWProtocolFramer.Instance) {
        // No timer is ever scheduled.
    }

    /// Stops at once: there is nothing to say goodbye with.
    internal func stop(framer _: NWProtocolFramer.Instance) -> Bool { true }

    /// Nothing to release.
    internal func cleanup(framer _: NWProtocolFramer.Instance) {
        // The framer holds no resources of the connection.
    }

    /// Sends what the connection writes as it is: only `AUTH TLS` is the framer's own.
    internal func handleOutput(
        framer: NWProtocolFramer.Instance,
        message _: NWProtocolFramer.Message,
        messageLength: Int,
        isComplete _: Bool
    ) {
        try? framer.writeOutputNoCopy(length: messageLength)
    }

    /// Reads the greeting, sends `AUTH TLS`, and on its `234` puts TLS underneath and passes
    /// everything through from then on; any other reply fails the connection.
    internal func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        let report = framer.options[Self.reportKey] as? ExplicitTLSReport
        while let line = Self.nextLine(framer) {
            // A reply of several lines is complete with its last; 120 says the server is not ready yet.
            guard let reply = parser.feed(line), reply.code != 120 else { continue }
            if !askedForTLS {
                guard reply.code == 220 else {
                    return fail(framer, report, reply)
                }
                report?.greeting = reply
                askedForTLS = true
                framer.writeOutput(data: Data("AUTH TLS\r\n".utf8))
                continue
            }
            guard reply.code == 234, let tls = framer.options[Self.tlsKey] as? NWProtocolTLS.Options,
                (try? framer.prependApplicationProtocol(options: tls)) != nil
            else {
                return fail(framer, report, reply)
            }
            framer.passThroughInput()
            framer.passThroughOutput()
            framer.markReady()
            return 0
        }
        return 0
    }

    private func fail(_ framer: NWProtocolFramer.Instance, _ report: ExplicitTLSReport?, _ reply: FTPReply) -> Int {
        report?.refusal = reply
        framer.markFailed(error: .posix(.EPROTO))
        return 0
    }

    deinit {
        // Nothing to release.
    }
}
