import Foundation
import TestSupport
import Testing

@testable import AFMShell
@testable import ConfigurationPlugin

/// The keys the program stored in its macOS preferences, before it stored any: a domain that
/// does not exist yet lists nothing.
@MainActor
internal struct LastStoredKeysTests {
    /// A preferences store whose domain holds nothing lists no keys.
    @Test
    internal func aDomainWithNothingStoredListsNoKeys() throws {
        let suite = "afm-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let sandbox = try Sandbox()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettings(defaults: defaults, largeFolder: sandbox.url("large"))
        let unused = "afm-tests-unused-" + UUID().uuidString
        #expect(UserDefaults.standard.persistentDomain(forName: unused) == nil)
        #expect(ConfigurationPlugin.storedKeys(of: store, domain: unused).isEmpty)
    }
}
