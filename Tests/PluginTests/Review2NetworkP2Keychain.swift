import AFMKernel
import Foundation
import Security
import TestSupport
import Testing

@testable import NetworkPlugin

/// The order of the Keychain calls when a password is stored (N100), with the Security
/// framework's four calls replaced by a recording stand-in: no Keychain is touched.
@Suite
internal struct Review2NetworkP2Keychain {
    /// A Keychain that holds its items in memory and writes down what it was asked.
    ///
    /// Unchecked: the items and the log are guarded by `lock`; the statuses are set by the test
    /// between calls.
    private final class FakeKeychain: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Data] = [:]
        private(set) var log: [String] = []
        var addStatus: OSStatus = errSecSuccess
        var updateStatus: OSStatus?

        var calls: KeychainPasswords.Calls {
            var recording = KeychainPasswords.Calls()
            recording.copy = { [self] query, result in
                lock.lock()
                defer { lock.unlock() }
                log.append("copy \(account(query))")
                guard let data = items[account(query)] else {
                    return errSecItemNotFound
                }
                result?.pointee = data as CFData
                return errSecSuccess
            }
            recording.update = { [self] query, changes in
                lock.lock()
                defer { lock.unlock() }
                log.append("update \(account(query))")
                if let updateStatus {
                    return updateStatus
                }
                guard items[account(query)] != nil else {
                    return errSecItemNotFound
                }
                items[account(query)] = value(kSecValueData, in: changes) as? Data
                return errSecSuccess
            }
            recording.add = { [self] item, _ in
                lock.lock()
                defer { lock.unlock() }
                log.append("add \(account(item))")
                guard addStatus == errSecSuccess else {
                    return addStatus
                }
                guard items[account(item)] == nil else {
                    return errSecDuplicateItem
                }
                items[account(item)] = value(kSecValueData, in: item) as? Data
                return errSecSuccess
            }
            recording.delete = { [self] query in
                lock.lock()
                defer { lock.unlock() }
                log.append("delete \(account(query))")
                return items.removeValue(forKey: account(query)) == nil ? errSecItemNotFound : errSecSuccess
            }
            return recording
        }

        func clearLog() {
            lock.lock()
            log = []
            lock.unlock()
        }

        private func value(_ key: CFString, in dictionary: CFDictionary) -> Any? {
            (dictionary as? [String: Any])?[key as String]
        }

        private func account(_ query: CFDictionary) -> String {
            (value(kSecAttrAccount, in: query) as? String) ?? "?"
        }

        deinit {
            // Nothing to release.
        }
    }

    /// Storing a password updates the item that is there, adds one only when there is none, and never deletes.
    @Test
    internal func aStoredPasswordIsChangedInPlaceAndNeverRemovedFirst() {
        let keychain = FakeKeychain()
        let passwords = KeychainPasswords(service: "test", calls: keychain.calls)
        // Nothing there yet: looked for by the update, then added.
        passwords.setPassword("one", for: "a")
        #expect(keychain.log == ["update a", "add a"])
        #expect(passwords.password(for: "a") == "one")
        // There already: one update, no delete, no add.
        keychain.clearLog()
        passwords.setPassword("two", for: "a")
        #expect(keychain.log == ["update a"])
        #expect(passwords.password(for: "a") == "two")
        // Removed only when that is asked for.
        keychain.clearLog()
        passwords.setPassword(nil, for: "a")
        #expect(keychain.log == ["delete a"])
        #expect(passwords.password(for: "a") == nil)
    }

    /// A change the Keychain refuses leaves the old password, and nothing else is tried.
    @Test
    internal func aChangeThatFailsLeavesTheOldPasswordThere() {
        let keychain = FakeKeychain()
        let passwords = KeychainPasswords(service: "test", calls: keychain.calls)
        passwords.setPassword("kept", for: "a")
        // The Keychain refuses the change (locked, no permission): the old password stays, and
        // nothing is deleted or added in an attempt to get the new one in.
        keychain.updateStatus = errSecInteractionNotAllowed
        keychain.addStatus = errSecInteractionNotAllowed
        keychain.clearLog()
        passwords.setPassword("new", for: "a")
        #expect(keychain.log == ["update a"])
        keychain.updateStatus = nil
        #expect(passwords.password(for: "a") == "kept")
        // A password for an account that has none, when adding fails: nothing else is touched.
        keychain.clearLog()
        passwords.setPassword("x", for: "b")
        #expect(keychain.log == ["update b", "add b"])
        #expect(passwords.password(for: "b") == nil && passwords.password(for: "a") == "kept")
    }

    /// The vault writes a moved password's new item before it deletes the old one.
    @Test
    internal func theVaultMovesAPasswordWithoutLosingItOnTheWay() {
        let keychain = FakeKeychain()
        let store = KeychainPasswords(service: "test", calls: keychain.calls)
        let vault = PasswordVault(store: store)
        var connection = SavedConnection()
        (connection.name, connection.host, connection.user) = ("one", "a.example", "anna")
        vault.setConnections([connection])
        vault.setPassword("secret", for: connection)
        var moved = connection
        moved.host = "b.example"
        vault.setConnections([moved])
        vault.carryPassword(from: connection, to: moved, removing: true)
        vault.waitUntilDone()
        #expect(vault.password(for: moved.profile) == "secret")
        // The new item was written before the old one was deleted.
        let (old, new) = (PasswordVault.account(of: connection), PasswordVault.account(of: moved))
        let written = keychain.log.firstIndex(of: "add \(new)")
        let deleted = keychain.log.firstIndex(of: "delete \(old)")
        #expect(written != nil && deleted != nil)
        if let written, let deleted { #expect(written < deleted) }
        // The password is bound to the server and the login: nothing is left under the old host.
        #expect(store.password(for: old) == nil && store.password(for: new) == "secret")
    }
}
