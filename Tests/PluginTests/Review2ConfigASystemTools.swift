import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import SystemToolsPlugin

/// The system tools after review 2: what is remembered of typed lines, which application a
/// name means, and jobs that end when they are cancelled.
@MainActor
@Suite
internal struct Review2ConfigASystemTools {
    /// The plugin under test, kept from acting outside the program.
    internal let tools = SystemToolsPlugin(launchesApplications: false)
    /// The settings the bench's kernel keeps, read back by the tests.
    internal let settings = MemorySettings()
    /// The kernel and panels the plugin runs in.
    internal let bench: TestBench
    /// The folders of the test: `A` (with `one.txt` and `sub`) and `B`.
    internal let box: Sandbox

    /// The bench's commands.
    internal var commands: CommandRegistry { bench.commands }
    /// The bench's scripted user.
    internal var interaction: ScriptedInteraction { bench.interaction }

    /// The remembered lines, newest first; none when nothing is stored.
    internal var history: [String] { settings.value([String].self, forKey: "systemTools.history") ?? [] }

    /// Makes the folders and a bench with the left panel in `A`, the right in `B`.
    internal init() throws {
        box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.folder("A/sub")
        try box.folder("B")
        bench = TestBench(
            plugins: [tools, SelectionPlugin()],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B"),
            settings: settings
        )
    }

    /// A line typed with a blank in front is not remembered, and switching remembering off forgets what was.
    @Test
    internal func aLineTypedWithABlankInFrontIsNotRemembered() {
        interaction.formAnswers = Array(repeating: .accept, count: 8)
        commands.perform(.runCommandLine, .text("echo one"))
        commands.perform(.runCommandLine, .text(" echo secret"))
        commands.perform(.runCommandLine, .text("\techo secret"))
        #expect(history == ["echo one"] && tools.log == ["ran: echo one", "ran: echo secret", "ran: echo secret"])
        #expect(CommandHistory.isPrivate(" x") && !CommandHistory.isPrivate("x ") && !CommandHistory.isPrivate(""))
        // Switched off in the options, nothing is remembered and what was goes.
        let page = bench.kernel.preferences.pages.first { $0.title == "System Tools" }
        #expect(page?.preferences.map(\.key).contains(SystemToolsPlugin.recordHistoryKey) == true)
        settings.set(false, forKey: SystemToolsPlugin.recordHistoryKey)
        page?.onChange()
        #expect(history.isEmpty)
        commands.perform(.runCommandLine, .text("echo two"))
        #expect(history.isEmpty && tools.log.last == "ran: echo two")
    }

    /// Print File Contents is offered when a file is among the operands, not for folders alone.
    @Test
    internal func printIsOfferedForFilesWithoutMakingTheListOfThem() {
        bench.left.moveCursor(toName: "one.txt")
        #expect(commands.isEnabled(SystemToolsCommands.printFile))
        bench.left.moveCursor(toName: "sub")
        #expect(!commands.isEnabled(SystemToolsCommands.printFile))
        commands.perform(.selectAll)
        #expect(commands.isEnabled(SystemToolsCommands.printFile))
        bench.left.model.setSelection(names: ["sub"])
        #expect(!commands.isEnabled(SystemToolsCommands.printFile))
    }

