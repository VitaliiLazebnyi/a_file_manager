import Foundation

/// The certificates the user chose to trust although the system does not, by server.
///
/// Safe from any thread.
///
/// The certificates trusted for good are not read from the settings, which a file from
/// somebody else can replace: `load` fetches them, on first use, from where only the user's
/// own answers are kept (the Keychain).
///
/// `load` does not change after `init`; everything else is guarded by `lock`.
public final class CertificateTrust: @unchecked Sendable {
    /// Reads the certificates that were accepted for good.
    ///
    /// Called once, on the thread that first connects with TLS, never on the main thread by this
    /// module.
    public let load: (@Sendable () -> [String: [String]])?
    private let lock = NSLock()
    private var accepted: [String: Set<String>]
    private var isLoaded = false

    /// Trust that starts with `accepted` (fingerprints by host) and reads the stored ones with `load`
    /// when it is first asked to (`prepare`).
    @preconcurrency
    public init(accepted: [String: [String]] = [:], load: (@Sendable () -> [String: [String]])? = nil) {
        self.load = load
        self.accepted = [:]
        for (host, fingerprints) in accepted { self.accepted[host.lowercased(), default: []].formUnion(fingerprints) }
    }

    /// Fetches the stored certificates if that was not done yet.
    ///
    /// May take a moment.
    public func prepare() {
        lock.lock()
        let loader = isLoaded ? nil : load
        isLoaded = true
        lock.unlock()
        guard let stored = loader?() else {
            return
        }
        lock.lock()
        for (host, fingerprints) in stored { accepted[host.lowercased(), default: []].formUnion(fingerprints) }
        lock.unlock()
    }

    /// Whether the user accepted the certificate with this fingerprint for the server; the host's case
    /// does not matter.
    public func isAccepted(_ fingerprint: String, for host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return accepted[host.lowercased()]?.contains(fingerprint) ?? false
    }

    /// The certificates accepted for a server so far, in order.
    public func fingerprints(for host: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return (accepted[host.lowercased()] ?? []).sorted()
    }

    /// Trusts the certificate with this fingerprint for the server from now on, besides those trusted
    /// before.
    public func accept(_ fingerprint: String, for host: String) {
        lock.lock()
        defer { lock.unlock() }
        accepted[host.lowercased(), default: []].insert(fingerprint)
    }

    /// Makes `fingerprint` the only certificate accepted for the server: the answer to a
    /// certificate that changed.
    ///
    /// The ones accepted before are no longer trusted.
    public func replace(with fingerprint: String, for host: String) {
        lock.lock()
        defer { lock.unlock() }
        accepted[host.lowercased()] = [fingerprint]
    }

    deinit {
        // Nothing to release.
    }
}
