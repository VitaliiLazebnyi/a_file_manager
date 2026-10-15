import AFMKernel
import Foundation
import TestSupport
import Testing

/// The settings store kept in memory, and its scopes.
@Suite
internal struct MemorySettingsTests {
    /// Values come back as they were stored; a scope prefixes its keys and sees only its own.
    @Test
    internal func settingsValuesAndScopes() {
        let settings = MemorySettings()
        #expect(settings.value([String].self, forKey: "list") == nil)
        settings.set(["a", "b"], forKey: "list")
        #expect(settings.value([String].self, forKey: "list") == ["a", "b"])
        let viewer = settings.scoped(to: "viewer")
        let search = settings.scoped(to: "search")
        viewer.set(12, forKey: "fontSize")
        #expect(viewer.value(Int.self, forKey: "fontSize") == 12)
        #expect(search.value(Int.self, forKey: "fontSize") == nil)
        #expect(settings.value(Int.self, forKey: "viewer.fontSize") == 12)
    }

    /// Bytes come back as they were stored, and a list of names as a list of names.
    @Test
    internal func rawDataIsStoredAsItIs() {
        let settings = MemorySettings()
        let data = Data([1, 2, 3])
        settings.set(data, forKey: "raw")
        #expect(settings.data(forKey: "raw") == data)
        settings.set(["a"], forKey: "list")
        #expect(settings.value([String].self, forKey: "list") == ["a"])
    }
}
