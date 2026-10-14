import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import SystemToolsPlugin

/// A drive that is a folder of the sandbox: what it answers and how its ejects go is up to the test.
/// Unchecked: what it records is guarded by `lock`; its switches are set by the test before use.
private final class StandInDrive: VolumeAccess, @unchecked Sendable {
    let volume: URL
    private let lock = NSLock()
    private var refusals: [EjectRefusal?]
    private var ejectCount = 0

    init(_ volume: URL, refusals: [EjectRefusal?] = []) {
        self.volume = volume
        self.refusals = refusals
    }

    var ejects: Int {
        lock.lock()
        defer { lock.unlock() }
        return ejectCount
    }

    func facts(of directory: URL) -> VolumeFacts {
        guard directory.isSameLocation(as: volume) || directory.isInside(volume) else {
            return VolumeFacts(url: URL(fileURLWithPath: "/"), name: "Macintosh HD")
        }
        return VolumeFacts(url: volume, name: "STICK", canBeEjected: true)
    }

    func eject(_: VolumeFacts) -> EjectRefusal? {
        lock.lock()
        defer { lock.unlock() }
        ejectCount += 1
        return refusals.isEmpty ? nil : refusals.removeFirst()
    }
}

/// Ejecting a drive: the panels leave it for where they came from, the program lets go of it,
/// and a refusal brings the panels back.
@MainActor @Suite struct VolumeEjectionTests {
    let box: Sandbox
    let stick: URL
    let home = FileManager.default.homeDirectoryForCurrentUser

    init() throws {
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

    @Test func thePanelsGoBackToWhereTheyCameFromAndTheUserIsTold() {
        let drive = StandInDrive(stick)
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
                && bench.right.model.directory.isSameLocation(as: box.url("B")))
        #expect(released.count == 1 && released.first?.isSameLocation(as: stick) == true && drive.ejects == 1)
        #expect(
            bench.ui.log.last == "notice: “STICK” can now be removed safely."
                && tools.log.last == "eject: \(stick.path)")
    }

    @Test func theDriveOfAGivenLocationIsEjectedWhicheverPanelIsActive() {
        let drive = StandInDrive(stick)
        let (bench, _) = bench(drive)
        bench.right.show(stick)
        bench.commands.perform(SystemToolsCommands.ejectVolume, .location(stick))
        #expect(bench.right.model.directory.isSameLocation(as: box.url("B")) && drive.ejects == 1)
    }

    @Test func aDriveInUseIsNotEjectedAndThePanelsComeBack() {
        let drive = StandInDrive(stick, refusals: [EjectRefusal(program: "Preview", reason: "The volume is in use.")])
        let (bench, tools) = bench(drive)
        bench.left.show(box.url("Stick/photos"))
        bench.commands.perform(SystemToolsCommands.ejectVolume)
        #expect(bench.left.model.directory.isSameLocation(as: box.url("Stick/photos")))
        #expect(bench.ui.log.last == "inform: “STICK” cannot be ejected" && tools.log.isEmpty && drive.ejects == 1)
    }

    @Test func whatThisProgramLetGoOfIsGivenAMoment() {
        let drive = StandInDrive(
            stick, refusals: [EjectRefusal(program: "AFileManager", isThisProgram: true, reason: "busy")])
        let (bench, _) = bench(drive)
        bench.left.show(stick)
        bench.commands.perform(SystemToolsCommands.ejectVolume)
        #expect(drive.ejects == 2 && bench.ui.log.last == "notice: “STICK” can now be removed safely.")
    }

    @Test func aWriteThatFailsKeepsTheDrive() {
        struct Unwritable: Error {}
        let drive = StandInDrive(stick)
        let (bench, _) = bench(drive)
        let volume = stick
        bench.kernel.fileSystems.addFlusher { url, _ in if url.isSameLocation(as: volume) { throw Unwritable() } }
        bench.left.show(stick)
        bench.commands.perform(SystemToolsCommands.ejectVolume)
        #expect(drive.ejects == 0 && bench.ui.log.last == "inform: “STICK” was not ejected")
        #expect(bench.left.model.directory.isSameLocation(as: stick))
    }

    @Test func theSystemDiskIsNotEjected() {
        let drive = StandInDrive(stick)
        let (bench, _) = bench(drive)
        bench.commands.perform(SystemToolsCommands.ejectVolume)
        #expect(drive.ejects == 0 && bench.ui.log.last == "inform: Macintosh HD cannot be ejected.")
        #expect(bench.left.model.directory.isSameLocation(as: box.url("A")))
    }

    @Test func onlyDrivesThatLeaveTheMacCanBeEjected() {
        func ejectable(
            _ path: String, root: Bool? = false, internal inside: Bool?, local: Bool? = true, removable: Bool? = false,
            ejectable: Bool? = false
        ) -> Bool {
            Place.isEjectable(
                path: path, isRootFileSystem: root, isInternal: inside, isLocal: local, isRemovable: removable,
                isEjectable: ejectable)
        }
        // Never: the start-up disk, a system volume, a second disk or partition inside the Mac,
        // or a disk the system says nothing about.
        #expect(!ejectable("/", root: true, internal: true))
        #expect(!ejectable("/System/Volumes/Data", internal: true))
        #expect(!ejectable("/Volumes/Archive", internal: true))
        #expect(!ejectable("/Volumes/Mystery", root: nil, internal: nil, local: nil, removable: nil, ejectable: nil))
        // Yes: a USB stick, a card in the Mac's reader, a disk image, an external disk, a share.
        #expect(ejectable("/Volumes/STICK", internal: false, removable: true, ejectable: true))
        #expect(ejectable("/Volumes/CARD", internal: true, removable: true))
        #expect(ejectable("/Volumes/Installer", internal: nil, ejectable: true))
        #expect(ejectable("/Volumes/Backup", internal: false))
        #expect(ejectable("/Volumes/Public", internal: nil, local: false))
    }

    @Test func theHistoryKnowsWhereThePanelWasBeforeTheDrive() {
        let (bench, _) = bench(StandInDrive(stick))
        #expect(bench.left.model.lastVisited { _ in true } == nil)
        for folder in ["B", "Stick", "Stick/photos"] { bench.left.show(box.url(folder)) }
        let volume = stick
        let before = bench.left.model.lastVisited { !($0.isSameLocation(as: volume) || $0.isInside(volume)) }
        #expect(before?.isSameLocation(as: box.url("B")) == true)
    }
}
