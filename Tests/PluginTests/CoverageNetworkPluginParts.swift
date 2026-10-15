import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import NetworkPlugin

/// The plugin as the program starts it, its settings, the defaults of what connections ask,
/// and the Keychain.
@MainActor
@Suite
internal struct CoverageNetworkPluginParts {
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

    /// As the program starts it, the plugin keeps passwords in the Keychain and can eject volumes.
    @Test
    internal func theProgramsPluginUsesTheKeychainAndTheSystem() throws {
        let box = try Sandbox()
        let plugin = NetworkPlugin()
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
        // Without saved connections nothing is stored at the start.
        #expect(KeychainPasswords(service: "Test network").password(for: PasswordVault.boundAccount) == nil)
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
        let keychain = KeychainPasswords(service: "local.a-file-manager.tests.\(UUID().uuidString)")
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
