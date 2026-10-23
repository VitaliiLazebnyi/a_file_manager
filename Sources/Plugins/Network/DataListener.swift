import AFMKernel
import Foundation
import Network

/// Waits for the server to open a data connection to us (active mode, spec 11 › Active mode,
/// passive mode and the data connection).
///
/// Used by one thread.
///
/// Only the server is let in: the listener is bound to the address the control connection
/// uses on this side, and a connection from any address but the control connection's other
/// end is closed and the wait goes on. Whoever else reaches the port in the meantime neither
/// receives an upload nor supplies a download or a listing.
internal final class DataListener {
    private var listener: NWListener
    private let queue = DispatchQueue(label: "afm.network.listener")
    private let accepted = Pending<NWConnection>()
    private let peer: String

    /// `peer` is the address of the server, `local` the address of this end of the control connection.
    internal init(peer: String, local: String) throws {
        self.peer = Self.comparable(peer)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(local), port: .any)
        listener = try NWListener(using: parameters)
    }

    /// The text of an address without what differs between two spellings of the same one: the
    /// zone of a link-local address, and the IPv6 form of an IPv4 address.
    internal static func comparable(_ address: String) -> String {
        var text = address.lowercased()
        if let zone = text.firstIndex(of: "%") { text = String(text[..<zone]) }
        if text.hasPrefix("::ffff:"), text.contains(".") { text = String(text.dropFirst(7)) }
        return ServerKey.bare(text)
    }

    /// Starts listening and returns the port.
    internal func start(timeout: TimeInterval) throws -> Int {
        if let port = try? begin(timeout: timeout) {
            return port
        }
        // The one address could not be listened on (an address with a zone, say): every
        // address then, with the same check of who connects.
        listener.cancel()
        listener = try NWListener(using: .tcp, on: .any)
        return try begin(timeout: timeout)
    }

    /// Waits for the server's connection and returns it started; the listener stops either way.
    internal func accept(timeout: TimeInterval, cancellation: CancellationFlag?) throws -> NetStream {
        defer { listener.cancel() }
        guard let connection = try accepted.wait(timeout: timeout, cancellation: cancellation) else {
            throw NetworkError.timedOut("waiting for the server's data connection")
        }
        let stream = NetStream(accepted: connection)
        stream.start()
        return stream
    }

    /// Stops listening; a connection the server opens now is refused.
    internal func cancel() { listener.cancel() }

    private func begin(timeout: TimeInterval) throws -> Int {
        let started = Pending<Bool>()
        listener.newConnectionHandler = { [accepted, peer] connection in
            guard case .hostPort(let host, _) = connection.endpoint, Self.comparable("\(host)") == peer else {
                // Not the server: turned away, and the wait goes on.
                connection.cancel()
                return
            }
            accepted.fulfill(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                started.fulfill(true)

            case .failed, .cancelled:
                started.fulfill(false)

            default:
                break
            }
        }
        listener.start(queue: queue)
        guard try started.wait(timeout: timeout, cancellation: nil) == true, let port = listener.port else {
            throw NetworkError.connectionFailed("No port is available for the server to connect to.")
        }
        return Int(port.rawValue)
    }

    deinit { listener.cancel() }
}
