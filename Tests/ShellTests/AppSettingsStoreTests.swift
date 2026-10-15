import Foundation
import TestSupport
import Testing

@testable import AFMShell

/// The settings kept in the macOS preferences: where the large values go, and what happens
/// when they cannot be written.
@Suite
internal struct AppSettingsStoreTests {
    /// The standard preferences keep their large values in the program's folder in Application
    /// Support; any other store with the rest.
    @Test
    internal func theStandardPreferencesKeepLargeValuesInTheProgramsFolder() throws {
        let standard = UserDefaultsSettings()
        let folder = try #require(standard.largeFolder)
        #expect(folder.lastPathComponent == "Settings")
        #expect(
            folder.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Application Support"
        )
        let suite = "afm-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(UserDefaultsSettings(defaults: defaults).largeFolder == nil)
    }

    /// A program without a bundle identifier keeps its large values under its process's name.
    @Test
    internal func aProgramWithoutABundleIdentifierIsNamedByItsProcess() throws {
        let sandbox = try Sandbox()
        let plain = try #require(Bundle(url: try sandbox.folder("Plain")))
        #expect(plain.bundleIdentifier == nil)
        let folder = try #require(UserDefaultsSettings.standardLargeFolder(of: plain))
        #expect(folder.deletingLastPathComponent().lastPathComponent == ProcessInfo.processInfo.processName)
    }

    /// A large value whose file cannot be written stays in memory for this run; waiting for it ends.
    @Test
    internal func aLargeValueThatCannotBeWrittenStaysInMemory() throws {
        let sandbox = try Sandbox()
        // A file where the folder should be: nothing can be made inside it.
        let blocked = try sandbox.file("blocked").appendingPathComponent("Settings", isDirectory: true)
        let suite = "afm-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettings(defaults: defaults, largeFolder: blocked)
        store.setLarge(Data("kept".utf8), forKey: "history")
        #expect(store.waitForWrites(atMost: 60))
        #expect(store.largeData(forKey: "history") == Data("kept".utf8))
        #expect(!sandbox.exists("blocked/Settings"))
        // Asked again, the value is the one in memory.
        #expect(store.largeData(forKey: "history") == Data("kept".utf8))
    }
}
