import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Disconnecting, ejecting volumes, and the session options of the Net menu.
@MainActor
@Suite
internal struct CoverageNetworkDisconnecting {
    private let fixture: CoverageNetworkBench

    private var scripted: ScriptedInteraction { fixture.scripted }

    /// A fresh bench.
    internal init() throws {
        fixture = try CoverageNetworkBench()
    }

    /// With nothing connected, Disconnect does nothing.
    @Test
    internal func withNothingConnectedDisconnectDoesNothing() {
        #expect(!fixture.commands.perform(.ftpDisconnect))
        fixture.plugin.commands?.disconnect()
        #expect(scripted.log.isEmpty)
    }

    /// With two connections and neither panel on one, the user picks the one to close.
    @Test
    internal func theUserPicksTheConnectionToClose() throws {
        let second = try TestFTPServer(root: fixture.box.url("srv"), options: TestFTPServer.Options())
        let other = ServerKey(scheme: "ftp", host: "127.0.0.1", port: second.port)
        fixture.quickConnect("ftp://\(fixture.address)/pub")
        fixture.quickConnect("ftp://127.0.0.1:\(second.port)/")
        fixture.left.show(fixture.box.url("local"))
        // Cancelled: both stay.
        scripted.formAnswers = [.cancel]
        fixture.commands.perform(.ftpDisconnect)
        #expect(fixture.plugin.center.connected.count == 2)
        // The second, saved with its own port and the folder it was in.
        let rows = fixture.plugin.center.connected.map(\.key)
        let row = try #require(rows.firstIndex(of: other))
        scripted.formAnswers = [.values(["row": .index(row)]), .values(["name": .text("Second")])]
        scripted.choiceAnswers = [0]
        fixture.commands.perform(.ftpDisconnect)
        #expect(fixture.plugin.center.connected.map(\.key) == [fixture.key])
        let saved = try #require(fixture.plugin.connections.first { $0.name == "Second" })
        #expect(saved.port == second.port && saved.anonymous && saved.user.isEmpty)
    }

    /// The one connection is closed even when neither panel shows it.
    @Test
    internal func theOneConnectionIsClosedWhenNoPanelShowsIt() {
        fixture.quickConnect("ftp://\(fixture.address)/pub")
        fixture.left.show(fixture.box.url("local"))
        scripted.choiceAnswers = [1]
        fixture.commands.perform(.ftpDisconnect)
        #expect(fixture.plugin.center.connected.isEmpty)
        #expect(!scripted.log.contains("form: FTP Disconnect"))
    }

    /// A connection that listed nothing yet is saved without a remote folder.
    @Test
    internal func aConnectionThatListedNothingIsSavedWithoutAFolder() throws {
        let center = fixture.plugin.center
        center.announce(ConnectionProfile(key: fixture.key, user: "anna", password: "pw"), chosen: true)
        _ = try center.connect(fixture.key, cancellation: nil)
        scripted.choiceAnswers = [0]
        scripted.formAnswers = [.values(["name": .text("Fresh"), "savePassword": .flag(false)])]
        fixture.commands.perform(.ftpDisconnect)
        let saved = try #require(fixture.plugin.connections.first)
        #expect(saved.remoteDirectory.isEmpty && saved.user == "anna" && !saved.anonymous)
    }

    /// A quick connection may stay unsaved; a panel that never showed a local folder goes home.
    @Test
    internal func aQuickConnectionMayStayUnsaved() {
        fixture.bench.panelSet.source = fixture.right
        fixture.quickConnect("ftp://\(fixture.address)/pub")
        #expect(fixture.right.model.directory == fixture.url("/pub"))
        fixture.left.show(fixture.url("/"))
        scripted.choiceAnswers = [1]
        fixture.commands.perform(.ftpDisconnect)
        #expect(fixture.plugin.center.connected.isEmpty && fixture.plugin.connections.isEmpty)
        #expect(fixture.right.model.directory.standardizedFileURL == fixture.box.url("other").standardizedFileURL)
        #expect(
            fixture.left.model.directory == FileManager.default.homeDirectoryForCurrentUser,
            "\(fixture.left.model.directory) \(fixture.left.failures)"
        )
    }

    /// A panel that went to a local folder and then to the server returns to that folder.
    @Test
    internal func aPanelReturnsToTheLocalFolderItLastShowed() {
        fixture.quickConnect("ftp://\(fixture.address)/pub")
        let tree = fixture.box.url("local")
        fixture.right.show(tree)
        fixture.bench.kernel.panelEvents.post(.locationChanged, from: fixture.right)
        fixture.bench.kernel.panelEvents.post(.cursorMoved, from: fixture.right)
        fixture.right.show(fixture.url("/"))
        fixture.bench.kernel.panelEvents.post(.locationChanged, from: fixture.right)
        scripted.choiceAnswers = [1]
        fixture.commands.perform(.ftpDisconnect)
        #expect(fixture.right.model.directory.standardizedFileURL == tree.standardizedFileURL)
    }

    /// Ejecting a volume takes the panels out of it first; a failure is reported.
    @Test
    internal func ejectingAVolumeTakesThePanelsOutFirst() {
        let volume = URL(fileURLWithPath: "/Volumes/Macintosh HD", isDirectory: true)
        // Nothing to eject while the panel is on the startup disk.
        fixture.plugin.commands?.ejectVolume()
        #expect(fixture.mounter.ejected.isEmpty)
        fixture.left.show(volume)
        fixture.right.show(volume)
        #expect(fixture.commands.perform(.netDisconnect))
        #expect(fixture.mounter.ejected == [volume])
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(fixture.left.model.directory == home && fixture.right.model.directory == home)
        fixture.left.show(volume)
        fixture.mounter.failEjects(with: VolumeError(message: "Busy."))
        fixture.commands.perform(.netDisconnect)
        #expect(scripted.log.last == "inform: Macintosh HD cannot be ejected!")
    }

    /// Without the view options, Show Hidden Files switches the panel itself.
    @Test
    internal func hiddenFilesAreSwitchedWithoutTheViewOptions() throws {
        let bare = try CoverageNetworkBench(company: .navigationOnly, withMounter: false)
        bare.quickConnect("ftp://\(bare.address)/pub")
        let before = bare.left.model.showHidden
        #expect(bare.commands.perform(.ftpHiddenFiles))
        #expect(bare.left.model.showHidden != before)
    }

    /// A cancelled transfer-mode dialog changes nothing.
    @Test
    internal func aCancelledTransferModeDialogChangesNothing() {
        scripted.formAnswers = [.cancel]
        fixture.commands.perform(.ftpSelectTransferMode)
        #expect(fixture.settings.data(forKey: "network.transferMode") == nil)
    }
}
