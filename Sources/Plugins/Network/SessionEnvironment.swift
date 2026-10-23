public import Foundation

/// What connections need from the program around them: the preferences, the certificates the
/// user accepted, and a way to ask the user.
///
/// The questions may be asked from any thread and block until they are answered.
///
/// The questions and the other settings are set while the plugin starts (tests set them when
/// they like) and read from any thread; they are guarded by `lock`. A question is taken under
/// the lock and asked without it.
public final class SessionEnvironment: @unchecked Sendable {
    /// Asks for the user name and password of a server, with the reason; nil when the user gives up.
    public typealias CredentialsQuestion = @Sendable (_ profile: ConnectionProfile, _ message: String) -> Credentials?
    /// Asks whether to accept a certificate the system does not trust.
    public typealias TrustQuestion = @Sendable (_ profile: ConnectionProfile, _ certificate: CertificateInfo) -> Bool
    /// Asks whether to accept a certificate in place of the ones accepted before (their fingerprints).
    public typealias ChangedTrustQuestion =
        @Sendable (_ profile: ConnectionProfile, _ certificate: CertificateInfo, _ known: [String]) -> Bool
    /// Asks a yes-or-no question about a server.
    public typealias ServerQuestion = @Sendable (_ profile: ConnectionProfile) -> Bool
    /// Keeps the password of a server.
    public typealias PasswordKeeper = @Sendable (_ profile: ConnectionProfile, _ password: String) -> Void
    /// Asks a question of the secure shell, which may be a secret to type; nil when the user gives up.
    public typealias SecretQuestion =
        @Sendable (_ profile: ConnectionProfile, _ question: String, _ isSecret: Bool) -> String?

    /// What can be set, in one place, for the lock.
    private struct Hooks {
        var askCredentials: CredentialsQuestion = { _, _ in nil }
        var askToTrust: TrustQuestion = { _, _ in false }
        var askToTrustChanged: ChangedTrustQuestion = { _, _, _ in false }
        var askToConnect: ServerQuestion = { _ in true }
        var askToSendPasswordUnprotected: ServerQuestion = { _ in true }
        var asksAboutUnprotectedLoopback = false
        var rememberPassword: PasswordKeeper = { _, _ in
            // Nothing is kept until the plugin sets a store.
        }
        var askSecret: SecretQuestion = { _, _, _ in nil }
        var declineMemory: TimeInterval = 5
        var log: @Sendable (String) -> Void = { _ in
            // Nothing is logged until the plugin sets a log.
        }
        var clock: @Sendable () -> Date = { Date() }
    }

    /// The network preferences, read from any thread.
    public let options: NetworkOptions
    /// The certificates the user accepted.
    public let trust: CertificateTrust
    private let lock = NSLock()
    private var hooks = Hooks()

    /// Asks for the user name and password of a server; `message` says why (the first time, or
    /// what the server answered to the last attempt).
    ///
    /// Nil when the user gives up.
    public var askCredentials: CredentialsQuestion {
        get { hook(\.askCredentials) }
        set { setHook(\.askCredentials, newValue) }
    }
    /// Shows a certificate the system does not trust; true when the user accepts it.
    ///
    /// The answer is recorded in `trust` by whoever asks.
    public var askToTrust: TrustQuestion {
        get { hook(\.askToTrust) }
        set { setHook(\.askToTrust, newValue) }
    }
    /// Shows a certificate that differs from the ones accepted for this server before
    /// (`known`, their fingerprints): the sign of somebody in the middle, or of a server that
    /// renewed its certificate.
    ///
    /// True when the user accepts the new one in place of the old; whoever asks records that with
    /// `CertificateTrust.replace`. Refused unless set.
    public var askToTrustChanged: ChangedTrustQuestion {
        get { hook(\.askToTrustChanged) }
        set { setHook(\.askToTrustChanged, newValue) }
    }
    /// Asks whether to connect to a server nobody chose (`ConnectionProfile.asksBeforeConnecting`).
    public var askToConnect: ServerQuestion {
        get { hook(\.askToConnect) }
        set { setHook(\.askToConnect, newValue) }
    }
    /// Asks whether to send a password over a connection that is not encrypted (plain FTP).
    public var askToSendPasswordUnprotected: ServerQuestion {
        get { hook(\.askToSendPasswordUnprotected) }
        set { setHook(\.askToSendPasswordUnprotected, newValue) }
    }
    /// A server on this machine itself (`localhost`, `127.0.0.1`) is not asked about: nothing
    /// sent there crosses a network.
    ///
    /// Tests set this to ask all the same.
    public var asksAboutUnprotectedLoopback: Bool {
        get { hook(\.asksAboutUnprotectedLoopback) }
        set { setHook(\.asksAboutUnprotectedLoopback, newValue) }
    }
    /// Stores the password the user asked to keep, after the server accepted it.
    ///
    /// Called on the connecting thread.
    public var rememberPassword: PasswordKeeper {
        get { hook(\.rememberPassword) }
        set { setHook(\.rememberPassword, newValue) }
    }
    /// Asks a question of the secure shell (a host key to confirm, the passphrase of a key).
    public var askSecret: SecretQuestion {
        get { hook(\.askSecret) }
        set { setHook(\.askSecret, newValue) }
    }
    /// After the user refused a password or a certificate, further attempts to connect to that
    /// server fail for this many seconds without asking again: one click on a folder leads to
    /// several questions to the file system, and the user answered once.
    public var declineMemory: TimeInterval {
        get { hook(\.declineMemory) }
        set { setHook(\.declineMemory, newValue) }
    }
    /// Receives the dialogue with the servers, line by line, from any thread.
    public var log: @Sendable (String) -> Void {
        get { hook(\.log) }
        set { setHook(\.log, newValue) }
    }
    /// The time by which connections age: how long one sat idle, how long nothing was done with
    /// a server, and when the links of a listing are no longer asked about in the background.
    ///
    /// The system's clock unless a test sets another.
    public var clock: @Sendable () -> Date {
        get { hook(\.clock) }
        set { setHook(\.clock, newValue) }
    }

    /// An environment that asks nobody: credentials and certificates are refused, the rest allowed.
    ///
    /// The plugin and the tests set the questions they answer.
    public init(options: NetworkOptions = NetworkOptions(), trust: CertificateTrust = CertificateTrust()) {
        self.options = options
        self.trust = trust
    }

    private func hook<Value>(_ path: KeyPath<Hooks, Value>) -> Value {
        lock.withLock { hooks[keyPath: path] }
    }

    private func setHook<Value>(_ path: WritableKeyPath<Hooks, Value>, _ value: Value) {
        lock.withLock { hooks[keyPath: path] = value }
    }

    deinit {
        // Nothing to release.
    }
}
