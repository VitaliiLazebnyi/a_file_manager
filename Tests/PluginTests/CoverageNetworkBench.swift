import AFMContracts
import AFMKernel
import FileOperationsPlugin
import Foundation
import LocalFileSystemPlugin
import NavigationPlugin
import TestSupport
import ViewOptionsPlugin

@testable import NetworkPlugin

/// The network plugin in a kernel with fake panels, next to a test FTP server on a sandbox:
/// `srv` is served, `local` and `other` are shown in the panels.
@MainActor
internal final class CoverageNetworkBench {
    /// The other plugins of the kernel.
    internal enum Company {
        /// Navigation, file operations and view options.
        case all
        /// Navigation only: no copy service, no Hidden Files command.
        case navigationOnly
    }

    /// The sandbox.
    internal let box: Sandbox
    /// The FTP server on `srv`.
    internal let server: TestFTPServer
    /// The password store of the plugin.
    internal let passwords = MemoryPasswords()
    /// The settings of the kernel.
    internal let settings = MemorySettings()
    /// The mounter of the plugin.
    internal let mounter = CoverageNetworkMounter()
    /// The plugin.
    internal let plugin: NetworkPlugin
    /// The kernel and the panels.
    internal let bench: TestBench

    /// The kernel's commands.
    internal var commands: CommandRegistry { bench.commands }
    /// The left panel.
    internal var left: FakePanel { bench.left }
    /// The right panel.
    internal var right: FakePanel { bench.right }
    /// The scripted user.
    internal var scripted: ScriptedInteraction { bench.interaction }
    /// What the connections ask through.
    internal var environment: SessionEnvironment { plugin.center.environment }
    /// The key of the test server.
    internal var key: ServerKey { ServerKey(scheme: "ftp", host: "127.0.0.1", port: server.port) }
    /// The test server as an address.
    internal var address: String { "127.0.0.1:\(server.port)" }

    /// A bench with every plugin and the recording mounter.
    internal convenience init() throws {
        try self.init(company: .all, withMounter: true)
    }

    /// A bench with the plugins of `company`, with or without a mounter.
    internal init(company: Company, withMounter: Bool) throws {
        box = try Sandbox()
        try box.file("srv/pub/report.txt", "report")
        try box.file("srv/readme.txt", "read me")
        try box.file("local/up.txt", "upload")
        try box.folder("other")
        server = try TestFTPServer(root: box.url("srv"))
        settings.set("0", forKey: "network.keepAliveSeconds")
        // The longest the plugin waits for an answer: the test server answers at once, but on a
        // machine busy with other tests its thread may be long in getting to it.
        settings.set("600", forKey: "network.timeoutSeconds")
        plugin = NetworkPlugin(
            launchesApplications: false,
            passwords: passwords,
            mounter: withMounter ? mounter : nil
        )
        let others: [any Plugin] =
            company == .all ? [NavigationPlugin(), FileOperationsPlugin(), ViewOptionsPlugin()] : [NavigationPlugin()]
        bench = TestBench(
            plugins: [plugin] + others,
            fileSystems: [LocalFileSystem()],
            left: box.url("local"),
            right: box.url("other"),
            settings: settings
        )
        plugin.center.environment.declineMemory = 0
    }

    /// A location on the test server.
    internal func url(_ path: String) -> URL {
        key.url(path: path)
    }

    /// Connects through Ctrl+N, anonymously.
    internal func quickConnect(_ text: String) {
        scripted.formAnswers = [.values(["address": .text(text), "anonymous": .flag(true)])]
        commands.perform(.ftpNew)
    }

    /// Writes `lines` into a list file and runs it, answering the questions with `answers`.
    internal func runList(_ lines: [String], answers: [Int]) throws {
        let list = try box.file("list.txt", lines.joined(separator: "\n") + "\n")
        scripted.promptAnswers = [.text(list.path)]
        scripted.choiceAnswers = answers
        commands.perform(.ftpDownloadList)
    }

    /// Lets the main queue run what was put on it before, until `condition` holds.
    internal func settle(until condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(Wait.ceiling)
        while !condition() {
            if Date() > end {
                return false
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        return true
    }

    deinit {
        // Nothing to release.
    }
}
