public import Foundation

/// What can go wrong between this program and a server.
public enum NetworkError: LocalizedError, Sendable {
    /// A wait for a connection of the server's pool, or for another thread's login, that ended
    /// because nothing moved for too long.
    case busy(String)
    /// The user or the program gave up the operation.
    case cancelled
    /// No connection to the server could be made; the text says why.
    case connectionFailed(String)
    /// A connection that was made broke or was closed.
    case connectionLost
    /// Something was done only in part; the text says what is where now.
    case incomplete(String)
    /// The server did not accept the login; the text says why.
    case loginFailed(String)
    /// The session was disconnected; the text names the server.
    case notConnected(String)
    /// The server answered a command with an error.
    case refused(FTPReply)
    /// An FTPS server insists that data connections resume the control connection's TLS
    /// session, which `Network.framework` gives no way to do.
    case sessionReuseRequired(String)
    /// The server did not answer in time; the text says what was waited for.
    case timedOut(String)
    /// The server answered something that makes no sense here; the text says what.
    case unexpected(String)
    /// The system does not trust the server's certificate and the user did not accept it.
    case untrustedCertificate(CertificateInfo)

    /// The message the user is shown.
    public var errorDescription: String? {
        switch self {
        case .timedOut(let what):
            return "The server did not answer in time (\(what))."

        case .connectionFailed(let why):
            return "Connect call failed! \(why)"

        case .connectionLost:
            return "The connection to the server was lost."

        case .cancelled:
            return "The operation was cancelled."

        case .refused(let reply):
            return "The server answered: \(reply.message)"

        case .loginFailed(let why):
            return "Login failed. \(why)"

        case .untrustedCertificate(let info):
            return "The server's certificate is not trusted: \(info.problem)"

        case .unexpected(let what):
            return "Unexpected answer from the server: \(what)"

        case .notConnected(let server):
            return "There is no connection to \(server)."

        case .sessionReuseRequired(let said):
            return "The server requires the encrypted data connections to reuse the TLS session of the control "
                + "connection, which this program does not support (the server said: \(said)). "
                + "Turn off \"require session reuse\" on the server (vsftpd: require_ssl_reuse=NO) or use SFTP."

        case .incomplete(let what):
            return what

        case .busy(let what):
            return what
        }
    }

    /// True when the connection itself is gone, so the same command may work on a new one.
    internal var isConnectionLevel: Bool {
        switch self {
        case .connectionLost, .timedOut, .connectionFailed:
            return true

        case .refused(let reply):
            return reply.code == 421

        default:
            return false
        }
    }
}
