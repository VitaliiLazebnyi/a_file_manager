import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import SystemToolsPlugin

/// The command line, the terminal and the system information, with a desktop that only records: the arms the quiet
/// desktop of the other tests does not take.
@MainActor
@Suite
internal struct CovSysToolsLines {
    private let stage: CovSysToolsStage

    private var recorder: CovSysToolsDesktop { stage.recorder }

    /// The files of the stage; throws when the disk refuses.
    internal init() throws {
        stage = try CovSysToolsStage()
    }

    // MARK: Command line

    /// A plugin that has not started has logged nothing, whichever desktop it has.
    @Test
    internal func aPluginThatHasNotStartedHasLoggedNothing() {
        #expect(SystemToolsPlugin(launchesApplications: true).log.isEmpty)
        #expect(SystemToolsPlugin(launchesApplications: false).log.isEmpty)
    }

    /// In a folder that is not on this Mac a line runs, and is asked for, in the home folder.
    @Test
    internal func aLineRunsInTheHomeFolderWhenThePanelIsNotLocal() {
        let (bench, _) = stage.bench(.quiet)
        bench.left.show(stage.memory.url("/M"))
        bench.interaction.formAnswers = [.accept, .accept]
        bench.commands.perform(.runCommandLine, .text("pwd"))
        let printed = CovSysToolsStage.shownText(bench.interaction)?.trimmingCharacters(in: .newlines)
        #expect(printed.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == stage.home)
        bench.interaction.promptAnswers = [.text("pwd")]
        bench.commands.perform(SystemToolsCommands.runPrompt)
        #expect(bench.interaction.log.contains("prompt: Run command: [pwd]"))
    }

    /// A line ending in `&` is started and left alone: nothing is collected or shown.
    @Test
    internal func aDetachedLineIsStartedAndLeftAlone() {
        let (bench, tools) = stage.bench(recorder.desktop())
        bench.commands.perform(.runCommandLine, .text("echo hi &"))
        #expect(tools.log == ["started: echo hi"] && bench.interaction.forms.isEmpty)
        let history = bench.kernel.settings.value([String].self, forKey: "systemTools.history")
        #expect(history == ["echo hi &"])
    }

    /// An application is started, or given the files the line names.
    @Test
    internal func anApplicationIsStartedOrGivenTheFiles() {
        let (bench, tools) = stage.bench(recorder.desktop())
        let application = stage.box.url("A/Tool.app").standardizedFileURL
        bench.commands.perform(.runCommandLine, .text("./Tool.app"))
        #expect(recorder.started.value == [application] && tools.log == ["application: \(application.path)"])
        bench.commands.perform(.runCommandLine, .text("./Tool.app one.txt"))
        let opened = recorder.opened.value
        #expect(opened.count == 1 && opened.first?.application == application)
        #expect(opened.first?.files == [stage.box.url("A/one.txt").standardizedFileURL])
    }

    /// A shell that cannot start is reported with the program's name.
    @Test
    internal func aShellThatCannotStartIsReported() {
        let desktop = recorder.desktop(
            shell: stage.box.url("none"),
            searchPath: TypedCommand.processPath,
            printer: URL(fileURLWithPath: "/usr/bin/true"),
            volumes: ToolsDesktop.quiet.volumes
        )
        let (bench, tools) = stage.bench(desktop)
        bench.commands.perform(.runCommandLine, .text("echo hi"))
        #expect(bench.interaction.log.last == "inform: echo cannot be started!" && tools.log == ["ran: echo hi"])
    }

    /// A cancelled line ends; what it wrote is shown only when the output is always shown.
    @Test
    internal func aCancelledLineEndsAndIsShownOnlyWhenAlwaysShown() {
        let (bench, tools) = stage.bench(CoverageSmallJobs.Mode.cancelled)
        bench.commands.perform(.runCommandLine, .text("sleep 30"))
        #expect(tools.log == ["ran: sleep 30"] && bench.interaction.forms.isEmpty)
        bench.kernel.settings.set(1, forKey: SystemToolsPlugin.showOutputKey)
        bench.interaction.formAnswers = [.accept]
        bench.commands.perform(.runCommandLine, .text("sleep 30"))
        #expect(bench.interaction.log.last == "form: sleep 30 (cancelled)")
    }

