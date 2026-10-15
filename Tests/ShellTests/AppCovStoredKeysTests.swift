import Foundation
import TestSupport
import Testing

@testable import AFMShell
@testable import ConfigurationPlugin

/// The configuration dialog lists the keys the program stored in its macOS preferences; only the
/// real preferences store has such a list (`ConfigurationPlugin.storedKeys(of:)`).
@MainActor
@Suite(.serialized)
internal struct AppCovStoredKeysTests {
    /// The preferences store lists the program's own values, the ones it stored as JSON; any
    /// other store lists nothing.
    @Test
    internal func thePreferencesListTheProgramsOwnValues() throws {
        let suite = "afm-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let sandbox = try Sandbox()
        let store = UserDefaultsSettings(defaults: defaults, largeFolder: sandbox.url("large"))
        // The list is read from the program's own domain: a value of the program and one of
        // somebody else's, each under a name of this test's, taken away again afterwards.
        let standard = UserDefaults.standard
        let own = "afm-tests-own-" + UUID().uuidString
        let foreign = "afm-tests-foreign-" + UUID().uuidString
        standard.set(Data("{\"a\":1}".utf8), forKey: own)
        standard.set("not JSON data", forKey: foreign)
        defer {
            standard.removeObject(forKey: own)
            standard.removeObject(forKey: foreign)
            defaults.removePersistentDomain(forName: suite)
        }
        let keys = ConfigurationPlugin.storedKeys(of: store)
        #expect(keys.contains(own) && !keys.contains(foreign) && keys == keys.sorted())
        #expect(ConfigurationPlugin.storedKeys(of: MemorySettings()).isEmpty)
    }
}
