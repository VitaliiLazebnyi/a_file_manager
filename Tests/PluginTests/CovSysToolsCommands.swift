import AFMContracts
import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import SystemToolsPlugin

/// The volume name, Open With, Quit and Minimize with a desktop that only records, and the quiet desktop itself.
@MainActor
@Suite
internal struct CovSysToolsCommands {
    private let stage: CovSysToolsStage

    private var recorder: CovSysToolsDesktop { stage.recorder }

    /// The files of the stage; throws when the disk refuses.
    internal init() throws {
        stage = try CovSysToolsStage()
    }

    // MARK: Volume name

    /// A volume is renamed by the desktop, and the panels are read again; a refusal is reported.
    @Test
    internal func aVolumeIsRenamedOrTheRefusalReported() {
        let disk = CovSysToolsVolume(VolumeFacts(url: stage.box.root, name: "Disk"))
        let (bench, tools) = stage.bench(recorder.desktop(volumes: disk))
        bench.interaction.promptAnswers = [.text("Work")]
        bench.commands.perform(SystemToolsCommands.renameVolume)
        #expect(recorder.renamed.value.map(\.name) == ["Work"])
        #expect(tools.log == ["rename-volume: \(stage.box.root.path) -> Work"])
        struct Refused: Error {}
        recorder.renameError.value = Refused()
        bench.interaction.promptAnswers = [.text("Other")]
        bench.commands.perform(SystemToolsCommands.renameVolume)
        #expect(bench.interaction.log.last == "inform: The volume Disk cannot be renamed!" && tools.log.count == 1)
    }

    /// A folder whose volume is not known cannot be renamed.
    @Test
    internal func aFolderOfNoKnownVolumeIsNotRenamed() {
        let (bench, _) = stage.bench(recorder.desktop(volumes: CovSysToolsVolume(VolumeFacts())))
        bench.commands.perform(SystemToolsCommands.renameVolume)
        #expect(bench.interaction.log == ["inform: The volume of \(stage.box.url("A").path) cannot be determined."])
    }

    /// Cancelled, the question about the volume or the renaming does nothing more.
    @Test
    internal func aCancelledRenameDoesNothing() {
        let (cancelled, _) = stage.bench(CoverageSmallJobs.Mode.cancelled)
        cancelled.commands.perform(SystemToolsCommands.renameVolume)
        #expect(cancelled.interaction.log.isEmpty)
        let (late, tools) = stage.bench(CoverageSmallJobs.Mode.cancelledFrom(first: 1))
        late.interaction.promptAnswers = [.text("Late Name")]
        late.commands.perform(SystemToolsCommands.renameVolume)
        #expect(recorder.renamed.value.isEmpty && tools.log.isEmpty && late.jobService.titles.count == 2)
    }

    // MARK: Open With

    /// The usual application comes first and is marked; the one picked opens the file.
    @Test
    internal func theUsualApplicationComesFirstAndThePickedOneOpens() throws {
        let (usual, other) = (stage.box.url("Usual.app"), stage.box.url("Other.app"))
        recorder.applications.value = (usual, [other, usual])
        let (bench, tools) = stage.bench(recorder.desktop())
        bench.left.moveCursor(toName: "one.txt")
        bench.interaction.formAnswers = [.accept]
        bench.commands.perform(SystemToolsCommands.openWith)
        let kind = try #require(bench.interaction.forms.last?.first?.kind)
        guard case .list(let rows, _) = kind else {
            Issue.record("no list of applications")
            return
        }
        #expect(rows.count == 2 && rows[0].hasSuffix(" (default)") && !rows[1].hasSuffix(" (default)"))
        #expect(recorder.opened.value.first?.application == usual && tools.log == ["open-with: Usual.app one.txt"])
        // Without a choice, or without a usual one, nothing opens unasked.
        recorder.applications.value = (nil, [other])
        bench.commands.perform(SystemToolsCommands.openWith)
        #expect(recorder.opened.value.count == 1 && tools.log.count == 1)
        let (cancelled, _) = stage.bench(CoverageSmallJobs.Mode.cancelled)
        cancelled.left.moveCursor(toName: "one.txt")
        cancelled.commands.perform(SystemToolsCommands.openWith)
        #expect(cancelled.interaction.log.isEmpty)
    }

    // MARK: The program

    /// Quit and Minimize go to the desktop.
    @Test
    internal func quitAndMinimizeGoToTheDesktop() {
        let (bench, tools) = stage.bench(recorder.desktop())
        bench.commands.perform(SystemToolsCommands.quit)
        bench.commands.perform(SystemToolsCommands.minimize)
        #expect(recorder.quits.value == 1 && recorder.minimizes.value == 1 && tools.log == ["quit", "minimize"])
    }

    /// The quiet desktop does nothing outside the program and knows nothing it would have to ask the system.
    @Test
    internal func theQuietDesktopDoesNothing() throws {
        let quiet = ToolsDesktop.quiet
        let folder = stage.box.url("A")
        quiet.start(folder)
        quiet.open([folder], folder)
        quiet.print(NSPrintOperation(view: NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))))
        quiet.copy("text")
        quiet.quit()
        quiet.minimize()
        try quiet.renameVolume(folder, "Name")
        #expect(quiet.applicationWithIdentifier("com.apple.Terminal") == nil)
        #expect(quiet.applicationsToOpen(folder).usual == nil && quiet.applicationsToOpen(folder).all.isEmpty)
        #expect(quiet.environment() == ProcessInfo.processInfo.environment)
        #expect(quiet.searchPath() == TypedCommand.processPath)
        let (make, echo) = (try #require(TypedCommand("make")), try #require(TypedCommand("echo")))
        #expect(!quiet.mayRun(make) && quiet.mayRun(echo))
        #expect(quiet.volumes.eject(VolumeFacts(url: folder, name: "A")) == nil)
        #expect(quiet.printer.path == "/usr/bin/true" && quiet.shell.executable.path == "/bin/sh")
    }
}
