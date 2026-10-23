import Foundation
import Security

/// Passwords in the user's login Keychain, as generic passwords under one service name
/// (spec 11 › Encrypt and the master password: the Keychain takes the place of both the
/// scrambled passwords in the settings file and the master password that protects them).
public final class KeychainPasswords: PasswordStore {
    /// The four calls of the Security framework this class makes; tests put a recording
    /// stand-in in their place, so the order of the calls is tested without a Keychain.
    internal struct Calls {
        /// `SecItemCopyMatching`: finds an item and puts what the query asks for into `result`.
        internal var copy: @Sendable (_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus =
            SecItemCopyMatching
        /// `SecItemUpdate`: changes the items the query finds.
        internal var update: @Sendable (_ query: CFDictionary, _ changes: CFDictionary) -> OSStatus = SecItemUpdate
        /// `SecItemAdd`: adds a new item.
        internal var add: @Sendable (_ item: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus =
            SecItemAdd
        /// `SecItemDelete`: removes the items the query finds.
        internal var delete: @Sendable (_ query: CFDictionary) -> OSStatus = SecItemDelete
    }

    /// The service name every item of this store is kept under.
    private let service: String
    /// The Security calls made.
    private let calls: Calls

    /// A store in the login Keychain under `service`.
    public convenience init(service: String) {
        self.init(service: service, calls: Calls())
    }

    /// A store under `service` that makes `calls` in place of the Security framework's.
    internal init(service: String, calls: Calls) {
        self.service = service
        self.calls = calls
    }

    /// The query that names the item of `account`.
    private func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    /// The password of `account` read from the Keychain; nil when there is none or it is not UTF-8.
    ///
    /// May wait for the user to unlock the Keychain.
    public func password(for account: String) -> String? {
        var query = query(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard calls.copy(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(bytes: data, encoding: .utf8)
    }

    /// The stored password is changed in place.
    ///
    /// It is only removed when that is what was asked for: removed first and added again, a failing
    /// second step would lose it.
    public func setPassword(_ password: String?, for account: String) {
        guard let password else {
            _ = calls.delete(query(account) as CFDictionary)
            return
        }
        let data = Data(password.utf8)
        let status = calls.update(query(account) as CFDictionary, [kSecValueData: data] as CFDictionary)
        guard status == errSecItemNotFound else {
            return
        }
        var item = query(account)
        item[kSecValueData] = data
        item[kSecAttrLabel] = service
        _ = calls.add(item as CFDictionary, nil)
    }

    deinit {
        // Nothing to release.
    }
}
