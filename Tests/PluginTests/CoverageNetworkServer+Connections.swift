import Foundation

@testable import NetworkPlugin

/// Scripts made of fixed answers, connections to the server, and what errors carry.
extension CoverageNetworkServer {
    /// What `init(replies:)` does for a command.
    internal enum Answer: ExpressibleByStringLiteral, Sendable {
        /// Sends the text.
        case text(String)
        /// Ends the control connection.
        case hangUp
        /// Does what the closure does.
        case act(@Sendable (Line) -> Void)

        /// Sends the text.
        internal init(stringLiteral value: String) {
            self = .text(value)
        }
    }

    /// A server that answers a command, or every command with a verb, as given for it, and
    /// everything else like `standard`.
    internal convenience init(replies: [String: Answer]) throws {
        try self.init { command, line in
            guard let answer = replies[command] ?? replies[Self.verb(command)] else {
                return .standard
            }
            switch answer {
            case .text(let text):
                line.send(text)

            case .hangUp:
                line.hangUp()

            case .act(let action):
                action(line)
            }
            return .handled
        }
    }

    /// The code of the reply a refusal carries; nil for any other error.
    internal static func code(of error: NetworkError?) -> Int? {
        guard case .refused(let reply) = error else {
            return nil
        }
        return reply.code
    }

    /// The text a network error carries (what timed out, what failed, what was unexpected).
    internal static func text(of error: NetworkError?) -> String? {
        switch error {
        case .timedOut(let text), .loginFailed(let text), .unexpected(let text), .connectionFailed(let text),
            .busy(let text), .incomplete(let text):
            return text

        default:
            return nil
        }
    }

    /// A connection to this server, not connected yet; `change` adjusts its settings.
    internal func connection(_ change: (inout FTPServerConfig) -> Void) -> FTPConnection {
        var config = FTPServerConfig(host: "127.0.0.1", port: port, timeout: 10)
        change(&config)
        return FTPConnection(config: config, trust: CertificateTrust())
    }

    /// A connection to this server, logged in; `change` adjusts its settings.
    internal func connected(_ change: (inout FTPServerConfig) -> Void) throws -> FTPConnection {
        let connection = connection(change)
        try connection.connect()
        return connection
    }

    /// A connection to this server with the usual settings, logged in.
    internal func connected() throws -> FTPConnection {
        try connected { _ in
            // The usual settings.
        }
    }
}
