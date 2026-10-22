import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import SystemToolsPlugin

/// Offers a viewer that only records what it was asked to show.
private final class RecordingViewer: Plugin, ViewerService {
    let name = "Recording viewer"
    var texts: [(text: String, title: String)] = []

    func start(in kernel: Kernel) { kernel.services.register((any ViewerService).self, self) }
    func view(_: URL) {}
    func view(text: String, title: String) { texts.append((text, title)) }
}

/// The text of the multi-line field of the form shown last.
@MainActor private func shownText(_ ui: ScriptedInteraction) -> String? {
    for field in ui.forms.last ?? [] {
        if case .multilineText(let text) = field.kind { return text }
    }
    return nil
}

/// Lets the main thread run what was queued for it until `condition` holds; false when it still
/// does not after `Wait.ceiling`.
@MainActor private func settle(until condition: () -> Bool) async -> Bool {
    let end = Date(timeIntervalSinceNow: Wait.ceiling)
    while !condition() {
        guard Date() < end else { return false }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return true
}

/// What `pwd` printed, written the way the sandbox writes its paths.
private func folder(_ output: String?) -> String? {
    output.map { URL(fileURLWithPath: $0.trimmingCharacters(in: .newlines)).resolvingSymlinksInPath().path }
}

/// The system tools through their commands.
///
/// Nothing here starts another application; the only programs run are `echo`, `pwd`, `true`,
/// `false` and the like.
@MainActor @Suite struct SystemToolsCommandTests {
    let memory = MemoryFileSystem()
    let tools = SystemToolsPlugin(launchesApplications: false)
    let bench: TestBench
    let box: Sandbox

    var commands: CommandRegistry { bench.commands }
    var ui: ScriptedInteraction { bench.interaction }

    init() throws {
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

    @Test func aTypedLineRunsInTheSourceFolderAndItsOutputIsShown() {
        ui.formAnswers = [.accept, .accept]
        commands.perform(.runCommandLine, .text("echo hello"))
        #expect(shownText(ui) == "hello\n" && ui.log.last == "form: echo hello")
        commands.perform(.runCommandLine, .text("  pwd  "))
        #expect(folder(shownText(ui)) == box.url("A").path)
        #expect(tools.log == ["ran: echo hello", "ran: pwd"])
        #expect(bench.jobService.titles == ["Running: echo hello", "Running: pwd"])
        // A line typed with a blank in front is run and not remembered (see Review2ConfigASystemTools).
        #expect(bench.kernel.settings.value([String].self, forKey: "systemTools.history") == ["echo hello"])
        // Newest first, as the command line's history list shows them.
        commands.perform(.runCommandLine, .text("pwd"))
        #expect(bench.kernel.settings.value([String].self, forKey: "systemTools.history") == ["pwd", "echo hello"])
    }

    @Test func aFailingCommandReportsItsExitStatus() {
        commands.perform(.runCommandLine, .text("false"))
        #expect(ui.log.last == "form: false (exit status 1)")
        #expect(shownText(ui) == "The command ended with exit status 1 and wrote nothing.")
        // A command that succeeds silently shows nothing, unless output is always wanted.
        commands.perform(.runCommandLine, .text("true"))
        #expect(ui.forms.count == 1)
        bench.kernel.settings.set(1, forKey: SystemToolsPlugin.showOutputKey)
        commands.perform(.runCommandLine, .text("true"))
        #expect(ui.forms.count == 2 && shownText(ui) == "The command wrote nothing.")
        bench.kernel.settings.set(2, forKey: SystemToolsPlugin.showOutputKey)
        commands.perform(.runCommandLine, .text("echo unseen"))
        #expect(ui.forms.count == 2 && tools.log.last == "ran: echo unseen")
    }

    @Test func testsRunOnlyHarmlessLines() {
        for line in [
            "make install", "rm -rf x", "echo hi; rm x", "echo `id`", "echo $(id)", "echo hi > file", "echo hi &",
            "open -a Terminal",
            "TextEdit.app"
        ] {
            commands.perform(.runCommandLine, .text(line))
        }
        #expect(tools.log.allSatisfy { $0.hasPrefix("skipped: ") } && tools.log.count == 9)
        #expect(bench.jobService.titles.isEmpty && ui.forms.isEmpty)
        commands.perform(.runCommandLine, .text("   "))
        #expect(tools.log.count == 9)
    }

    @Test func outsideTheLocalDisksTheHomeFolderIsUsed() {
        bench.left.show(memory.url("/A"))
        commands.perform(.runCommandLine, .text("pwd"))
        #expect(folder(shownText(ui)) == FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path)
    }

    @Test func runCommandAsksForTheLine() {
        ui.promptAnswers = [.text("echo asked"), .accept, .cancel]
        commands.perform(SystemToolsCommands.runPrompt)
        #expect(shownText(ui) == "asked\n")
        // The last line is proposed again.
        commands.perform(.runCommandLine)
        #expect(
            ui.log.contains("prompt: Run command: [echo asked]") && tools.log == ["ran: echo asked", "ran: echo asked"]
        )
        commands.perform(SystemToolsCommands.runPrompt)
        #expect(tools.log.count == 2)
    }

    @Test func theViewerShowsTheOutputWhenThereIsOne() {
        let viewer = RecordingViewer()
        let tools = SystemToolsPlugin(launchesApplications: false)
        let bench = TestBench(
            plugins: [viewer, tools],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B")
        )
        bench.commands.perform(.runCommandLine, .text("printf '%s-%s' a b"))
        #expect(
            viewer.texts.map(\.text) == ["a-b"] && viewer.texts.first?.title == "printf '%s-%s' a b"
                && bench.interaction.forms.isEmpty
        )
    }

    // MARK: Terminal, system, volumes

    @Test func whatWouldStartApplicationsIsOnlyRecorded() async {
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

    @Test func systemInformationIsShownAsText() {
        ui.formAnswers = [.accept]
        commands.perform(SystemToolsCommands.systemInformation)
        let text = shownText(ui) ?? ""
        #expect(ui.log.last == "form: System Information")
        for label in [
            "Hardware", "CPU cores:", "Installed RAM:", "Software", "macOS version:", "Time since start:", "Volumes"
        ] {
            #expect(text.contains(label), "\(label)")
        }
    }

    @Test func aVolumeIsRenamedOnlyWithAValidName() {
        ui.promptAnswers = [.text("Work Disk"), .text("a/b"), .accept, .cancel]
        commands.perform(SystemToolsCommands.renameVolume)
        #expect(
            tools.log.count == 1 && tools.log[0].hasPrefix("rename-volume: ") && tools.log[0].hasSuffix(" -> Work Disk")
        )
        #expect(ui.log.contains { $0.hasPrefix("prompt: Set volume label - /") })
        commands.perform(SystemToolsCommands.renameVolume)
        #expect(ui.log.last == "inform: The volume cannot be named a/b!")
        // The same name and Cancel change nothing.
        commands.perform(SystemToolsCommands.renameVolume)
        commands.perform(SystemToolsCommands.renameVolume)
        #expect(tools.log.count == 1)
    }

    @Test func theSystemVolumeCannotBeEjected() {
        commands.perform(SystemToolsCommands.ejectVolume)
        #expect(ui.log.last?.hasSuffix("cannot be ejected.") == true && tools.log.isEmpty)
    }

    @Test func openWithListsApplications() {
        bench.left.moveCursor(toName: "one.txt")
        ui.formAnswers = [.accept]
        commands.perform(SystemToolsCommands.openWith)
        // Which applications there are depends on the Mac; either one was picked or none is known.
        let picked = tools.log.last?.hasPrefix("open-with: ") == true && tools.log.last?.hasSuffix(" one.txt") == true
        #expect(picked || ui.log.last == "inform: No application is known to open one.txt.")
    }

    // MARK: Printing

    @Test func theFileListGoesToThePrinterAsPages() {
        bench.left.show(memory.url("/A"))
        commands.perform(.selectAll)
        ui.formAnswers = [.values(["lines": .text("5"), "header": .text("")])]
        commands.perform(SystemToolsCommands.printList)
        // Three rows, an empty line and the totals on pages of five lines.
        #expect(tools.log == ["print: 1 pages"] && ui.log.last == "form: Print directory")
        // The dialog remembers what was entered.
        ui.formAnswers = [.cancel]
        commands.perform(SystemToolsCommands.printList)
        #expect(ui.forms.last?.first?.initialValue == .text("") && ui.forms.last?[2].initialValue == .text("5"))
    }

    @Test func theFileListCanBeShownAsText() {
        bench.left.show(memory.url("/A"))
        bench.left.moveCursor(toName: "one.txt")
        ui.formAnswers = [.values(["output": .index(2)]), .accept]
        commands.perform(SystemToolsCommands.printList)
        let date = Format.date(Date(timeIntervalSince1970: 1_000_000))
        #expect(shownText(ui) == "mem:/A - Page 1/1\n\none.txt  3  \(date)  rw-r--r--\n\n0 k in 1 files")
        // Brief view prints the names only; on `[..]` the whole list is meant.
        bench.left.viewMode = .brief
        bench.left.model.moveCursor(to: 0)
        ui.formAnswers = [.accept, .accept]
        commands.perform(SystemToolsCommands.printList)
        #expect(shownText(ui) == "mem:/A - Page 1/1\n\ndocs/\none.txt\ntwo.txt\n\n2 k in 2 files, 1 folders")
    }

    @Test func theListWithSubfoldersAsksForDepthAndMask() {
        bench.left.show(memory.url("/A"))
        commands.perform(.selectAll)
        ui.promptAnswers = [.text("-1"), .text("*.txt | two.*"), .text("list.txt")]
        ui.formAnswers = [.values(["output": .index(1), "details": .flag(false), "header": .text("%d")])]
        commands.perform(SystemToolsCommands.printListWithSubfolders)
        #expect(
            memory.contents("/A/list.txt")
                == "mem:/A\n\ndocs/\ndocs/deep/\ndocs/deep/far.txt\ndocs/in.txt\none.txt\n\n0 k in 3 files, 2 folders"
        )
        #expect(bench.left.model.cursorItem?.name == "list.txt" && tools.log == ["list-file: mem:/A/list.txt"])

        // Depth 1 enters the selected folders but not their subfolders; an existing file is asked about.
        commands.perform(.unselectAll)
        bench.left.moveCursor(toName: "docs")
        ui.promptAnswers = [.text("1"), .accept, .text("list.txt")]
        ui.formAnswers = [.values(["details": .flag(false)])]
        ui.choiceAnswers = [0]
        commands.perform(SystemToolsCommands.printListWithSubfolders)
        #expect(
            memory.contents("/A/list.txt") == "mem:/A\n\ndocs/\ndocs/deep/\ndocs/in.txt\n\n0 k in 1 files, 2 folders"
        )
        ui.promptAnswers = [.text("many")]
        commands.perform(SystemToolsCommands.printListWithSubfolders)
        #expect(ui.log.last == "inform: many is not a number.")
    }

    @Test func printingFileContentsIsConfirmedFirst() {
        bench.left.moveCursor(toName: "one.txt")
        ui.choiceAnswers = [1, 0]
        commands.perform(SystemToolsCommands.printFile)
        #expect(tools.log.isEmpty)
        commands.perform(SystemToolsCommands.printFile)
        #expect(tools.log == ["print-file: one.txt"])
        bench.left.model.moveCursor(to: 0)
        #expect(!commands.isEnabled(SystemToolsCommands.printFile))
    }

    // MARK: Registration

    @Test func registration() {
        let menus = bench.kernel.menus
        let inMenus = menus.menus.flatMap(\.items).compactMap { $0 } + menus.contextMenu(onItem: true).compactMap { $0 }
        #expect(
            inMenus.allSatisfy { commands[$0] != nil }
                && Set(menus.menus.flatMap(\.items).compactMap { $0 }).count
                    == menus.menus.flatMap(\.items).compactMap { $0 }.count
        )
        #expect(bench.kernel.keyClashes.isEmpty)
        #expect(
            menus.menus.first { $0.title == "Commands" }?.items
                == [
                    SystemToolsCommands.systemInformation, SystemToolsCommands.renameVolume,
                    SystemToolsCommands.ejectVolume,
                    SystemToolsCommands.openTerminal, nil, SystemToolsCommands.runPrompt
                ]
        )
        let buttons = bench.kernel.toolbar.defaultLayout.compactMap { $0?.command }
        #expect(
            buttons.filter { [SystemToolsCommands.openTerminal, SystemToolsCommands.systemInformation].contains($0) }
                == [SystemToolsCommands.openTerminal, SystemToolsCommands.systemInformation]
        )
        #expect(bench.kernel.preferences.pages.map(\.title).contains("System Tools"))
        #expect(
            bench.kernel.keyBindings.command(for: .f(9, .control)) == SystemToolsCommands.printFile
                && bench.kernel.keyBindings.command(for: .f(4, .option)) == SystemToolsCommands.quit
        )
        for id in [
            "afm_RunCommandLine", "cm_ExecuteDOS", "cm_SysInfo", "cm_VolumeId", "cm_PrintDir", "cm_PrintDirSub",
            "cm_PrintFile",
            "cm_Associate", "cm_Exit", "cm_Minimize"
        ] {
            #expect(commands[CommandID(rawValue: id)] != nil, "\(id)")
        }
    }
}

