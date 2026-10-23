import AFMContracts
import AFMKernel
import FileOperationsPlugin
import Foundation
import LocalFileSystemPlugin
import NavigationPlugin
import NetworkPlugin
import TestSupport
import ViewOptionsPlugin

/// The network plugin with the navigation, file operation and view plugins in a test bench, the test FTP server
/// on a sandbox, and settings, passwords and volumes that the tests can look into.
///
/// The left panel starts in the sandbox's `local` folder, the right one in `other`; the server serves `srv`.
@MainActor
internal struct NetworkCommandFixture {
    /// The sandbox with the server's files, the local files and the copy target.
    internal let box: Sandbox
    /// The FTP server the commands connect to.
    internal let server: TestFTPServer
    /// The password store the plugin keeps its passwords in.
    internal let passwords = MemoryPasswords()
    /// The settings, which remember everything ever stored in them.
    internal let settings = RecordingSettings()
    /// The system's volume mounting, as the plugin sees it.
    internal let mounter = FakeMounter()
    /// The plugin under test.
    internal let plugin: NetworkPlugin
    /// The kernel, the panels and the dialogs.
    internal let bench: TestBench

    /// Fills the sandbox, starts the server and the bench, with no keep-alive and a long timeout.
    internal init() throws {
        box = try Sandbox()
        try box.file("srv/pub/report.txt", "report")
        try box.file("srv/pub/sub/deep.txt", "deep")
        try box.file("srv/readme.txt", "read me")
        try box.file("local/up.txt", "upload")
        try box.file("local/tree/a.txt", "a")
        try box.file("local/tree/inner/b.txt", "bb")
        try box.folder("other")
        server = try TestFTPServer(root: box.url("srv"), options: TestFTPServer.Options())
        settings.set("0", forKey: "network.keepAliveSeconds")
        // The longest the plugin waits for an answer: the test server answers at once, but on a
        // machine busy with other tests its thread may be long in getting to it.
        settings.set("600", forKey: "network.timeoutSeconds")
        plugin = NetworkPlugin(launchesApplications: false, passwords: passwords, mounter: mounter)
        bench = TestBench(
            plugins: [plugin, NavigationPlugin(), FileOperationsPlugin(), ViewOptionsPlugin()],
            fileSystems: [LocalFileSystem()],
            left: box.url("local"),
            right: box.url("other"),
            settings: settings
        )
        plugin.center.environment.declineMemory = 0
    }
}