    /// An installed application comes before one of the same name in the panel's folder, unless
    /// that one is asked for by path.
    @Test
    internal func anInstalledApplicationComesBeforeOneOfTheSameNameInThePanelsFolder() throws {
        let installed = try box.folder("Apps/Tool.app")
        let planted = try box.folder("Here/Tool.app")
        let only = try box.folder("Here/Only.app")
        let (here, folders) = (box.url("Here"), [box.url("Apps")])
        func found(_ line: String) -> String? {
            TypedCommand(line)?.application(relativeTo: here, searching: folders, path: TypedCommand.processPath)?.path
        }
        #expect(found("Tool.app") == installed.path && found("Tool.app notes.txt") == installed.path)
        // Asked for by path, the one in the folder is meant.
        #expect(found("./Tool.app") == planted.standardizedFileURL.path && found(planted.path) == planted.path)
        // A name no installed application has is still found where the panel is.
        #expect(
            found("Only.app") == only.standardizedFileURL.path && found("None.app") == nil
                && found("sub/None.app") == nil
        )
    }

    /// Whether a bare name is a program or an application is decided by the PATH it is given.
    @Test
    internal func whetherABareNameIsAProgramIsDecidedByThePathItIsGiven() throws {
        try box.folder("Apps/mytool.app")
        let program = try box.file("bin/mytool", "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        let typed = try #require(TypedCommand("mytool"))
        // On the PATH of the login shell: a program for the shell. Not on it: the application.
        #expect(
            typed.application(
                relativeTo: box.root,
                searching: [box.url("Apps")],
                path: "/nonexistent:" + box.url("bin").path
            )
                == nil
        )
        #expect(
            typed.application(relativeTo: box.root, searching: [box.url("Apps")], path: "/nonexistent")?
                .lastPathComponent == "mytool.app"
        )
    }

    /// System Information ends when it is cancelled, and lists hardware, software and volumes when it is not.
    @Test
    internal func systemInformationEndsWhenItIsCancelled() {
        let cancelled = CancellationFlag()
        cancelled.cancel()
        #expect(SystemInformation.gather(displays: [], cancellation: cancelled, asking: .system) == nil)
        #expect(
            SystemInformation.volumes(SystemInformation.Questions.system.volumes(), cancellation: cancelled)
                .allSatisfy { $0.value.hasSuffix("not answering") }
        )
        let information = SystemInformation.gather(displays: ["1x1"], cancellation: CancellationFlag(), asking: .system)
        #expect(
            information?.sections.map(\.title) == ["Hardware", "Software", "Volumes"]
                && information?.sections[2].rows.isEmpty == false
        )
    }

    /// A cancelled list with subfolders enters no further folder.
    @Test
    internal func aCancelledListWithSubfoldersEntersNoFolder() throws {
        try box.file("A/sub/deep/far.txt")
        let fileSystems = bench.kernel.fileSystems
        let items = try fileSystems.provider(for: box.url("A")).list(box.url("A"), showHidden: false)
        let running = ListCollector(
            fileSystems: fileSystems,
            showHidden: false,
            mask: ListMask("*.*"),
            depth: -1,
            cancellation: CancellationFlag()
        )
        #expect(running.rows(of: items).map(\.name) == ["one.txt", "sub", "sub/deep", "sub/deep/far.txt"])
        let cancelled = CancellationFlag()
        cancelled.cancel()
        let stopped = ListCollector(
            fileSystems: fileSystems,
            showHidden: false,
            mask: ListMask("*.*"),
            depth: -1,
            cancellation: cancelled
        )
        #expect(stopped.rows(of: items).map(\.name) == ["one.txt", "sub"])
    }

    /// Log lines stay on one line, and the log keeps only its newest lines.
    @Test
    internal func logLinesStayOneLineAndTheLogIsBounded() {
        commands.perform(.runCommandLine, .text("make 'a\nb'"))
        #expect(tools.log == ["skipped: make 'a\\nb'"])
        for number in 0..<1_200 { commands.perform(.runCommandLine, .text(" make \(number)")) }
        #expect(tools.log.count <= 512 && tools.log.last == "skipped: make 1199")
        #expect(DisplayText.oneLine("x\u{1B}[0m\ny", limit: 200) == "x\\u{1B}[0m\\ny")
    }

    /// The shell is always a POSIX shell, whatever the user's login shell is.
    @Test
    internal func theShellIsAlwaysAPosixShell() {
        #expect(LoginShell.posix.executable == "/bin/zsh" && LoginShell.posix.options.last == "-c")
        #expect(
            !LoginShell.usersShell(environment: ProcessInfo.processInfo.environment, account: LoginShell.accountShell())
                .isEmpty
        )
    }
}