/// The pure parts: reading a typed line, running a child process, formats and pages.
@Suite struct SystemToolsTypes {
    // MARK: Typed lines

    @Test func aLineIsTakenApart() throws {
        let plain = try #require(TypedCommand("  ls -la  "))
        #expect(plain.command == "ls -la" && plain.firstWord == "ls" && plain.arguments == "-la" && !plain.isDetached)
        let detached = try #require(TypedCommand("open . &"))
        #expect(detached.command == "open ." && detached.isDetached)
        #expect(TypedCommand("make && make install &&")?.isDetached == false)
        #expect(TypedCommand("") == nil && TypedCommand("  &") == nil)
        #expect(TypedCommand("\"My Tool.app\" file.txt")?.firstWord == "My Tool.app")
        #expect(TypedCommand("My\\ Tool --flag")?.firstWord == "My Tool")
        #expect(TypedCommand("'it''s' x")?.firstWord == "its")
        #expect(TypedCommand.split("a   'b c'  d").rest == "'b c'  d")
    }

    @Test func applicationsAreFoundByNameOrPath() throws {
        let box = try Sandbox()
        try box.folder("Apps/Tool.app")
        try box.file("Apps/script.app", "not a bundle")
        let folders = [box.url("Apps")]
        #expect(
            TypedCommand("Tool")?.application(relativeTo: box.root, searching: folders)?.lastPathComponent == "Tool.app"
        )
        #expect(
            TypedCommand("Tool.app notes.txt")?.application(relativeTo: box.root, searching: folders)?.lastPathComponent
                == "Tool.app"
        )
        #expect(
            TypedCommand("Apps/Tool.app")?.application(relativeTo: box.root, searching: [])?.path
                == box.url("Apps/Tool.app").path
        )
        // A name with arguments is a program for the shell, and a file is not an application.
        #expect(TypedCommand("Tool --help")?.application(relativeTo: box.root, searching: folders) == nil)
        #expect(TypedCommand("script")?.application(relativeTo: box.root, searching: folders) == nil)
        #expect(TypedCommand("ls")?.application(relativeTo: box.root, searching: folders) == nil)
        #expect(
            SystemTools.files(in: "a.txt 'b c.txt' /tmp/d", relativeTo: box.root).map(\.path)
                == [box.url("a.txt").path, box.url("b c.txt").path, "/tmp/d"]
        )
    }

    @Test func onlyPlainHarmlessLinesAreHarmless() throws {
        #expect(SystemTools.isHarmless(try #require(TypedCommand("echo a b"))))
        #expect(!SystemTools.isHarmless(try #require(TypedCommand("echo a | sh"))))
        #expect(!SystemTools.isHarmless(try #require(TypedCommand("sh -c 'echo a'"))))
    }

    @Test func theHistoryKeepsEachLineOnceNewestFirst() {
        var history: [String] = []
        for line in ["a", "b", "a"] { history = CommandHistory.adding(line, to: history) }
        #expect(history == ["a", "b"])
        for number in 0..<30 { history = CommandHistory.adding("line \(number)", to: history) }
        #expect(history.count == CommandHistory.limit && history.first == "line 29")
    }

    // MARK: Child processes

    private func sh(_ script: String, collects: Bool = true) -> ProcessRunner {
        ProcessRunner(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            directory: nil,
            collectsOutput: collects
        )
    }

    @Test func outputAndStatusAreCollected() {
        let outcome = sh("echo out; echo err 1>&2; exit 3").run(cancellation: CancellationFlag())
        #expect(
            outcome.output == "out\nerr\n" && outcome.status == 3 && outcome.failure == nil && !outcome.wasCancelled
        )
    }

    @Test func aLotOfOutputDoesNotBlockTheChild() {
        // Far more than a pipe holds: the child would wait for ever if nobody read.
        var reported = 0
        let outcome = sh("head -c 3000000 /dev/zero | tr '\\0' x")
            .run(cancellation: CancellationFlag()) {
                reported = max(reported, $0)
            }
        #expect(outcome.output.utf8.count == 3_000_000 && outcome.status == 0 && !outcome.isTruncated)
    }

    @Test func cancellingEndsTheChild() {
        let cancellation = CancellationFlag()
        Thread {
            Thread.sleep(forTimeInterval: 0.2)
            cancellation.cancel()
        }
        .start()
        let started = Date()
        let outcome = sh("echo before; sleep 30").run(cancellation: cancellation)
        #expect(outcome.wasCancelled && Date().timeIntervalSince(started) < 10)
        #expect(outcome.output == "before\n")
    }

    @Test func aProgramThatDoesNotExistIsAFailure() {
        let runner = ProcessRunner(
            executable: URL(fileURLWithPath: "/nonexistent/program"),
            arguments: [],
            directory: nil
        )
        #expect(runner.run(cancellation: CancellationFlag()).failure != nil)
    }

    @Test func aDetachedCommandIsNotReadFrom() {
        let outcome = sh("echo unseen", collects: false).run(cancellation: CancellationFlag())
        #expect(outcome.output.isEmpty && outcome.status == 0)
    }

    @Test func severalChildrenRunAtOnce() {
        let outputs = Parallel.map(Array(0..<8)) { number in
            sh("echo \(number)").run(cancellation: CancellationFlag()).output
        }
        #expect(outputs == (0..<8).map { "\($0)\n" })
    }

    // MARK: System information

    @Test func informationIsLaidOutInAlignedColumns() {
        let information = SystemInformation(sections: [
            .init(
                title: "Hardware",
                rows: [.init(label: "Model", value: "Mac"), .init(label: "CPU cores", value: "8")]
            ),
            .init(title: "Volumes", rows: [.init(label: "Disk", value: "/: 1 k of 2 k free")])
        ])
        #expect(
            information.text == "Hardware\n  Model:     Mac\n  CPU cores: 8\n\nVolumes\n  Disk:      /: 1 k of 2 k free"
        )
    }

    @Test func formatsFollowTheDialog() {
        #expect(SystemInformation.memory(128 << 30) == "131,072 M (128 G)")
        #expect(SystemInformation.memory(UInt64(1.5 * Double(1 << 30))) == "1,536 M (1.5 G)")
        #expect(SystemInformation.memory(512 << 20) == "512 M")
        #expect(SystemInformation.uptime(130 * 3_600 + 19 * 60 + 21) == "130h 19m 21s")
        #expect(SystemInformation.space(free: 2_048, total: 4_096 * 1_024) == "2 k of 4,096 k free")
        #expect(SystemInformation.space(free: nil, total: 1) == "size unknown")
    }

    @Test func theSystemAnswers() throws {
        let gathered = SystemInformation.gather(displays: ["1x1"], cancellation: CancellationFlag(), asking: .system)
        let information = try #require(gathered)
        #expect(information.sections.map(\.title) == ["Hardware", "Software", "Volumes"])
        #expect(information.sections[0].rows.contains { $0.label == "Display" && $0.value == "1x1" })
        #expect(
            (SystemInformation.systemNumber("hw.ncpu") ?? 0) > 0
                && SystemInformation.systemText("kern.ostype") == "Darwin"
        )
        #expect(SystemInformation.systemText("no.such.value") == nil && !information.sections[2].rows.isEmpty)
    }

    @Test func volumeNamesAreChecked() {
        #expect(VolumeName.problem(with: "Work Disk 2") == nil && VolumeName.problem(with: "Диск") == nil)
        #expect(
            VolumeName.problem(with: "") != nil && VolumeName.problem(with: "a/b") != nil
                && VolumeName.problem(with: "a:b") != nil
        )
        #expect(
            VolumeName.problem(with: ".hidden") != nil
                && VolumeName.problem(with: String(repeating: "x", count: 300)) != nil
        )
    }

    // MARK: File lists

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func headerPlaceholdersAreFilledIn() {
        #expect(
            DirectoryListFormatter.expand("%d - Page %p/%t", directory: "/tmp/A", page: 2, pages: 3, now: now)
                == "/tmp/A - Page 2/3"
        )
        #expect(DirectoryListFormatter.expand("100%% %x %", directory: "", page: 1, pages: 1, now: now) == "100% %x %")
        let stamp = DirectoryListFormatter.expand("%D|%T", directory: "", page: 1, pages: 1, now: now)
            .split(
                separator: "|"
            )
        #expect(stamp.count == 2 && stamp.allSatisfy { !$0.isEmpty && !$0.contains("%") })
    }

    @Test func rowsAreAlignedAndTheFooterCounts() {
        let rows = [
            ListRow(name: "images", isFolder: true, modified: now, permissions: 0o755),
            ListRow(name: "green.png", isFolder: false, size: 782, modified: now),
            ListRow(name: "a", isFolder: false, size: 1_234_567, modified: now)
        ]
        let date = Format.date(now)
        #expect(
            DirectoryListFormatter().body(rows) == [
                "images/        <DIR>  \(date)  rwxr-xr-x",
                "green.png        782  \(date)  rw-r--r--",
                "a          1,234,567  \(date)  rw-r--r--",
                "", "1,206 k in 2 files, 1 folders"
            ]
        )
        #expect(DirectoryListFormatter.footer([rows[1]]) == "1 k in 1 files")
        var brief = DirectoryListFormatter()
        brief.isDetailed = false
        #expect(brief.body(rows).prefix(3) == ["images/", "green.png", "a"])
    }

    @Test func longListsAreSplitIntoPagesWithAHeaderEach() {
        let rows = (1...10).map { ListRow(name: "file\($0)", isFolder: false, size: 1) }
        var formatter = DirectoryListFormatter()
        formatter.isDetailed = false
        formatter.linesPerPage = 6
        // Ten rows, an empty line and the footer: twelve lines in pages of four below the header.
        let pages = formatter.pages(directory: "/A", rows: rows, now: now)
        #expect(pages.count == 3 && pages[0] == ["/A - Page 1/3", "", "file1", "file2", "file3", "file4"])
        #expect(pages[2] == ["/A - Page 3/3", "", "file9", "file10", "", "0 k in 10 files"])
        #expect(formatter.text(directory: "/A", rows: rows, now: now).components(separatedBy: "\u{0C}").count == 3)
        formatter.header = ""
        #expect(formatter.pages(directory: "/A", rows: rows, now: now).map(\.count) == [6, 6])
        #expect(formatter.pages(directory: "/A", rows: [], now: now) == [["", "0 k in 0 files"]])
    }

    @Test func masksIncludeAndExclude() {
        #expect(ListMask("*.doc *.txt").matches("a.txt") && !ListMask("*.doc *.txt").matches("a.png"))
        #expect(ListMask("*.* | *.bak *.~*").matches("a.txt") && !ListMask("*.* | *.bak *.~*").matches("a.bak"))
        #expect(
            ListMask("|*.exe").matches("a.txt") && !ListMask("|*.exe").matches("a.exe")
                && ListMask("").matches("anything")
        )
    }

    @Test func subfoldersAreCollectedToTheGivenDepth() {
        let (fileSystems, memory) = makeFileSystems()
        for path in ["/A/b.txt", "/A/a.md", "/A/sub/c.txt", "/A/sub/deeper/d.txt", "/A/.hidden/e.txt"] {
            memory.addFile(path)
        }
        func names(depth: Int, mask: String = "*.*", hidden: Bool = false) -> [String] {
            let items = (try? memory.list(memory.url("/A"), showHidden: hidden)) ?? []
            return ListCollector(
                fileSystems: fileSystems,
                showHidden: hidden,
                mask: ListMask(mask),
                depth: depth,
                cancellation: CancellationFlag()
            )
            .rows(of: items).map(\.name)
        }
        #expect(names(depth: 0) == ["a.md", "b.txt", "sub"])
        #expect(names(depth: 1) == ["a.md", "b.txt", "sub", "sub/c.txt", "sub/deeper"])
        #expect(names(depth: -1, mask: "*.txt") == ["b.txt", "sub", "sub/c.txt", "sub/deeper", "sub/deeper/d.txt"])
        #expect(names(depth: -1, hidden: true).contains(".hidden/e.txt"))
        let cancelled = CancellationFlag()
        cancelled.cancel()
        let items = (try? memory.list(memory.url("/A"), showHidden: false)) ?? []
        #expect(
            ListCollector(
                fileSystems: fileSystems,
                showHidden: false,
                mask: ListMask("*"),
                depth: -1,
                cancellation: cancelled
            )
            .rows(of: items).map(\.name) == ["a.md", "b.txt", "sub"]
        )
    }
}
