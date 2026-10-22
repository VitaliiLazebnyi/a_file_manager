import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing
import os

@testable import NetworkPlugin

/// The plugin as the program starts it, its settings, the defaults of what connections ask,
/// and the Keychain (with the Security framework's calls replaced: no test touches the real one).
@MainActor
@Suite
internal struct CoverageNetworkPluginParts {
    /// The Security framework's calls on items kept in memory, by account.
    private static func keychainInMemory() -> KeychainPasswords.Calls {
        let items = OSAllocatedUnfairLock(initialState: [String: Data]())
        @Sendable
        func account(_ query: CFDictionary) -> String {
            ((query as? [String: Any])?[kSecAttrAccount as String] as? String) ?? ""
        }
        var calls = KeychainPasswords.Calls()
        calls.copy = { query, result in
            let key = account(query)
            guard let data = items.withLock({ $0[key] }) else {
                return errSecItemNotFound
            }
            result?.pointee = data as CFData
            return errSecSuccess
        }
        calls.update = { query, changes in
            let (key, data) = (account(query), (changes as? [String: Any])?[kSecValueData as String] as? Data)
            return items.withLock { stored in
                guard stored[key] != nil else {
                    return errSecItemNotFound
                }
                stored[key] = data
                return errSecSuccess
            }
        }
        calls.add = { item, _ in
            let (key, data) = (account(item), (item as? [String: Any])?[kSecValueData as String] as? Data)
            items.withLock { $0[key] = data }
            return errSecSuccess
        }
        calls.delete = { query in
            let key = account(query)
            return items.withLock { $0.removeValue(forKey: key) } == nil ? errSecItemNotFound : errSecSuccess
        }
        return calls
    }

    /// Settings that are no numbers or out of range fall back to the defaults.
    @Test
    internal func oddSettingsFallBackToTheDefaults() {
        let settings = MemorySettings()
        settings.set("soon", forKey: "network.keepAliveSeconds")
        settings.set("never", forKey: "network.timeoutSeconds")
        settings.set(9, forKey: "network.transferMode")
        settings.set(99, forKey: "network.parallelConnections")
        let values = NetworkSettings.values(from: settings)
        #expect(values.keepAliveInterval == 60 && values.timeout == 30)
        #expect(values.transferMode == .binary && values.parallelConnections == 3)
        settings.set(5, forKey: "network.parallelConnections")
        #expect(NetworkSettings.values(from: settings).parallelConnections == 8)
    }

    /// As the program starts it, the plugin can eject volumes through the system.
    ///
    /// (The store of passwords is given: the program's own is the login Keychain, which no test
    /// touches.).
    @Test
    internal func theProgramsPluginCanEjectThroughTheSystem() throws {
        let box = try Sandbox()
        let plugin = NetworkPlugin(passwords: MemoryPasswords())
        #expect(plugin.connections.isEmpty)
        let bench = TestBench(
            plugins: [plugin],
            fileSystems: [LocalFileSystem()],
            left: box.url(""),
            right: box.url(""),
            settings: MemorySettings()
        )
        plugin.waitForStoredSecrets()
        #expect(plugin.commands?.canEject == true)
        // Sessions for each scheme of the plugin, none for others.
        let make = plugin.center.makeSession
        let environment = plugin.center.environment
        #expect(make(ConnectionProfile(key: ServerKey(scheme: "sftp", host: "a.invalid")), environment) is SFTPSession)
        #expect(make(ConnectionProfile(key: ServerKey(scheme: "http", host: "a.invalid")), environment) == nil)
        // Open Saved Connection without a name shows the list.
        bench.commands.perform(.ftpOpen)
        #expect(bench.interaction.log == ["form: Connect to FTP server"])
        plugin.stop()
    }

    /// A password is kept in the Keychain, changed in place, and removed.
    @Test
    internal func aPasswordIsKeptInTheKeychain() {
        let keychain = KeychainPasswords(service: "tests", calls: Self.keychainInMemory())
        keychain.setPassword("first", for: "anna")
        keychain.setPassword("second", for: "anna")
        #expect(keychain.password(for: "anna") == "second")
        keychain.setPassword(nil, for: "anna")
        #expect(keychain.password(for: "anna") == nil)
    }

    /// Without a dialog, a connection gets no answers: no password, no trust, no secret.
    @Test
    internal func withoutADialogAConnectionGetsNoAnswers() {
        let environment = SessionEnvironment()
        let profile = ConnectionProfile(key: ServerKey(scheme: "ftps", host: "a.invalid", port: 990))
        let certificate = CertificateInfo(fingerprint: "AA", subject: "a", problem: "unknown")
        #expect(profile.tls == .implicit)
        #expect(environment.askCredentials(profile, "") == nil)
        #expect(!environment.askToTrust(profile, certificate))
        #expect(!environment.askToTrustChanged(profile, certificate, ["BB"]))
        #expect(environment.askToSendPasswordUnprotected(profile))
        #expect(environment.askSecret(profile, "Passphrase:", true) == nil)
        environment.rememberPassword(profile, "pw")
        let lines = Signal<String>()
        environment.log = { line in lines.set(line) }
        environment.log("hello")
        #expect(lines.wait() == "hello")
    }

    /// A lock held elsewhere is not waited for on the main thread, and a wait elsewhere ends
    /// when the caller gives up.
    @Test
    internal func aHeldLockIsNotWaitedForOnTheMainThread() {
        let lock = NSLock()
        lock.lock()
        defer { lock.unlock() }
        #expect(throws: NetworkError.self) {
            try lockPatiently(lock, cancellation: nil) { nil }
        }
        let ended = Signal<Bool>()
        Thread.detachNewThread {
            do {
                try lockPatiently(lock, cancellation: nil) { NetworkError.notConnected("a.invalid") }
                ended.set(false)
            } catch {
                ended.set(true)
            }
        }
        #expect(ended.wait() == true)
    }
}
