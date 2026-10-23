import AFMKernel
import Foundation
import NetworkPlugin
import TestSupport

/// A suite that drives the network plugin through its commands on a `NetworkCommandFixture`.
@MainActor
internal protocol NetworkCommandSuite {
    /// The bench, the server and the plugin of the test.
    var fixture: NetworkCommandFixture { get }
}

/// The fixture's parts under short names, and the steps the tests share.
extension NetworkCommandSuite {
    /// The sandbox of the fixture.
    internal var box: Sandbox { fixture.box }
    /// The FTP server of the fixture.
    internal var server: TestFTPServer { fixture.server }
    /// The password store of the plugin.
    internal var passwords: MemoryPasswords { fixture.passwords }
    /// The settings, which remember everything ever stored in them.
    internal var settings: RecordingSettings { fixture.settings }
    /// The fake volume mounting.
    internal var mounter: FakeMounter { fixture.mounter }
    /// The plugin under test.
    internal var plugin: NetworkPlugin { fixture.plugin }
    /// The kernel, the panels and the dialogs.
    internal var bench: TestBench { fixture.bench }
    /// The commands of every plugin on the bench.
    internal var commands: CommandRegistry { bench.commands }
    /// The left panel, the source unless a test says otherwise.
    internal var left: FakePanel { bench.left }
    /// The right panel.
    internal var right: FakePanel { bench.right }
    /// The scripted dialogs: their answers, and a log of what was shown.
    internal var dialogs: ScriptedInteraction { bench.interaction }
    /// The test server's key.
    internal var key: ServerKey { ServerKey(scheme: "ftp", host: "127.0.0.1", port: server.port) }
    /// The test server's address as the user types it.
    internal var address: String { "127.0.0.1:\(server.port)" }
    /// The folder of the right panel as a copy target.
    internal var localTarget: String { box.url("other").absoluteString + "/" }

    /// The location of a path on the test server.
    internal func url(_ path: String) -> URL {
        key.url(path: path)
    }

    /// Ctrl+N with the test server's address, anonymously.
    internal func quickConnect() {
        quickConnect(address)
    }

    /// Ctrl+N with the address given, anonymously.
    internal func quickConnect(_ text: String) {
        dialogs.formAnswers = [.values(["address": .text(text), "anonymous": .flag(true)])]
        commands.perform(.ftpNew)
    }
}
