import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import SystemToolsPlugin

/// The volumes of the Mac as the tools see them, ejected by a stand-in for the system's unmount, and the arms of an
/// eject the other tests do not take: cancelled questions, refusals, panels that cannot go back.
@MainActor
@Suite
internal struct CovSysToolsVolumes {
    private let box: Sandbox
    private let stick: URL

    /// A sandbox with `A/one.txt`, `B` and the stick `Stick/photos/cat.jpg`.
    internal init() throws {
        box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.folder("B")
        try box.file("Stick/photos/cat.jpg", "meow")
        stick = box.url("Stick")
    }

    // MARK: The system's volumes

    /// A folder that is not there is on no volume; one that is is on a named volume.
    @Test
    internal func aFolderIsOnANamedVolumeWhenItIsThere() {
        let volumes = SystemVolumes { _, _, done in done(nil) }
        #expect(volumes.facts(of: box.url("none")) == VolumeFacts())
        let facts = volumes.facts(of: box.root)
        #expect(facts.url != nil && !facts.name.isEmpty && !facts.canBeEjected)
    }

    /// An eject asks the unmount gently, a disk as a whole and a share alone; what the system says is passed on.
    @Test
    internal func anEjectAsksTheUnmountAndPassesOnTheAnswer() {
        let asked = Shared<[FileManager.UnmountOptions]>([])
        let answer = Shared<(any Error)?>(nil)
        let volumes = SystemVolumes { _, options, done in
            asked.modify { $0.append(options) }
            done(answer.value)
        }
        #expect(volumes.eject(VolumeFacts()) == EjectRefusal(reason: "The volume is not known."))
        #expect(volumes.eject(VolumeFacts(url: stick)) == nil)
        #expect(volumes.eject(VolumeFacts(url: stick, isNetwork: true)) == nil)
        #expect(asked.value == [[.allPartitionsAndEjectDisk], []])
        answer.value = refusal(by: getpid())
        let own = volumes.eject(VolumeFacts(url: stick))
        #expect(own?.isThisProgram == true && own?.program == SystemVolumes.programName(getpid()))
        answer.value = refusal(by: 1)
        let other = volumes.eject(VolumeFacts(url: stick))
        #expect(other?.program == nil && other?.isThisProgram == false)
        answer.value = refusal(by: nil)
        let unknown = volumes.eject(VolumeFacts(url: stick))
        #expect(unknown?.program == nil && unknown?.isThisProgram == false && unknown?.reason.isEmpty == false)
    }

    /// A program is named as an application where it is one, else by its process; a process that does not tell
    /// has no name.
    @Test
    internal func aProgramIsNamedAsTheUserKnowsIt() throws {
        #expect(SystemVolumes.programName(0) == nil && SystemVolumes.programName(Int32.max) == nil)
        // A process of another user does not tell its name; one of this user that is no application does.
        #expect(SystemVolumes.programName(1) == nil)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        #expect(SystemVolumes.programName(child.processIdentifier) == "sleep")
        let application = try #require(NSWorkspace.shared.runningApplications.first { $0.localizedName != nil })
        #expect(SystemVolumes.programName(application.processIdentifier) == application.localizedName)
    }

    // MARK: Ejecting

    /// A volume of no name is called by the folder's path.
    @Test
    internal func aVolumeOfNoNameIsCalledByThePath() {
        let bench = bench(CovSysToolsVolume(VolumeFacts()), fileSystems: [LocalFileSystem()])
        bench.commands.perform(SystemToolsCommands.ejectVolume)
        #expect(bench.interaction.log == ["inform: \(box.url("A").path) cannot be ejected."])
    }

    /// Cancelled while the volume is asked about, nothing happens; cancelled while it is ejected, the panels stay
    /// where they went.
    @Test
    internal func aCancelledEjectStopsWhereItWas() {
        let drive = drive([])
        for mode in [CoverageSmallJobs.Mode.cancelled, .cancelledFrom(first: 1)] {
            let bench = CoverageSmallBench(
                mode,
                plugins: [SystemToolsPlugin(launchesApplications: false, volumes: drive)],
                fileSystems: [LocalFileSystem()],
                left: box.url("A"),
                right: box.url("B")
            )
            bench.left.show(stick)
            bench.commands.perform(SystemToolsCommands.ejectVolume)
            #expect(bench.interaction.log.isEmpty && drive.ejects.value == 0)
        }
    }

