import AFMKernel
import FileOperationsPlugin
import Foundation
import LocalFileSystemPlugin
import NavigationPlugin
import TestSupport
import ViewOptionsPlugin

@testable import NetworkPlugin

/// A test FTP server, the Network plugin with passwords in memory, and the panels of a test bench.
///
/// The server serves `srv` (`pub/report.txt`, `readme.txt`); the left panel starts in `local`
/// (`up.txt`), the right one in `other`. Mounting always fails.
@MainActor
internal final class Review2NetworkCommandFixture {
    /// The folders on disk.
    internal let box: Sandbox
    /// The FTP server the commands connect to.
    internal let server: TestFTPServer
    /// The passwords the plugin keeps, in memory.
    internal let passwords = MemoryPasswords()
    /// The settings of the test bench.
    internal let settings = MemorySettings()
    /// The plugin under test.
    internal let plugin: NetworkPlugin
    /// The kernel, the panels and the scripted user.
    internal let bench: TestBench

    /// The commands of the test bench.
    internal var commands: CommandRegistry { bench.commands }
    /// The left panel, where connections open.
    internal var left: FakePanel { bench.left }
    /// The user, as the test scripts them.
    internal var interaction: ScriptedInteraction { bench.interaction }
    /// The test server's key.
    internal var key: ServerKey { ServerKey(scheme: "ftp", host: "127.0.0.1", port: server.port) }
    /// The test server's host and port, for addresses.
    internal var address: String { "127.0.0.1:\(server.port)" }

    /// Starts the server and the bench, with keep-alive off and no question about saving.
    internal init() throws {
        box = try Sandbox()
        try box.file("srv/pub/report.txt", "report")
        try box.file("srv/readme.txt", "read me")
        try box.file("local/up.txt", "upload")
        try box.folder("other")
        server = try TestFTPServer(root: box.url("srv"), options: TestFTPServer.Options())
        settings.set("0", forKey: "network.keepAliveSeconds")
        plugin = NetworkPlugin(launchesApplications: false, passwords: passwords, mounter: RefusingMounter())
        bench = TestBench(
            plugins: [plugin, NavigationPlugin(), FileOperationsPlugin(), ViewOptionsPlugin()],
            fileSystems: [LocalFileSystem()],
            left: box.url("local"),
            right: box.url("other"),
            settings: settings
        )
        plugin.center.environment.declineMemory = 0
    }

    /// The address of `path` on the test server.
    internal func url(_ path: String) -> URL { key.url(path: path) }

    /// Connects the left panel to `text` with Quick connect, anonymously.
    internal func quickConnect(_ text: String) {
        interaction.formAnswers = [.values(["address": .text(text), "anonymous": .flag(true)])]
        commands.perform(.ftpNew)
    }

    /// Writes `lines` to a download list and runs it, the questions answered with `answers`.
    internal func runList(_ lines: [String], answers: [Int]) throws {
        let list = try box.file("list.txt", lines.joined(separator: "\n") + "\n")
        interaction.promptAnswers = [.text(list.path)]
        interaction.choiceAnswers = answers
        commands.perform(.ftpDownloadList)
    }

    deinit {
        // Nothing to release: the server stops and the sandbox removes its folders when they go.
    }
}
