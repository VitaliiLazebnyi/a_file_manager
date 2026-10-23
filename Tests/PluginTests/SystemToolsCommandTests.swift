import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import SystemToolsPlugin

/// The system tools through their commands.
///
/// Nothing here starts another application; the only programs run are `echo`, `pwd`, `true`,
/// `false` and the like.
@MainActor
@Suite
internal struct SystemToolsCommandTests {
    /// A file system in memory, for lists that are not on the local disks.
    internal let memory = MemoryFileSystem()
    /// The plugin under test, kept from acting outside the program.
    internal let tools = SystemToolsPlugin(launchesApplications: false)
    /// The kernel and panels the plugin runs in.
    internal let bench: TestBench
    /// The local folders of the test: `A` with `one.txt`, and `B`.
    internal let box: Sandbox

    /// The bench's commands.
    internal var commands: CommandRegistry { bench.commands }
    /// The bench's scripted user.
    internal var interaction: ScriptedInteraction { bench.interaction }

    /// Makes the folders on the disk and in memory, and a bench with the left panel in `A`.
    internal init() throws {
        box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.folder("B")
        memory.addFile("/A/one.txt", "new")
        memory.addFile("/A/two.txt", String(repeating: "x", count: 2_048))
        memory.addFile("/A/docs/in.txt", "inside")
        memory.addFile("/A/docs/deep/far.txt", "far")
        memory.addDirectory("/B")
        bench = TestBench(
            plugins: [tools, SelectionPlugin()],
            fileSystems: [LocalFileSystem(), memory],
            left: box.url("A"),
            right: box.url("B")
        )
    }

    // MARK: Command line

    /// A typed line runs in the source panel's folder, its output is shown, and the line is remembered.
    @Test
    internal func aTypedLineRunsInTheSourceFolderAndItsOutputIsShown() {
        interaction.formAnswers = [.accept, .accept]
        commands.perform(.runCommandLine, .text("echo hello"))
        #expect(shownText() == "hello\n" && interaction.log.last == "form: echo hello")
        commands.perform(.runCommandLine, .text("  pwd  "))
        #expect(folder(shownText()) == box.url("A").path)
        #expect(tools.log == ["ran: echo hello", "ran: pwd"])
        #expect(bench.jobService.titles == ["Running: echo hello", "Running: pwd"])
        // A line typed with a blank in front is run and not remembered (see Review2ConfigASystemTools).
        #expect(bench.kernel.settings.value([String].self, forKey: "systemTools.history") == ["echo hello"])
        // Newest first, as the command line's history list shows them.
        commands.perform(.runCommandLine, .text("pwd"))
        #expect(bench.kernel.settings.value([String].self, forKey: "systemTools.history") == ["pwd", "echo hello"])
    }

    /// A failing command reports its exit status; the output setting decides when anything is shown.
    @Test
    internal func aFailingCommandReportsItsExitStatus() {
        commands.perform(.runCommandLine, .text("false"))
        #expect(interaction.log.last == "form: false (exit status 1)")
        #expect(shownText() == "The command ended with exit status 1 and wrote nothing.")
        // A command that succeeds silently shows nothing, unless output is always wanted.
        commands.perform(.runCommandLine, .text("true"))
        #expect(interaction.forms.count == 1)
        bench.kernel.settings.set(1, forKey: SystemToolsPlugin.showOutputKey)
        commands.perform(.runCommandLine, .text("true"))
        #expect(interaction.forms.count == 2 && shownText() == "The command wrote nothing.")
        bench.kernel.settings.set(2, forKey: SystemToolsPlugin.showOutputKey)
        commands.perform(.runCommandLine, .text("echo unseen"))
        #expect(interaction.forms.count == 2 && tools.log.last == "ran: echo unseen")
    }

    /// While tests keep the tools from acting, only harmless lines run; the others are recorded as skipped.
    @Test
    internal func testsRunOnlyHarmlessLines() {
        for line in [
            "make install", "rm -rf x", "echo hi; rm x", "echo `id`", "echo $(id)", "echo hi > file", "echo hi &",
            "open -a Terminal",
            "TextEdit.app"
        ] {
            commands.perform(.runCommandLine, .text(line))
        }
        #expect(tools.log.allSatisfy { $0.hasPrefix("skipped: ") } && tools.log.count == 9)
        #expect(bench.jobService.titles.isEmpty && interaction.forms.isEmpty)
        commands.perform(.runCommandLine, .text("   "))
        #expect(tools.log.count == 9)
    }

    /// A line typed while the panel shows no local folder runs in the home folder.
    @Test
    internal func outsideTheLocalDisksTheHomeFolderIsUsed() {
        bench.left.show(memory.url("/A"))
        commands.perform(.runCommandLine, .text("pwd"))
        #expect(folder(shownText()) == FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path)
    }