    /// A line that runs for a while reports how much it wrote.
    @Test
    internal func aLongLineReportsItsOutput() {
        let (bench, _) = stage.bench(CoverageSmallJobs.Mode.cancelledFrom(first: 100))
        let line = "echo early; sleep 0.3; echo late"
        bench.interaction.formAnswers = [.accept]
        bench.commands.perform(.runCommandLine, .text(line))
        let reports = bench.jobService.reports.map(\.lines)
        #expect(reports.contains { $0.first == line && $0.last?.hasSuffix(" bytes of output") == true })
        #expect(CovSysToolsStage.shownText(bench.interaction) == "early\nlate\n")
    }

    /// Output beyond the limit is cut off, and the viewer says so.
    @Test
    internal func outputBeyondTheLimitIsCutOff() {
        let (bench, _) = stage.bench(.quiet)
        bench.interaction.formAnswers = [.accept]
        bench.commands.perform(.runCommandLine, .text("printf '%9000000s' x"))
        let shown = CovSysToolsStage.shownText(bench.interaction)
        #expect(shown?.hasSuffix("[The output was cut off after 8 MB.]") == true)
    }

    // MARK: Terminal

    /// A terminal that is not found is reported; one known by its identifier opens a window in the folder.
    @Test
    internal func theTerminalIsLookedUpAndOpensTheFolder() async {
        let (bench, tools) = stage.bench(recorder.desktop())
        bench.kernel.settings.set("No Such Terminal 42", forKey: SystemToolsPlugin.terminalKey)
        bench.commands.perform(SystemToolsCommands.openTerminal)
        #expect(await CovSysToolsDesktop.settle { bench.interaction.log.count == 1 })
        #expect(bench.interaction.log == ["inform: The terminal application No Such Terminal 42 was not found."])
        let terminal = stage.box.url("Term.app")
        recorder.identified.value = ["com.example.term": terminal]
        bench.kernel.settings.set(" com.example.term ", forKey: SystemToolsPlugin.terminalKey)
        bench.commands.perform(SystemToolsCommands.openTerminal)
        #expect(await CovSysToolsDesktop.settle { !tools.log.isEmpty })
        let opened = recorder.opened.value
        #expect(opened.count == 1 && opened.first?.files == [stage.box.url("A")])
        #expect(opened.first?.application == terminal)
    }

    /// An application is found by its path, by its name with or without `.app`, or else by its identifier.
    @Test
    internal func anApplicationIsFoundByPathNameOrIdentifier() {
        let none: (String) -> URL? = { _ in nil }
        let tool = stage.box.url("A/Tool.app")
        #expect(SystemTools.application(named: tool.path, identified: none) == tool)
        #expect(SystemTools.application(named: stage.box.url("A/None.app").path, identified: none) == nil)
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        #expect(SystemTools.application(named: "Terminal", identified: none) == terminal)
        #expect(SystemTools.application(named: "Terminal.app", identified: none) == terminal)
        #expect(SystemTools.application(named: "org.example.none") { _ in tool } == tool)
    }

    // MARK: System information

    /// A screen shows its pixels, and its points and scale when they differ.
    @Test
    internal func aScreenIsWrittenWithItsScale() {
        #expect(SystemTools.display(NSSize(width: 1_440, height: 900), scale: 2) == "2880x1800 (1440x900 @2x)")
        #expect(SystemTools.display(NSSize(width: 1_440, height: 900), scale: 1) == "1440x900")
    }

    /// Copy puts the information on the clipboard; a cancelled gathering shows nothing.
    @Test
    internal func systemInformationIsCopiedWhenAsked() {
        let (bench, _) = stage.bench(recorder.desktop())
        bench.interaction.formAnswers = [.values([:], button: 1), .accept]
        bench.commands.perform(SystemToolsCommands.systemInformation)
        #expect(recorder.copied.value.count == 1 && recorder.copied.value.first?.hasPrefix("Hardware") == true)
        bench.commands.perform(SystemToolsCommands.systemInformation)
        #expect(recorder.copied.value.count == 1)
        let (cancelled, _) = stage.bench(CoverageSmallJobs.Mode.cancelled)
        cancelled.commands.perform(SystemToolsCommands.systemInformation)
        #expect(cancelled.interaction.log.isEmpty)
    }
}
