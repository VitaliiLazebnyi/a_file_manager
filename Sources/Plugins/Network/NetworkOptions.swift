import AFMKernel
public import Foundation

/// The user's network preferences as the connections need them.
///
/// The settings store belongs to the main thread, so its values are copied here whenever they
/// change; this copy is read from any thread.
///
/// All state is guarded by `lock`.
public final class NetworkOptions: @unchecked Sendable {
    /// One copy of the preferences, taken and replaced as a whole.
    public struct Values: Sendable {
        /// Whether an FTP connection opens its data connections passively unless its profile says otherwise.
        public var passiveByDefault = true
        /// Seconds between two NOOPs on an idle connection; 0 sends none.
        public var keepAliveInterval: TimeInterval = 60
        /// How file contents travel.
        public var transferMode = TransferMode.binary
        /// How many connections to one server serve listings and commands at the same time.
        public var parallelConnections = 3
        /// The masks of the files that the automatic transfer mode sends as text, separated by spaces.
        public var textFileMasks = NetworkOptions.defaultTextMasks
        /// The password sent with an anonymous login.
        public var anonymousPassword = NetworkOptions.defaultAnonymousPassword
        /// Seconds a connection waits for a server before it gives up.
        public var timeout: TimeInterval = 30

        /// The preferences as a new installation has them.
        public init() {
            // Every member starts at its declared value.
        }
    }

    /// The masks of the files sent as text in the automatic mode, until the user changes them.
    public static let defaultTextMasks = "*.txt *.htm* *.xml *.css *.js *.json *.md *.csv *.ini *.sh *.php *.py *.pl"
    /// The password of an anonymous login, until the user changes it.
    public static let defaultAnonymousPassword = "anonymous@example.com"

    private let lock = NSLock()
    private var current = Values()

    /// The preferences now in force; read and set from any thread.
    public var values: Values {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            lock.unlock()
        }
    }

    /// Options with the values of a new installation.
    public init() {
        // `current` starts with the defaults.
    }

    /// Whether a file of this name is transferred as text.
    internal func transfersAsText(_ name: String) -> Bool {
        let snapshot = values
        switch snapshot.transferMode {
        case .binary:
            return false

        case .text:
            return true

        case .automatic:
            return FileMask(snapshot.textFileMasks).matches(name)
        }
    }

    deinit {
        // Nothing to release.
    }
}
