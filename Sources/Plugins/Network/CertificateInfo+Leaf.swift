import CryptoKit
import Foundation
import Security

/// A description made from the certificate itself.
extension CertificateInfo {
    /// Describes the server's own certificate, the first of the chain.
    internal init(leaf: SecCertificate, problem: String) {
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
        self.init(
            fingerprint: digest.map { String(format: "%02X", $0) }.joined(separator: ":"),
            subject: (SecCertificateCopySubjectSummary(leaf) as String?) ?? "",
            problem: problem
        )
    }
}
