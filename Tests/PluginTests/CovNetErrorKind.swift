@testable import NetworkPlugin

/// Which `NetworkError` an error is, without what it carries.
internal enum CovNetErrorKind: String {
    /// A wait that nothing moved ended.
    case busy = "busy"
    /// A wait ended with the caller's flag.
    case cancelled = "cancelled"
    /// The connection could not be made.
    case connectionFailed = "connectionFailed"
    /// The connection broke off.
    case connectionLost = "connectionLost"
    /// Something was done only in part.
    case incomplete = "incomplete"
    /// The login was refused.
    case loginFailed = "loginFailed"
    /// The session is not connected.
    case notConnected = "notConnected"
    /// Not a `NetworkError`, or none at all.
    case other = "other"
    /// The server refused a command.
    case refused = "refused"
    /// The server wants its TLS session resumed.
    case sessionReuseRequired = "sessionReuseRequired"
    /// The server did not answer in time.
    case timedOut = "timedOut"
    /// The server answered with something that was not expected.
    case unexpected = "unexpected"
    /// The server's certificate is not trusted.
    case untrustedCertificate = "untrustedCertificate"

    /// The kind of `error`: the name of its case.
    internal init(_ error: (any Error)?) {
        guard let network = error as? NetworkError else {
            self = .other
            return
        }
        let name = String(String(describing: network).prefix(while: \.isLetter))
        self = Self(rawValue: name) ?? .other
    }
}
