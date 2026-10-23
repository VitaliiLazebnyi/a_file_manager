import AFMKernel
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import NetworkPlugin

/// The network plugin started without a password store of its own.
@MainActor
@Suite
internal struct CovNetPluginStart {
    /// A plugin that may not launch applications keeps its passwords in memory, and works without the Keychain.
    @Test
    internal func aPluginThatLaunchesNothingKeepsItsPasswordsInMemory() throws {
        let box = try Sandbox()
        let plugin = NetworkPlugin(launchesApplications: false)
        let bench = TestBench(
            plugins: [plugin],
            fileSystems: [LocalFileSystem()],
            left: try box.folder("local"),
            right: try box.folder("other")
        )
        defer { plugin.stop() }
        #expect(plugin.commands != nil && plugin.connections.isEmpty)
        #expect(bench.commands.perform(.ftpDisconnect) == false)
    }
}
