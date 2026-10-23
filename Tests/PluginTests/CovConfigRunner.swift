import AFMKernel
import Foundation
import LocalFileSystemPlugin
import NavigationPlugin
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// The runner of user commands at the corners the other suites leave: list files, chains that
/// are stopped, the start of processes and the lines that open applications.
@MainActor
@Suite
internal struct CovConfigRunner {
    private let box: Sandbox
    private let memory = MemoryFileSystem()
    private let bench: TestBench
    /// What the probe commands were given, in order.
    private let probes: CovConfigProbes

    /// A fresh bench for every test.
    internal init() throws {
        box = try Sandbox()
        try box.folder("A")
        memory.addFile("/M/one.txt", "1")
        bench = TestBench(
            plugins: [NavigationPlugin()],
            fileSystems: [LocalFileSystem(), memory],
            left: box.url("A"),
            right: memory.url("/M")
        )
        // `em_plain` is a command of the program with a user command's prefix.
        probes = CovConfigProbes(["cov_probe", "cov_second", "em_plain"], in: bench.commands)
    }

    private func runner(launches: Bool = false, background: DispatchQueue? = nil, lists: URL? = nil) -> CommandRunner {
        CommandRunner(
            kernel: bench.kernel,
            launchesApplications: launches,
            background: background,
            listFolder: lists ?? box.url("lists")
        )
    }

    /// Marks `count` new files in the right panel.
    private func markMany(_ count: Int) {
        for index in 0..<count { memory.addFile("/M/many/f\(index).txt", "") }
        bench.right.show(memory.url("/M/many"), focus: nil, history: .keep, completion: nil)
        bench.right.model.select(mask: "*")
    }

    /// The folders of earlier runs go when their process is gone; this one's, a running one's and
    /// folders of other names stay.
    @Test
    internal func staleListFoldersOfEndedRunsGo() throws {
        let parent = try box.folder("parent")
        for name in ["notes", "\(getpid())", "1", "2147483646"] { try box.folder("parent/\(name)") }
        CommandRunner.removeStaleListFolders(in: parent)
        let left = try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted()
        #expect(left == ["1", "\(getpid())", "notes"].sorted())
    }

    /// A list file of a command of the program goes once its time is up.
    @Test
    internal func aListFileGoesWhenItsTimeIsUp() async throws {
        let runner = runner(background: DispatchQueue(label: "cov.runner"))
        runner.listGrace = 0
        try box.file("A/x.txt")
        bench.left.reload(focus: "x.txt", quietly: true, completion: nil)
        runner.run(CommandAction(command: "cov_probe", parameters: "%L"), title: "List")
        #expect(await AppWait.until { probes.seen.count == 1 })
        let list = try #require(probes.seen.first?.dropFirst("cov_probe:".count))
        #expect(await AppWait.until { !FileManager.default.fileExists(atPath: String(list)) })
    }

    /// A run stopped while its list was written does not start; the next one does.
    @Test
    internal func aRunStoppedWhileItsListIsWrittenDoesNotStart() async throws {
        let runner = runner(background: DispatchQueue(label: "cov.runner"))
        try box.file("A/x.txt")
        bench.left.reload(focus: "x.txt", quietly: true, completion: nil)
        runner.run(CommandAction(command: "cov_probe", parameters: "%L"), title: "First")
        runner.stopWaiting()
        runner.run(CommandAction(command: "cov_second", parameters: "%L"), title: "Second")
        #expect(await AppWait.until { !probes.seen.isEmpty })
        #expect(probes.seen.count == 1 && probes.seen.first?.hasPrefix("cov_second:") == true)
    }

    /// A list that cannot be written is reported, and the command does not run.
    @Test
    internal func aListThatCannotBeWrittenIsReported() throws {
        let blocker = try box.file("blocker", "a file where the folder should be")
        let runner = runner(lists: blocker.appendingPathComponent("lists"))
        try box.file("A/x.txt")
        bench.left.reload(focus: "x.txt", quietly: true, completion: nil)
        runner.run(CommandAction(command: "cov_probe", parameters: "%L"), title: "List")
        #expect(probes.seen.isEmpty)
        #expect(bench.interaction.log.first?.contains("The list of files for “List” could not be written") == true)
    }

    /// The marked names of the right panel are gathered away from the main thread when there are many.
    @Test
    internal func manyMarkedNamesOfTheOtherPanelAreGatheredInTheBackground() async {
        markMany(CommandRunner.backgroundSelectionThreshold)
        let runner = runner(background: DispatchQueue(label: "cov.runner"))
        runner.run(CommandAction(command: "cov_probe", parameters: "%R1"), title: "Many")
        #expect(await AppWait.until { probes.seen == ["cov_probe:f0.txt"] })
    }

