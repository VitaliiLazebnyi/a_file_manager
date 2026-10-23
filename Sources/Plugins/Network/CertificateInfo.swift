/// What the user is shown of a certificate that could not be verified (spec 11 › Certificates).
public struct CertificateInfo: Equatable, Sendable {
    /// SHA-256 of the certificate, as `AB:CD:…`.
    public let fingerprint: String
    /// Whom the certificate was issued to, as the system sums it up.
    public let subject: String
    /// Why the system does not trust it.
    public let problem: String
}