    /// Run Command asks for the line and offers the last one again.
    @Test
    internal func runCommandAsksForTheLine() {
        interaction.promptAnswers = [.text("echo asked"), .accept, .cancel]
        commands.perform(SystemToolsCommands.runPrompt)
        #expect(shownText() == "asked\n")
        // The last line is proposed again.
        commands.perform(.runCommandLine)
        #expect(
            interaction.log.contains("prompt: Run command: [echo asked]")
                && tools.log == ["ran: echo asked", "ran: echo asked"]
        )
        commands.perform(SystemToolsCommands.runPrompt)
        #expect(tools.log.count == 2)
    }

    /// When a plugin offers a viewer, the output is shown there instead of in a dialog.
    @Test
    internal func theViewerShowsTheOutputWhenThereIsOne() {
        let viewer = RecordingViewer()
        let viewerBench = TestBench(
            plugins: [viewer, SystemToolsPlugin(launchesApplications: false)],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B")
        )
        viewerBench.commands.perform(.runCommandLine, .text("printf '%s-%s' a b"))
        #expect(
            viewer.texts.map(\.text) == ["a-b"] && viewer.texts.first?.title == "printf '%s-%s' a b"
                && viewerBench.interaction.forms.isEmpty
        )
    }

    // MARK: Terminal, system, volumes

    /// What would start applications (a terminal, quitting, minimizing) is only recorded, and needs a local folder.
    @Test
    internal func whatWouldStartApplicationsIsOnlyRecorded() async {
        commands.perform(SystemToolsCommands.openTerminal)
        // The terminal is looked up off the main thread.
        #expect(await settle { !tools.log.isEmpty })
        commands.perform(SystemToolsCommands.quit)
        commands.perform(SystemToolsCommands.minimize)
        #expect(tools.log == ["terminal: \(box.url("A").path)", "quit", "minimize"])
        bench.left.show(memory.url("/A"))
        #expect(
            !commands.isEnabled(SystemToolsCommands.openTerminal)
                && !commands.isEnabled(SystemToolsCommands.renameVolume)
                && !commands.isEnabled(SystemToolsCommands.ejectVolume)
                && !commands.isEnabled(SystemToolsCommands.openWith)
        )
    }

    /// System Information is shown as text with the hardware, the software and the volumes.
    @Test
    internal func systemInformationIsShownAsText() {
        interaction.formAnswers = [.accept]
        commands.perform(SystemToolsCommands.systemInformation)
        let text = shownText() ?? ""
        #expect(interaction.log.last == "form: System Information")
        for label in [
            "Hardware", "CPU cores:", "Installed RAM:", "Software", "macOS version:", "Time since start:", "Volumes"
        ] {
            #expect(text.contains(label), "\(label)")
        }
    }

    /// A volume is renamed only with a valid name that differs from the one it has.
    @Test
    internal func aVolumeIsRenamedOnlyWithAValidName() {
        interaction.promptAnswers = [.text("Work Disk"), .text("a/b"), .accept, .cancel]
        commands.perform(SystemToolsCommands.renameVolume)
        #expect(
            tools.log.count == 1 && tools.log[0].hasPrefix("rename-volume: ") && tools.log[0].hasSuffix(" -> Work Disk")
        )
        #expect(interaction.log.contains { $0.hasPrefix("prompt: Set volume label - /") })
        commands.perform(SystemToolsCommands.renameVolume)
        #expect(interaction.log.last == "inform: The volume cannot be named a/b!")
        // The same name and Cancel change nothing.
        commands.perform(SystemToolsCommands.renameVolume)
        commands.perform(SystemToolsCommands.renameVolume)
        #expect(tools.log.count == 1)
    }

    /// The system volume cannot be ejected.
    @Test
    internal func theSystemVolumeCannotBeEjected() {
        commands.perform(SystemToolsCommands.ejectVolume)
        #expect(interaction.log.last?.hasSuffix("cannot be ejected.") == true && tools.log.isEmpty)
    }

    /// Open With lists the applications that can open the item under the cursor.
    @Test
    internal func openWithListsApplications() {
        bench.left.moveCursor(toName: "one.txt")
        interaction.formAnswers = [.accept]
        commands.perform(SystemToolsCommands.openWith)
        // Which applications there are depends on the Mac; either one was picked or none is known.
        let picked = tools.log.last?.hasPrefix("open-with: ") == true && tools.log.last?.hasSuffix(" one.txt") == true
        #expect(picked || interaction.log.last == "inform: No application is known to open one.txt.")
    }

    /// The text of the multi-line field of the form shown last.
    internal func shownText() -> String? {
        for field in interaction.forms.last ?? [] {
            if case .multilineText(let text) = field.kind {
                return text
            }
        }
        return nil
    }

    /// Lets the main thread run what was queued for it until `condition` holds; false when it still
    /// does not after `Wait.ceiling`.
    internal func settle(until condition: () -> Bool) async -> Bool {
        let end = Date(timeIntervalSinceNow: Wait.ceiling)
        while !condition() {
            guard Date() < end else {
                return false
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }

    /// What `pwd` printed, written the way the sandbox writes its paths.
    internal func folder(_ output: String?) -> String? {
        output.map { URL(fileURLWithPath: $0.trimmingCharacters(in: .newlines)).resolvingSymlinksInPath().path }
    }
}
