import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Connecting from the dialogs and the commands: saved connections, quick connections, Connect
/// to Server, and the answers that end them early.
@MainActor
@Suite
internal struct CoverageNetworkConnecting {
    private let fixture: CoverageNetworkBench

    private var scripted: ScriptedInteraction { fixture.scripted }

    /// A fresh bench.
    internal init() throws {
        fixture = try CoverageNetworkBench()
    }

    /// A port nothing listens on.
    private static func closedPort() throws -> Int {
        let listener = try TestFTPServer.listen()
        let port = TestFTPServer.port(of: listener)
        close(listener)
        return port
    }

    /// A saved connection opened from the right panel takes the left panel to its local folder.
    @Test
    internal func aSavedConnectionTakesTheOtherPanelToItsLocalFolder() {
        let details: [String: FormValues.Value] = [
            "name": .text("Work"), "host": .text(fixture.address), "anonymous": .flag(true),
            "local": .text(fixture.box.url("other").path), "remote": .text("/pub")
        ]
        scripted.formAnswers = [.values([:], button: 1), .values(details), .cancel]
        fixture.commands.perform(.ftpConnect)
        fixture.bench.panelSet.source = fixture.right
        fixture.commands.perform(.ftpOpen, .text("Work | */pub"))
        #expect(fixture.right.model.directory == fixture.url("/pub"))
        #expect(fixture.left.model.directory.standardizedFileURL == fixture.box.url("other").standardizedFileURL)
    }

    /// A name that no saved connection has is reported.
    @Test
    internal func anUnknownSavedConnectionIsReported() {
        fixture.commands.perform(.ftpOpen, .text("Nowhere"))
        #expect(fixture.scripted.log.last == "inform: There is no saved connection named Nowhere.")
    }

    /// A recent address is picked from the history, and a cancelled dialog connects nowhere.
    @Test
    internal func aRecentAddressIsPickedFromTheHistory() {
        fixture.quickConnect("ftp://\(fixture.address)/pub")
        fixture.quickConnect("ftp://\(fixture.address)/")
        fixture.commands.perform(.ftpDisconnect)
        // The second entry of the list is the older address.
        scripted.formAnswers = [.values(["recent": .index(2), "anonymous": .flag(true)])]
        fixture.commands.perform(.ftpNew)
        #expect(fixture.left.model.directory == fixture.url("/pub"))
        let commands = fixture.server.commands.count
        scripted.formAnswers = [.cancel]
        fixture.commands.perform(.ftpNew)
        #expect(fixture.server.commands.count == commands)
    }

    /// An SFTP address without a user logs in as the user of this Mac.
    @Test
    internal func anSFTPAddressWithoutAUserLogsInAsTheUserOfThisMac() throws {
        let port = try Self.closedPort()
        fixture.quickConnect("sftp://127.0.0.1:\(port)")
        #expect(scripted.log.last == "inform: Connect failed!")
        fixture.commands.perform(.netConnect, .text("sftp://127.0.0.1:\(port)/some/where"))
        #expect(scripted.log.last == "inform: Connect failed!")
        #expect(fixture.plugin.center.connected.isEmpty)
    }

    /// Connect to Server: a cancelled prompt does nothing, an FTP address with a path opens it.
    @Test
    internal func connectToServerOpensFTPAddressesWithTheirPath() {
        scripted.promptAnswers = [.cancel]
        fixture.commands.perform(.netConnect)
        #expect(fixture.mounter.mounted.isEmpty)
        fixture.commands.perform(.netConnect, .text("ftp://\(fixture.address)/pub"))
        #expect(fixture.left.model.directory == fixture.url("/pub"))
        fixture.commands.perform(.netConnect, .text("ftp://\(fixture.address)"))
        #expect(fixture.left.model.directory == fixture.url("/"))
    }

    /// A mount that was cancelled is not reported, one that went well is shown.
    @Test
    internal func aCancelledMountIsNotReported() {
        fixture.mounter.mountAt([fixture.box.url("other")])
        fixture.commands.perform(.netConnect, .text("smb://nas.invalid/share"))
        #expect(fixture.left.model.directory.standardizedFileURL == fixture.box.url("other").standardizedFileURL)
        fixture.mounter.failMounts(with: NetworkError.cancelled)
        let log = scripted.log
        fixture.commands.perform(.netConnect, .text("smb://nas.invalid/share"))
        #expect(scripted.log == log)
    }

    /// Without a mounter the address is remembered, and nothing is mounted.
    @Test
    internal func withoutAMounterTheAddressIsOnlyRemembered() throws {
        let bare = try CoverageNetworkBench(company: .all, withMounter: false)
        bare.commands.perform(.netConnect, .text("smb://anna:pw@nas.invalid/share"))
        #expect(bare.settings.text("network.lastServerAddress", default: "") == "smb://anna@nas.invalid/share")
        #expect(bare.scripted.log.isEmpty)
    }
}
