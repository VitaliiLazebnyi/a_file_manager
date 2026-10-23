import Foundation

/// Passwords that live as long as the program; for tests, which never touch the Keychain.
///
/// All state is guarded by `lock`.
public final class MemoryPasswords: PasswordStore, @unchecked Sendable {
    /// Guards `passwords`.
    private let lock = NSLock()
    /// The passwords by account.
    private var passwords: [String: String] = [:]

    /// The accounts that have a password, sorted.
    public var accounts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return passwords.keys.sorted()
    }

    /// An empty store.
    public init() {
        // No password yet.
    }

    /// The password kept under `account`, nil when there is none.
    public func password(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return passwords[account]
    }

    /// Keeps `password` under `account`; nil removes it.
    public func setPassword(_ password: String?, for account: String) {
        lock.lock()
        defer { lock.unlock() }
        passwords[account] = password
    }

    deinit {
        // Nothing to release.
    }
}