    /// A run stopped while its names were gathered does not start; the next one does.
    @Test
    internal func aRunStoppedWhileItsNamesAreGatheredDoesNotStart() async {
        markMany(CommandRunner.backgroundSelectionThreshold)
        let runner = runner(background: DispatchQueue(label: "cov.runner"))
        runner.run(CommandAction(command: "cov_probe", parameters: "%R1"), title: "First")
        runner.stopWaiting()
        runner.run(CommandAction(command: "cov_second", parameters: "%R1"), title: "Second")
        #expect(await AppWait.until { !probes.seen.isEmpty })
        #expect(probes.seen == ["cov_second:f0.txt"])
    }

    /// A wait that was stopped does not go on; a later chain does.
    @Test
    internal func aStoppedWaitDoesNotGoOn() async {
        let runner = runner()
        runner.run(CommandAction(command: "cm_wait 20, cov_probe"), title: "First")
        #expect(runner.isWaiting)
        runner.stopWaiting()
        runner.run(CommandAction(command: "cm_wait 200, cov_second"), title: "Second")
        #expect(await AppWait.until { !probes.seen.isEmpty })
        #expect(probes.seen == ["cov_second:"])
    }

    /// An empty command does nothing; a command of the program with a user command's name runs
    /// as a command, and an empty `cd` is passed by.
    @Test
    internal func emptyAndUnknownStepsDoNothing() {
        let runner = runner()
        var finished = 0
        runner.run(CommandAction(), arguments: "", as: nil, title: "Nothing") { finished += 1 }
        #expect(finished == 0 && bench.interaction.log.isEmpty)
        runner.userCommand = { _ in nil }
        let odd = CommandAction(command: "em_plain, em_plain x, cd, cov_probe")
        runner.run(odd, arguments: "", as: nil, title: "Odd") { finished += 1 }
        #expect(finished == 1 && probes.seen == ["em_plain:", "em_plain:x", "cov_probe:"])
        #expect(bench.left.model.directory == box.url("A"))
    }

    /// A program is started in the home folder when the source panel is not on this Mac's disks;
    /// a file that is no program says so, and so does a start folder that is a file.
    @Test
    internal func startedProgramsReportWhatWentWrong() async throws {
        bench.right.focus()
        let runner = runner(launches: true)
        let log = { bench.interaction.log }
        runner.run(CommandAction(command: "/etc/hosts"), title: "Hosts")
        #expect(await AppWait.until { log().count == 1 })
        #expect(log().first == "inform: “/etc/hosts” cannot be started!")
        let file = try box.file("plain.txt")
        runner.run(CommandAction(command: "true", startPath: file.path), title: "In a file")
        #expect(await AppWait.until { log().count == 2 })
        #expect(log().last == "inform: “true” cannot be started!")
    }

    /// A line too long for the system is refused when it is started, and so is a long line
    /// that a shell could not be given safely.
    @Test
    internal func longLinesAreCheckedWhereTheyStart() async {
        let name = String(repeating: "n", count: 240)
        for index in 0..<4_500 { memory.addFile("/M/long/\(name)\(index)", "") }
        bench.right.show(memory.url("/M/long"), focus: nil, history: .keep, completion: nil)
        bench.right.model.select(mask: "*")
        bench.right.focus()
        let runner = runner(launches: true)
        let log = { bench.interaction.log }
        runner.run(CommandAction(command: "echo", parameters: "%S"), title: "Long")
        #expect(await AppWait.until { log().count == 1 })
        #expect(log().first == "inform: “echo” cannot be started!")
        runner.run(CommandAction(command: "echo $'", parameters: "%S"), title: "Refused")
        #expect(await AppWait.until { log().count == 2 })
        #expect(log().last == "inform: “echo” cannot be started!")
    }

    /// A panel that shows real files under another path (a branch view) gives their full paths
    /// and no path of its own.
    @Test
    internal func aBranchViewGivesFullPaths() {
        let file = box.url("A/deep/x.txt")
        let listing = Listing(
            directory: memory.url("/M"),
            items: [FileItem(url: file, name: "deep/x.txt")],
            parent: nil,
            root: memory.url("/")
        )
        bench.left.model.show(listing, focus: "deep/x.txt")
        bench.left.focus()
        runner().run(CommandAction(command: "cov_probe", parameters: "[%P] %N"), title: "Branch")
        #expect(probes.seen == ["cov_probe:[] \(file.path)"])
    }

    /// Lines whose program is an application are opened with `open`; others are left as they are.
    @Test
    internal func applicationsAreOpenedWithOpen() {
        #expect(CommandRunner.applicationLine(for: "Calculator.app")?.hasPrefix("/usr/bin/open -a ") == true)
        #expect(CommandRunner.applicationLine(for: "NoSuchApplicationHere.app") == nil)
        let bare = CommandRunner.applicationLine(for: "Calculator")
        #expect(bare?.hasPrefix("if command -v Calculator") == true && bare?.contains("open -a Calculator") == true)
        let withValue: [ExpandedPiece] = [.text("Calculator "), .value("x")]
        #expect(CommandRunner.startLine(for: withValue) == withValue)
        #expect(CommandRunner.applicationLine(for: "-n") == nil && CommandRunner.applicationLine(for: "") == nil)
        #expect(CommandRunner.applicationLine(for: "./Calculator") == nil)
    }
}
