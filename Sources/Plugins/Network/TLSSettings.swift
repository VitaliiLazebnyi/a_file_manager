import Foundation
import Network
import Security

/// What a TLS connection needs to know: whose certificate to expect and which exceptions the
/// user made.
///
/// `rejected` receives the certificate when the handshake fails because of it, so
/// the thread that connects can ask the user and try again.
///
/// `rejected` is guarded by `lock`; nothing else changes after `init`.
internal final class TLSSettings: @unchecked Sendable {
    /// Where certificates are checked.
    ///
    /// The check may ask the network (revocation) and take seconds; on a queue of its own it holds
    /// up neither the stream it belongs to nor another.
    private static let verifyQueue = DispatchQueue(
        label: "afm.network.verify",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// The server's name or address, which its certificate must name.
    internal let host: String
    /// The certificates the user accepted.
    internal let trust: CertificateTrust
    /// Called where a certificate is checked, before the check; tests make a check slow with it.
    internal let beforeEvaluating: @Sendable () -> Void
    private let lock = NSLock()
    private var rejectedCertificate: CertificateInfo?

    /// The certificate of the last failed check, for the thread that connects; nil while every
    /// check passed.
    internal var rejected: CertificateInfo? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return rejectedCertificate
        }
        set {
            lock.lock()
            rejectedCertificate = newValue
            lock.unlock()
        }
    }

    /// True when the host is a name; an address in text form has no server name to announce.
    private var isName: Bool { IPv4Address(host) == nil && IPv6Address(host) == nil }

    /// Settings that run `beforeEvaluating` before every check of a certificate.
    internal init(host: String, trust: CertificateTrust, beforeEvaluating: @escaping @Sendable () -> Void) {
        self.host = host
        self.trust = trust
        self.beforeEvaluating = beforeEvaluating
    }

    /// Settings for a connection to `host`, with nothing to do before a check.
    internal convenience init(host: String, trust: CertificateTrust) {
        self.init(host: host, trust: trust) {
            // The check starts at once.
        }
    }

    /// Options for `NWProtocolTLS` that verify the server like the system does, and accept what
    /// the user accepted before.
    internal func options() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        if isName { sec_protocol_options_set_tls_server_name(security, host) }
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_verify_block(
            security,
            { [self] _, secTrust, complete in
                beforeEvaluating()
                complete(evaluate(sec_trust_copy_ref(secTrust).takeRetainedValue()))
            },
            Self.verifyQueue
        )
        return options
    }

    /// Whether the certificate chain is good for this host: trusted by the system and issued to
    /// the host (a name must match a DNS name of the certificate, an address one of its IP
    /// addresses), or accepted by the user before.
    ///
    /// A chain that fails is remembered in `rejected` for the thread that connects, which asks the
    /// user.
    internal func evaluate(_ trust: SecTrust) -> Bool {
        // The host is given in both cases: for an address Security compares the certificate's
        // IP addresses, and without it no name would be checked at all.
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            return true
        }
        // A failed evaluation always says why (`SecTrustEvaluateWithError` sets the error whenever
        // it returns false), and the chain of an evaluated trust is never empty: it starts with
        // the server's own certificate, the one the trust was made with.
        // swiftlint:disable:next force_unwrapping
        let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])!.first!
        // swiftlint:disable:next force_unwrapping
        let info = CertificateInfo(leaf: leaf, problem: CFErrorCopyDescription(error!) as String)
        if self.trust.isAccepted(info.fingerprint, for: host) {
            return true
        }
        rejected = info
        return false
    }

    deinit {
        // Nothing to release.
    }
}