    /// Refused by this program again and again, or without a program named, the user is told and the panel comes
    /// back.
    @Test
    internal func aRefusalIsExplained() {
        let mine = EjectRefusal(reason: "busy", program: "AFileManager", isThisProgram: true)
        let refusals = Array(repeating: mine, count: VolumeEjection.ownRefusalRetries + 1)
        let drive = drive(refusals + [EjectRefusal(reason: "The volume is busy.")])
        let bench = bench(drive, fileSystems: [LocalFileSystem()])
        bench.left.show(stick)
        bench.commands.perform(SystemToolsCommands.ejectVolume)
        #expect(drive.ejects.value == VolumeEjection.ownRefusalRetries + 1)
        #expect(bench.interaction.log.last == "inform: “STICK” cannot be ejected")
        bench.commands.perform(SystemToolsCommands.ejectVolume)
        #expect(bench.interaction.log.last == "inform: “STICK” cannot be ejected")
        #expect(bench.left.model.directory.isSameLocation(as: stick))
    }

    /// A panel whose folder before the drive is gone goes home; refused, it comes back to the drive.
    @Test
    internal func aPanelWhoseFolderBeforeIsGoneGoesHome() throws {
        let bench = bench(drive([EjectRefusal(reason: "busy")]), fileSystems: [LocalFileSystem()])
        let gone = try box.folder("Gone")
        bench.left.show(gone)
        bench.left.show(stick)
        try FileManager.default.removeItem(at: gone)
        var shownWhileEjecting: URL?
        bench.kernel.fileSystems.addVolumeReleaser { _ in shownWhileEjecting = bench.left.model.directory }
        bench.commands.perform(SystemToolsCommands.ejectVolume)
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(shownWhileEjecting?.isSameLocation(as: home) == true)
        #expect(bench.left.model.directory.isSameLocation(as: stick))
    }

    /// Refused, a panel the user moved meanwhile stays where it is; a tab in the background goes back to the drive.
    @Test
    internal func aRefusalLeavesMovedPanelsAndBringsBackBackgroundTabs() {
        let bench = bench(drive([EjectRefusal(reason: "busy")]), fileSystems: [LocalFileSystem()])
        bench.left.show(stick)
        let background = bench.right.tabs.openTab(showing: stick, activate: false)
        let elsewhere = box.url("B")
        bench.kernel.fileSystems.addVolumeReleaser { _ in bench.left.show(elsewhere) }
        bench.commands.perform(SystemToolsCommands.ejectVolume)
        #expect(bench.left.model.directory.isSameLocation(as: elsewhere))
        #expect(background.directory.isSameLocation(as: stick))
    }

    /// A tab in the background is pointed at its new folder even where no file system knows it.
    @Test
    internal func aBackgroundTabIsRetargetedWithoutAFileSystem() {
        let bench = bench(drive([]), fileSystems: [])
        let background = bench.right.tabs.openTab(showing: stick, activate: false)
        bench.commands.perform(SystemToolsCommands.ejectVolume)
        #expect(background.directory.isSameLocation(as: FileManager.default.homeDirectoryForCurrentUser))
        #expect(bench.interaction.log.last == "notice: “STICK” can now be removed safely.")
    }

    /// The stick as a volume that can be ejected, answering `refusals` in turn.
    private func drive(_ refusals: [EjectRefusal?]) -> CovSysToolsVolume {
        let drive = CovSysToolsVolume(VolumeFacts(url: stick, name: "STICK", canBeEjected: true))
        drive.refusals.value = refusals
        return drive
    }

    /// A bench on `volumes` and `fileSystems` whose jobs run at once.
    private func bench(_ volumes: any VolumeAccess, fileSystems: [any FileSystemProvider]) -> TestBench {
        TestBench(
            plugins: [SystemToolsPlugin(launchesApplications: false, volumes: volumes)],
            fileSystems: fileSystems,
            left: box.url("A"),
            right: box.url("B")
        )
    }

    /// An unmount refused by the process `pid`, or by nobody named.
    private func refusal(by pid: Int32?) -> NSError {
        let info: [String: Any] = pid.map { [NSFileManagerUnmountDissentingProcessIdentifierErrorKey: $0] } ?? [:]
        return NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: info)
    }
}
