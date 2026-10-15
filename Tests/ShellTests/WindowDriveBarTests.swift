import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The drive buttons below the button bar, and the drive a folder is on.
@MainActor
@Suite(.serialized)
internal struct WindowDriveBarTests {
    /// The window's folders and stand-ins.
    private let fixture: AppFixture
    /// The plugin that brings the test's buttons and commands.
    private let extra = WindowTestPlugin()

    /// A sandbox with the window's files.
    internal init() throws {
        fixture = try AppFixture(files: AppFixture.windowFiles)
    }

    /// The drive buttons are off until switched on, then show every place; a press goes there.
    @Test
    internal func theDriveButtonsAreHiddenUntilSwitchedOnAndShowPlaces() async {
        let app = await fixture.startWindow(with: extra)
        defer { app.stop() }
        let bar = app.window.driveBar
        #expect(bar.isHidden && !app.commands.isChecked(.showDriveButtons))
        app.commands.perform(.showDriveButtons)
        #expect(!bar.isHidden && app.commands.isChecked(.showDriveButtons))
        // The places are asked for in the background; the bar follows when they are there. (A
        // volume the file system finds a moment later is announced, and the bar follows again.)
        let places = { app.kernel.fileSystems.all.flatMap { $0.places() }.map(\.name) }
        #expect(await AppWait.until { bar.places.map(\.name) == places() })
        #expect(bar.buttons.count == bar.places.count && bar.buttons.first?.title == "Home")
        // A press shows the place in the source panel. (A stand-in place: the user's own
        // folders are none of a test's business.)
        bar.show(Place(name: "B", url: fixture.box.url("B"), kind: .folder), inNewTab: false)
        await app.settle()
        #expect(app.left.model.directory.lastPathComponent == "B")
    }

    /// The place of a folder is the one with the longest path that holds it, on the same server.
    @Test
    internal func thePlaceOfAFolderIsTheOneWithTheLongestPath() throws {
        let places = [
            Place(name: "Disk", url: URL(fileURLWithPath: "/"), kind: .internalDisk),
            Place(name: "Home", url: URL(fileURLWithPath: "/Users/me"), kind: .home),
            Place(name: "Stick", url: URL(fileURLWithPath: "/Volumes/Stick"), kind: .externalDisk)
        ]
        #expect(DriveBarView.currentPlace(among: places, for: URL(fileURLWithPath: "/Users/me/Documents")) == 1)
        #expect(DriveBarView.currentPlace(among: places, for: URL(fileURLWithPath: "/Users/merle")) == 0)
        #expect(DriveBarView.currentPlace(among: places, for: URL(fileURLWithPath: "/Volumes/Stick")) == 2)
        let elsewhere = try #require(URL(string: "mem://host/Users/me"))
        #expect(DriveBarView.currentPlace(among: places, for: elsewhere) == nil)
    }

    /// The path bar of a panel offers to eject the drive it is on.
    @Test
    internal func thePathBarOffersToEjectTheDriveItIsOn() {
        let bar = PathBarView(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        bar.update(text: "/Volumes/STICK/photos/*.*", segments: [])
        #expect(bar.ejectButton.isHidden)
        var ejected = 0
        bar.onEject = { ejected += 1 }
        bar.ejectableVolumeName = "STICK"
        bar.layout()
        #expect(
            !bar.ejectButton.isHidden && bar.ejectButton.toolTip == "Eject “STICK”" && bar.ejectButton.frame.maxX == 300
        )
        Controls.send(bar.ejectButton)
        #expect(ejected == 1)
        bar.ejectableVolumeName = nil
        #expect(bar.ejectButton.isHidden)
    }
}
