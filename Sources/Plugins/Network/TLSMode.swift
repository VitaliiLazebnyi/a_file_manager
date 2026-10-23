/// How a connection to an FTP server is secured (spec 11 › Address and URL syntax).
///
/// The raw values are what the settings file stores.
public enum TLSMode: Int, Codable, Equatable, Sendable {
    /// `AUTH TLS` on the plain control connection (`ftpes://`, and `ftps://` on any port but 990).
    case explicit = 1
    /// Encrypted from the first byte (`ftpis://`, and `ftps://` on port 990).
    case implicit = 2
    /// Plain FTP, nothing encrypted.
    case plain = 0
}
