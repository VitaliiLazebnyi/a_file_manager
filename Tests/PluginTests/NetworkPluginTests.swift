import AFMContracts
import AFMKernel
import Foundation
import NetworkPlugin
import TestSupport
import Testing

/// The network plugin driven through its commands: what it registers, its options and the network volumes.
@MainActor
@Suite
internal struct NetworkPluginTests: NetworkCommandSuite {
    /// The bench, the server and the plugin of the test.
    internal let fixture: NetworkCommandFixture

    /// A fresh fixture for every test.
    internal init() throws {
        fixture = try NetworkCommandFixture()
    }

    /// The plugin registers its menu, commands, shortcuts, file systems, toolbar buttons and
    /// preference page, and with nothing connected the commands that need a connection are off.
    @Test
    internal func registersCommandsMenusAndFileSystems() throws {
        let net = try #require(bench.kernel.menus.menus.first { $0.title == "Net" })
        #expect(
            net.items == [
                .ftpConnect, .ftpNew, .ftpDisconnect, .ftpHiddenFiles, nil,
                .ftpSelectTransferMode, .ftpAddToList, .ftpDownloadList, nil, .netConnect, .netDisconnect
            ]
        )
        #expect(net.items.compactMap(\.self).allSatisfy { commands[$0] != nil })
        #expect(bench.kernel.keyClashes.isEmpty)
        #expect(commands[.ftpConnect]?.defaultShortcuts == [Shortcut(.character("f"), .control)])
        #expect(commands[.ftpNew]?.defaultShortcuts == [Shortcut(.character("n"), .control)])
        #expect(commands[.ftpDisconnect]?.defaultShortcuts == [Shortcut(.character("f"), [.control, .shift])])
        #expect(bench.kernel.fileSystems.all.map(\.scheme).filter { $0 != "file" } == ["ftp", "ftps", "sftp"])
        let ours: [CommandID] = [.ftpConnect, .ftpNew, .ftpDisconnect, .netConnect]
        #expect(bench.kernel.toolbar.defaultLayout.compactMap { $0?.command }.filter(ours.contains) == ours)
        #expect(bench.kernel.preferences.pages.map(\.title).contains("FTP and Network"))
        // Nothing is connected: nothing to disconnect, no server among the volumes, no eject on the startup disk.
        #expect(
            !commands.isEnabled(.ftpDisconnect) && !commands.isEnabled(.ftpHiddenFiles)
                && !commands.isEnabled(.netDisconnect)
        )
        #expect(!bench.kernel.fileSystems.all.flatMap { $0.places() }.contains { !$0.url.isFileURL })
    }

    /// Hidden files show when switched on, the transfer mode is chosen in a dialog, and the preference
    /// page reads the same settings.
    @Test
    internal func hiddenFilesAndTransferMode() throws {
        try box.file("srv/.secret", "s")
        quickConnect()
        #expect(left.names == ["pub", "readme.txt"] && !commands.isChecked(.ftpHiddenFiles))
        commands.perform(.ftpHiddenFiles)
        #expect(left.names == ["pub", ".secret", "readme.txt"] && commands.isChecked(.ftpHiddenFiles))

        #expect(plugin.center.environment.options.values.transferMode == .binary)
        dialogs.formAnswers = [.values(["mode": .index(1)])]
        commands.perform(.ftpSelectTransferMode)
        #expect(plugin.center.environment.options.values.transferMode == .text)
        // The preference page reads the same settings.
        let page = try #require(bench.kernel.preferences.pages.first)
        settings.set(false, forKey: "network.passiveMode")
        settings.set(5, forKey: "network.parallelConnections")
        settings.set("15", forKey: "network.timeoutSeconds")
        page.onChange()
        let values = plugin.center.environment.options.values
        #expect(
            !values.passiveByDefault && values.parallelConnections == 8 && values.timeout == 15
                && values.transferMode == .text
        )
    }

    /// Connect to Server mounts other kinds of servers as volumes and opens the plugin's own kinds
    /// itself; unknown schemes and failed mounts are reported.
    @Test
    internal func connectToServerMountsAndEjects() throws {
        let volume = try box.folder("Volumes/Share")
        mounter.mountPoint = volume
        dialogs.promptAnswers = [.text("smb://nas.local/Share")]
        commands.perform(.netConnect)
        #expect(mounter.mounted.map(\.absoluteString) == ["smb://nas.local/Share"])
        #expect(left.model.directory == volume && dialogs.log.contains("prompt: Connect to Server [smb://]"))
        // An address of this program's own kind opens a connection instead.
        commands.perform(.netConnect, .text("ftp://\(address)/pub"))
        #expect(left.model.directory == url("/pub") && mounter.mounted.count == 1)
        commands.perform(.netConnect, .text("gopher://old"))
        #expect(dialogs.log.last == "inform: gopher://old is not the address of a server.")
        mounter.failure = VolumeError(message: "No route")
        commands.perform(.netConnect, .text("afp://nas.local/x"))
        #expect(dialogs.log.last == "inform: Connect failed!")
        // Eject is offered for folders on a mounted volume only; the sandbox is not one.
        #expect(!commands.isEnabled(.netDisconnect) && mounter.ejected.isEmpty)
    }
}
