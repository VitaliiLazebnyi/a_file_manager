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
@MainActor @Suite struct Review2ConfigASystemTools {
    let tools = SystemToolsPlugin(launchesApplications: false)
    let settings = MemorySettings()
    let bench: TestBench
    let box: Sandbox

    var commands: CommandRegistry { bench.commands }
    var ui: ScriptedInteraction { bench.interaction }

    init() throws {
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

    var history: [String]? { settings.value([String].self, forKey: "systemTools.history") }

    @Test func aLineTypedWithABlankInFrontIsNotRemembered() {
        ui.formAnswers = Array(repeating: .accept, count: 8)
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
        #expect(history == nil)
        commands.perform(.runCommandLine, .text("echo two"))
        #expect(history == nil && tools.log.last == "ran: echo two")
    }

    @Test func printIsOfferedForFilesWithoutMakingTheListOfThem() {
        bench.left.moveCursor(toName: "one.txt")
        #expect(commands.isEnabled(SystemToolsCommands.printFile))
        bench.left.moveCursor(toName: "sub")
        #expect(!commands.isEnabled(SystemToolsCommands.printFile))
        commands.perform(.selectAll)
        #expect(commands.isEnabled(SystemToolsCommands.printFile))
        bench.left.model.setSelection(names: ["sub"])
        #expect(!commands.isEnabled(SystemToolsCommands.printFile))
    }

    @Test func anInstalledApplicationComesBeforeOneOfTheSameNameInThePanelsFolder() throws {
        let installed = try box.folder("Apps/Tool.app")
        let planted = try box.folder("Here/Tool.app")
        let only = try box.folder("Here/Only.app")
        let (here, folders) = (box.url("Here"), [box.url("Apps")])
        func found(_ line: String) -> String? {
            TypedCommand(line)?.application(relativeTo: here, searching: folders)?.path
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

    @Test func whetherABareNameIsAProgramIsDecidedByThePathItIsGiven() throws {
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

    @Test func systemInformationEndsWhenItIsCancelled() {
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

    @Test func aCancelledListWithSubfoldersEntersNoFolder() throws {
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

    @Test func logLinesStayOneLineAndTheLogIsBounded() {
        commands.perform(.runCommandLine, .text("make 'a\nb'"))
        #expect(tools.log == ["skipped: make 'a\\nb'"])
        for number in 0..<1_200 { commands.perform(.runCommandLine, .text(" make \(number)")) }
        #expect(tools.log.count <= 512 && tools.log.last == "skipped: make 1199")
        #expect(DisplayText.oneLine("x\u{1B}[0m\ny") == "x\\u{1B}[0m\\ny")
    }

    @Test func theShellIsAlwaysAPosixShell() {
        #expect(LoginShell.posix.executable == "/bin/zsh" && LoginShell.posix.options.last == "-c")
        #expect(
            !LoginShell.usersShell(environment: ProcessInfo.processInfo.environment, account: LoginShell.accountShell())
                .isEmpty
        )
    }
}
