import Foundation

/// What the explicit-TLS start-up of a control connection reports back: the greeting it read,
/// or the reply that refused `AUTH TLS`.
///
/// Written on the connection's queue, read after the connection is ready or has failed.
///
/// All state is guarded by `lock`.
internal final class ExplicitTLSReport: @unchecked Sendable {
    private let lock = NSLock()
    private var greetingReply: FTPReply?
    private var refusalReply: FTPReply?

    /// The server's greeting, read before `AUTH TLS` was sent; nil until it came.
    internal var greeting: FTPReply? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return greetingReply
        }
        set {
            lock.lock()
            greetingReply = newValue
            lock.unlock()
        }
    }

    /// The reply that ended the start-up: a greeting that was not 220, or the answer to `AUTH TLS`
    /// that was not 234; nil while none did.
    internal var refusal: FTPReply? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return refusalReply
        }
        set {
            lock.lock()
            refusalReply = newValue
            lock.unlock()
        }
    }

    deinit {
        // Nothing to release.
    }
}
