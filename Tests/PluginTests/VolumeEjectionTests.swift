import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import SystemToolsPlugin

/// Ejecting a drive: the panels leave it for where they came from, the program lets go of it,
/// and a refusal brings the panels back.
@MainActor
@Suite
internal struct VolumeEjectionTests {
    /// The folders of the test: `A` and `B` on the Mac, `Stick` the drive.
    internal let box: Sandbox
    /// The folder that stands for the drive.
    internal let stick: URL
    /// Where a tab goes that was never anywhere else.
    internal let home = FileManager.default.homeDirectoryForCurrentUser

    /// Makes the folders, the drive with a photo in it.
    internal init() throws {
        box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.folder("B")
        try box.file("Stick/photos/cat.jpg", "meow")
        stick = box.url("Stick")
    }

    private func bench(_ drive: StandInDrive) -> (TestBench, SystemToolsPlugin) {
        let tools = SystemToolsPlugin(launchesApplications: false, volumes: drive)
        return (
            TestBench(plugins: [tools], fileSystems: [LocalFileSystem()], left: box.url("A"), right: box.url("B")),
            tools
        )
    }

    /// The panels on the drive go back to where they were before it, a background tab goes home,
    /// and the user is told the drive can be removed.
    @Test
    internal func thePanelsGoBackToWhereTheyCameFromAndTheUserIsTold() {
        let drive = StandInDrive(stick, refusals: [])
        let (bench, tools) = bench(drive)
        var released: [URL] = []
        bench.kernel.fileSystems.addVolumeReleaser { released.append($0) }
        bench.left.show(box.url("Stick/photos"))
        // A tab in the background that never was anywhere else goes home.
        let background = bench.right.tabs.openTab(showing: stick, activate: false)
        bench.commands.perform(SystemToolsCommands.ejectVolume)
        #expect(bench.left.model.directory.isSameLocation(as: box.url("A")))
        #expect(
            background.directory.isSameLocation(as: home)
                && bench.right.model.directory.isSameLocation(as: box.url("B"))
        )
        #expect(released.count == 1 && released.first?.isSameLocation(as: stick) == true && drive.ejects == 1)
        #expect(
            bench.interaction.log.last == "notice: “STICK” can now be removed safely."
                && tools.log.last == "eject: \(stick.path)"
        )
    }

    /// With a location, the drive of that location is ejected, whichever panel is active.
    @Test
    internal func theDriveOfAGivenLocationIsEjectedWhicheverPanelIsActive() {
        let drive = StandInDrive(stick, refusals: [])
        let (bench, _) = bench(drive)
        bench.right.show(stick)
        bench.commands.perform(SystemToolsCommands.ejectVolume, .location(stick))
        #expect(bench.right.model.directory.isSameLocation(as: box.url("B")) && drive.ejects == 1)
    }

    /// A drive another program uses is not ejected: the panels come back to it and the user is told who uses it.
    @Test
    internal func aDriveInUseIsNotEjectedAndThePanelsComeBack() {
        let drive = StandInDrive(stick, refusals: [EjectRefusal(reason: "The volume is in use.", program: "Preview")])
        let (bench, tools) = bench(drive)
        bench.left.show(box.url("Stick/photos"))
        bench.commands.perform(SystemToolsCommands.ejectVolume)
        #expect(bench.left.model.directory.isSameLocation(as: box.url("Stick/photos")))
        #expect(
            bench.interaction.log.last == "inform: “STICK” cannot be ejected" && tools.log.isEmpty && drive.ejects == 1
        )
    }

    /// When this program itself still holds the drive, the eject is tried again a moment later.
    @Test
    internal func whatThisProgramLetGoOfIsGivenAMoment() {
        let drive = StandInDrive(
            stick,
            refusals: [EjectRefusal(reason: "busy", program: "AFileManager", isThisProgram: true)]
        )
        let (bench, _) = bench(drive)
        bench.left.show(stick)
        bench.commands.perform(SystemToolsCommands.ejectVolume)
        #expect(drive.ejects == 2 && bench.interaction.log.last == "notice: “STICK” can now be removed safely.")
    }

    /// A pending write that fails stops the eject: the drive stays, and so does the panel on it.
    @Test
    internal func aWriteThatFailsKeepsTheDrive() {
        struct Unwritable: Error {}
        let drive = StandInDrive(stick, refusals: [])
        let (bench, _) = bench(drive)
        let volume = stick
        bench.kernel.fileSystems.addFlusher { url, _ in if url.isSameLocation(as: volume) { throw Unwritable() } }
        bench.left.show(stick)
        bench.commands.perform(SystemToolsCommands.ejectVolume)
        #expect(drive.ejects == 0 && bench.interaction.log.last == "inform: “STICK” was not ejected")
        #expect(bench.left.model.directory.isSameLocation(as: stick))
    }

    /// The start-up disk cannot be ejected, and the panel stays where it is.
    @Test
    internal func theSystemDiskIsNotEjected() {
        let drive = StandInDrive(stick, refusals: [])
        let (bench, _) = bench(drive)
        bench.commands.perform(SystemToolsCommands.ejectVolume)
        #expect(drive.ejects == 0 && bench.interaction.log.last == "inform: Macintosh HD cannot be ejected.")
        #expect(bench.left.model.directory.isSameLocation(as: box.url("A")))
    }

    /// Only drives that can leave the Mac (sticks, cards, disk images, external disks, shares) may be ejected.
    @Test
    internal func onlyDrivesThatLeaveTheMacCanBeEjected() {
        let (yes, never, unknown) = (Place.Fact.known(true), Place.Fact.known(false), Place.Fact.unknown)
        func ejectable(
            _ path: String,
            internal inside: Place.Fact,
            root: Place.Fact = .known(false),
            local: Place.Fact = .known(true),
            removable: Place.Fact = .known(false),
            ejectable: Place.Fact = .known(false)
        ) -> Bool {
            var traits = Place.VolumeTraits(path: path, values: nil)
            (traits.isRootFileSystem, traits.isInternal, traits.isLocal) = (root, inside, local)
            (traits.isRemovable, traits.isEjectable) = (removable, ejectable)
            return traits.mayBeEjected
        }
        // Never: the start-up disk, a system volume, a second disk or partition inside the Mac,
        // or a disk the system says nothing about.
        #expect(!ejectable("/", internal: yes, root: yes))
        #expect(!ejectable("/System/Volumes/Data", internal: yes))
        #expect(!ejectable("/Volumes/Archive", internal: yes))
        #expect(
            !ejectable(
                "/Volumes/Mystery",
                internal: unknown,
                root: unknown,
                local: unknown,
                removable: unknown,
                ejectable: unknown
            )
        )
        // Yes: a USB stick, a card in the Mac's reader, a disk image, an external disk, a share.
        #expect(ejectable("/Volumes/STICK", internal: never, removable: yes, ejectable: yes))
        #expect(ejectable("/Volumes/CARD", internal: yes, removable: yes))
        #expect(ejectable("/Volumes/Installer", internal: unknown, ejectable: yes))
        #expect(ejectable("/Volumes/Backup", internal: never))
        #expect(ejectable("/Volumes/Public", internal: unknown, local: never))
    }

    /// A panel's history tells the last folder it showed outside the drive.
    @Test
    internal func theHistoryKnowsWhereThePanelWasBeforeTheDrive() {
        let (bench, _) = bench(StandInDrive(stick, refusals: []))
        #expect(bench.left.model.lastVisited { _ in true } == nil)
        for folder in ["B", "Stick", "Stick/photos"] { bench.left.show(box.url(folder)) }
        let volume = stick
        let before = bench.left.model.lastVisited { !($0.isSameLocation(as: volume) || $0.isInside(volume)) }
        #expect(before?.isSameLocation(as: box.url("B")) == true)
    }
}
