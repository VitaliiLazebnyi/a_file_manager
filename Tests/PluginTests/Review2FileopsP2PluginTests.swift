import AFMContracts
import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import ClipboardPlugin
@testable import FileOperationsPlugin
@testable import FilePropertiesPlugin

// Second pass of review round 2 for the commands of the file-operation plugins, the clipboard
// and the file properties: the fixes of the first pass that had no test of their own (F003,
// F008, F009, F010, F027, F037, F038, F039, F040, F070), the default buttons of the questions
// that destroy something (F055), what the viewer and tools areas asked for (V070, T024, T047)
// and the comment file's reproducers from fuzzing (G002).

/// Shows no dialogs: keeps every question with the button Return would press, and answers
/// the way `answer` says (by default: Return).
final class P2RecordingUI: UserInteraction {
    struct Question {
        let message: String
        let buttons: [String]
        /// The button Return presses; -1 when the question was asked without saying so.
        let defaultButton: Int?
    }

    private(set) var questions: [Question] = []
    private(set) var messages: [String] = []
    private(set) var forms: [String] = []
    /// The index of the chosen button; nil presses Return.
    var answer: (Question) -> Int? = { _ in nil }
    var formAnswer: ([FormField]) -> FormValues? = { _ in nil }
    var promptAnswer: (String) -> String? = { _ in nil }

    func prompt(_: String, value: String, detail _: String) -> String? { promptAnswer(value) }
    func choose(_ message: String, detail _: String, buttons: [String], style _: QuestionStyle) -> Int {
        let question = Question(message: message, buttons: buttons, defaultButton: -1)
        questions.append(question)
        return answer(question) ?? 0
    }
    func choose(_ message: String, detail _: String, buttons: [String], style _: QuestionStyle, defaultButton: Int?)
        -> Int
    {
        let question = Question(message: message, buttons: buttons, defaultButton: defaultButton)
        questions.append(question)
        // Return presses the default button; without one, nothing happens until Esc: the last.
        return answer(question) ?? defaultButton ?? buttons.count - 1
    }
    func inform(_ message: String, detail _: String, style _: QuestionStyle) { messages.append(message) }
    func form(_ title: String, detail _: String, fields: [FormField], buttons _: [String]) -> FormValues? {
        forms.append(title)
        return formAnswer(fields)
    }
}

/// Runs the work of a job at once, on the calling thread, and keeps its completion until
/// `deliver()`: the time in which the user goes on working while a job is under way.
final class P2DeferredJobs: JobService {
    private(set) var isBusy = false
    private var pending: [() -> Void] = []
    private(set) var titles: [String] = []
    /// Called after each job's work, before its completion is kept.
    var afterWork: (() -> Void)?

    final class Monitor: JobMonitor, Sendable {
        let cancellation = CancellationFlag()
        func report(_: JobProgress) {}
        func ask<Answer: Sendable>(_ question: @MainActor @Sendable () -> Answer) -> Answer {
            // The work runs on the calling thread, the main one.
            MainActor.assumeIsolated(question)
        }
    }

    func run<Result: Sendable>(
        title: String,
        work: @escaping @Sendable (any JobMonitor) -> Result,
        completion: @escaping @MainActor (Result) -> Void
    ) {
        titles.append(title)
        let result = work(Monitor())
        afterWork?()
        pending.append { completion(result) }
    }

    /// Runs the completions that wait, and those they start.
    func deliver() {
        while !pending.isEmpty { pending.removeFirst()() }
    }
}

/// A kernel with fake panels, like `TestBench`, with the user interface and the job service
/// a test brings.
final class P2Bench: ShellServices {
    let kernel: Kernel
    let panelSet: FakePanelSet
    let jobs: any JobService

    var panels: any PanelSet { panelSet }
    var left: FakePanel { panelSet.leftPanel }
    var right: FakePanel { panelSet.rightPanel }
    var commands: CommandRegistry { kernel.commands }

    init(
        plugins: [any Plugin],
        fileSystems: [any FileSystemProvider],
        left: URL,
        right: URL,
        ui: any UserInteraction,
        jobs: any JobService = ImmediateJobService(),
        settings: any SettingsStore = MemorySettings()
    ) {
        kernel = Kernel(productName: "Test", settings: settings, interaction: ui)
        fileSystems.forEach(kernel.fileSystems.register)
        kernel.load(plugins)
        panelSet = FakePanelSet(
            left: FakePanel(showing: left, fileSystems: kernel.fileSystems),
            right: FakePanel(showing: right, fileSystems: kernel.fileSystems)
        )
        self.jobs = jobs
        kernel.attach(self)
    }
}

// MARK: - File operations

@MainActor @Suite struct Review2FileopsP2Commands {
    let box: Sandbox
    let memory = MemoryFileSystem()
    let ui = P2RecordingUI()

    init() throws {
        box = try Sandbox()
        memory.addFile("/A/one.txt", "1")
        memory.addFile("/A/two.txt", "2")
        memory.addFile("/A/three.txt", "3")
        memory.addDirectory("/B")
    }

    private func bench(
        _ plugins: [any Plugin] = [FileOperationsPlugin(), SelectionPlugin()],
        left: URL? = nil,
        settings: any SettingsStore = MemorySettings()
    )
        -> P2Bench
    {
        P2Bench(
            plugins: plugins,
            fileSystems: [LocalFileSystem(), memory],
            left: left ?? memory.url("/A"),
            right: memory.url("/B"),
            ui: ui,
            settings: settings
        )
    }

    // F055: Return must not delete for good.
    @Test func returnDoesNotConfirmADeletionThatCannotBeUndone() throws {
        let bench = bench()
        bench.left.moveCursor(toName: "one.txt")
        // Nobody chooses a button: Return.
        #expect(bench.commands.perform(.deleteDirectly))
        let question = try #require(ui.questions.last)
        #expect(
            question.message == "Permanently delete" && question.buttons == ["Yes", "No"] && question.defaultButton == 1
        )
        #expect(memory.exists("/A/one.txt"))
        // Chosen, it is done.
        ui.answer = { _ in 0 }
        #expect(bench.commands.perform(.deleteDirectly) && !memory.exists("/A/one.txt"))
    }

    @Test func whatGoesToTheTrashIsStillConfirmedWithReturn() throws {
        try box.file("d/keep.txt", "kept")
        let bench = bench(left: box.url("d"))
        bench.left.moveCursor(toName: "keep.txt")
        // Answered with No all the same: the test moves nothing to the user's Trash.
        ui.answer = { _ in 1 }
        #expect(bench.commands.perform(.delete))
        let question = try #require(ui.questions.last)
        #expect(question.message == "Test" && question.defaultButton == 0 && box.exists("d/keep.txt"))
    }

    @Test func theQuestionsOfAJobThatDestroySomethingDefaultToSkip() {
        let fileSystems = FileSystemRegistry()
        fileSystems.register(memory)
        let bridge = JobBridge(monitor: P2DeferredJobs.Monitor(), ui: ui, fileSystems: fileSystems)
        let job = FileJob(kind: .copy, sources: [], fileSystems: fileSystems)
        let old = FileItem(url: memory.url("/B/one.txt"), name: "one.txt", stat: .init(size: 1))
        let new = FileItem(url: memory.url("/A/one.txt"), name: "one.txt", stat: .init(size: 2))
        // Each is answered with Return.
        #expect(bridge.job(job, conflictAt: old, source: new) == .skip)
        #expect(ui.questions.last?.message == "Overwrite:" && ui.questions.last?.defaultButton == 2)
        #expect(bridge.job(job, confirmDeleteNonEmpty: memory.url("/A")) == .skip)
        #expect(
            ui.questions.last?.buttons == ["Delete", "All", "Skip", "Cancel"] && ui.questions.last?.defaultButton == 2
        )
        for reason in [ProtectionQuestion.Reason.readOnly, .hidden, .locked, .noTrash] {
            #expect(
                bridge.job(job, confirm: ProtectionQuestion(reason: reason, purpose: .delete, item: old)) == .skip
            )
            #expect(ui.questions.last?.defaultButton == 2)
        }
        #expect(
            bridge.job(job, confirm: ProtectionQuestion(reason: .readOnly, purpose: .overwrite, item: old)) == .skip
        )
        #expect(
            bridge.job(job, crossVolumeAt: old, purpose: .delete) == .skip && ui.questions.last?.defaultButton == 0
        )
        // Every question of the bridge that can destroy said which button Return presses.
        #expect(ui.questions.allSatisfy { $0.defaultButton != -1 })
        // A chosen answer is still the answer.
        ui.answer = { _ in 0 }
        #expect(bridge.job(job, conflictAt: old, source: new) == .overwrite)
        #expect(bridge.job(job, confirmDeleteNonEmpty: memory.url("/A")) == .delete)
    }

    // F008, F025: what a command works on, and what it takes the marks off with.
    @Test func theOperandsAreCountedWithoutMakingTheListOfThem() throws {
        let bench = bench()
        let model = bench.left.model
        model.moveCursor(to: try #require(model.row(ofName: "two.txt")))
        var picked = FileOperations.Picked(model)
        #expect(picked.count == 1 && picked.first?.name == "two.txt" && picked.single?.name == "two.txt")
        #expect(OperationText.heading("Copy", count: picked.count, single: picked.single) == "Copy \"two.txt\" to")
        model.setSelection(names: ["three.txt", "one.txt"])
        picked = FileOperations.Picked(model)
        // The first in the order of the list, whatever the order of marking was.
        #expect(picked.count == 2 && picked.first?.name == "one.txt" && picked.single == nil)
        #expect(picked.items().map(\.name) == ["one.txt", "three.txt"])
        #expect(OperationText.heading("Copy", count: picked.count, single: picked.single) == "Copy 2 file(s) to")
        #expect(OperationText.targetProposal(count: 2, single: nil, targetPath: "mem:/B") == "mem:/B/*.*")
        #expect(
            OperationText.deleteQuestion(count: 2, single: nil, toTrash: false)
                == "Do you really want to delete the 2 selected files/directories?"
        )
        // The old forms say the same.
        #expect(OperationText.heading("Copy", picked.items()) == "Copy 2 file(s) to")
        #expect(
            OperationText.deleteQuestion(Array(picked.items().prefix(1)), toTrash: true)
                == OperationText.deleteQuestion(count: 1, single: picked.first, toTrash: true)
        )
        // On `[..]` with nothing marked there is nothing to do.
        model.clearSelection()
        model.moveCursor(to: 0)
        #expect(FileOperations.Picked(model).count == (model.cursorItem == nil ? 0 : 1))
    }

    @Test func theMarksOfWhatWasProcessedComeOffAndTheOthersStay() {
        let bench = bench()
        let model = bench.left.model
        model.selectAll()
        let picked = FileOperations.Picked(model)
        // Two of the three were processed.
        var processed = FileOperations.Processed([memory.url("/A/one.txt"), memory.url("/A/three.txt")], of: picked)
        #expect(processed.names == ["one.txt", "three.txt"] && processed.indices.count == 2)
        processed.deselect(in: model)
        #expect(model.selectedNames == ["two.txt"])
        // The panel shows another list by the time the job ends: the names are gone by then
        // as places, and are still found as names.
        model.selectAll()
        processed = FileOperations.Processed([memory.url("/A/two.txt")], of: FileOperations.Picked(model))
        memory.addFile("/A/a-new-first.txt")
        bench.left.reload()
        #expect(model.items.first?.name == "a-new-first.txt" && model.selectionCount == 3)
        processed.deselect(in: model)
        #expect(Set(model.selectedNames) == ["one.txt", "three.txt"])
        // Nothing processed: nothing changes.
        FileOperations.Processed([], of: FileOperations.Picked(model)).deselect(in: model)
        #expect(model.selectionCount == 2)
    }

    @Test func afterACopyOnlyTheCopiedItemsLoseTheirMark() {
        let bench = bench()
        memory.addDirectory("/B/two.txt")  // a folder in the way of one of the three
        bench.right.reload()
        bench.left.model.selectAll()
        ui.promptAnswer = { $0 }
        // The conflict is answered with Return, which skips; the error with Skip.
        #expect(bench.commands.perform(.copy))
        #expect(memory.contents("/B/one.txt") == "1" && memory.contents("/B/three.txt") == "3")
        #expect(bench.left.model.selectedNames == ["two.txt"])
    }

    // F009
    @Test func deleteAsksWhatTheFolderCanDoOnceNotPerItem() {
        for index in 0..<60 { memory.addFile("/many/f\(index).txt") }
        let bench = bench(left: memory.url("/many"))
        bench.left.model.selectAll()
        let asked = Shared(0)
        memory.capabilitiesAt = { _ in
            asked.modify { $0 += 1 }
            return [.write]
        }
        ui.answer = { _ in 0 }
        #expect(bench.commands.perform(.deleteDirectly))
        #expect(memory.allPaths.filter { $0.hasPrefix("/many/") }.isEmpty)
        // The command's own check, the question, the job: a handful, not one per file.
        #expect(asked.value > 0 && asked.value < 10, "\(asked.value)")
    }

    // F027: the log's last lines at the end of the program.
    @Test func theLogIsWrittenWhileTheProgramPreparesToQuit() async {
        let settings = MemorySettings()
        settings.set(true, forKey: OperationSettings.logEnabled)
        settings.set(box.url("logs/operations.log").path, forKey: OperationSettings.logFile)
        let plugin = FileOperationsPlugin()
        let bench = bench([plugin, SelectionPlugin()], settings: settings)
        bench.left.moveCursor(toName: "one.txt")
        ui.promptAnswer = { $0 }
        #expect(bench.commands.perform(.copy) && memory.contents("/B/one.txt") == "1")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            plugin.prepareToQuit(cancellation: CancellationFlag()) { done.resume() }
        }
        #expect(box.read("logs/operations.log")?.contains("Copy: mem:/A/one.txt -> mem:/B/one.txt") == true)
        // A plugin that has no log to write says so at once.
        // Guarded by `lock`.
        nonisolated(unsafe) var answered = false
        FileOperationsPlugin().prepareToQuit(cancellation: CancellationFlag()) { answered = true }
        #expect(answered)
        plugin.stop()
    }

    @Test func aLogThatCannotBeWrittenHoldsUpNeitherTheQuitNorItsCaller() async {
        var configuration = OperationLog.Configuration()
        configuration.isEnabled = true
        configuration.file = box.url("logs/operations.log")
        let log = OperationLog(configuration)
        // The log's queue is held, as by a disk that has stopped answering.
        let release = DispatchSemaphore(value: 0)
        log.onQueue { release.wait() }
        defer { release.signal() }
        log.write(OperationRecord(.copy, source: "/a", target: "/b"))
        // The quit on the main thread waits a moment and goes on.
        #expect(log.flush(timeout: 0.05) == false)
        // The flush before the quit ends as soon as the user does not want to wait.
        let flag = CancellationFlag()
        // Guarded by `lock`.
        nonisolated(unsafe) var calls = 0
        let lock = NSLock()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            log.flush(cancellation: flag) {
                lock.withLock { calls += 1 }
                done.resume()
            }
            flag.cancel()
        }
        #expect(!box.exists("logs/operations.log"))
        // Let go, the queue writes what it holds, and nobody is called a second time.
        release.signal()
        log.flush()
        #expect(box.read("logs/operations.log")?.hasSuffix("Copy: /a -> /b\n") == true && lock.withLock { calls } == 1)
        // A flag that is set before the flush is asked for answers at once, too.
        nonisolated(unsafe) var early = false
        log.flush(cancellation: flag) { early = true }
        #expect(early)
    }

    @Test func aPipeWhereTheLogShouldBeIsNotOpened() throws {
        try box.folder("logs")
        #expect(mkfifo(box.url("logs/operations.log").path, 0o600) == 0)
        var configuration = OperationLog.Configuration()
        configuration.isEnabled = true
        configuration.file = box.url("logs/operations.log")
        let log = OperationLog(configuration)
        log.write(OperationRecord(.copy, source: "/a", target: "/b"))
        // Without a reader, opening a pipe to write would wait for ever.
        #expect(log.flush(timeout: 30))
    }

    // New folders are made exclusively, and a job that is cancelled makes none.
    @Test func aNewFolderIsNotTakenForOneThatAppearedMeanwhile() {
        let bench = bench()
        #expect(bench.commands.perform(.makeDirectory, .text("fresh|fresh/inner|one.txt")))
        #expect(memory.exists("/A/fresh/inner"))
        // The name of a file that is there: said, and nothing made.
        #expect(
            ui.messages.contains { $0.contains("one.txt cannot be created") } && memory.contents("/A/one.txt") == "1"
        )
    }
}

// MARK: - Clipboard

@MainActor @Suite struct Review2FileopsP2Clipboard {
    let box: Sandbox
    private let scratch = ScratchPasteboard()
    var pasteboard: NSPasteboard { scratch.pasteboard }
    let probe = P2ProbeFileSystem()
    let bench: TestBench

    var commands: CommandRegistry { bench.commands }

    init() throws {
        box = try Sandbox()
        try box.folder("t")
        probe.base.addFile("/A/one.txt")
        bench = TestBench(
            plugins: [FileOperationsPlugin(), ClipboardPlugin(pasteboard: scratch.pasteboard), SelectionPlugin()],
            fileSystems: [LocalFileSystem(), probe],
            left: probe.base.url("/A"),
            right: box.url("t")
        )
    }

    /// Lets the main queue run until `condition` holds. The limit is far beyond what the
    /// work takes; it only ends a test whose condition never comes true.
    private func wait(for condition: () -> Bool) async -> Bool {
        for _ in 0..<12_000 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    // F003
    @Test func aLongListOfNamesIsMadeInTheBackgroundAndTheLatestRequestWins() async {
        let count = ClipboardPlugin.listedAtOnce + 50
        for index in 0..<count { probe.base.addFile("/long/f\(index).txt") }
        bench.left.show(probe.base.url("/long"))
        commands.perform(.selectAll)
        pasteboard.clearContents()
        commands.perform(ClipboardCommands.copyNames)
        // Not there yet: the text is being put together elsewhere.
        #expect(pasteboard.string(forType: .string) == nil)
        #expect(await wait { pasteboard.string(forType: .string) != nil })
        #expect(pasteboard.string(forType: .string)?.split(separator: "\n").count == count)
        // Asked for again, and something newer put on the clipboard before it arrived: the
        // long list must not take its place afterwards.
        commands.perform(ClipboardCommands.copyNames)
        commands.perform(ClipboardCommands.copySourcePath)
        #expect(pasteboard.string(forType: .string) == "probe:/long")
        // The list has long been put together by then (it takes a millisecond); had it been
        // handed over after all, it would be on the clipboard now.
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(pasteboard.string(forType: .string) == "probe:/long")
    }

    /// What another program does: one pasteboard item per file.
    private func writeAsAnotherProgram(_ urls: [URL]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(
            urls.map { url -> NSPasteboardItem in
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                return item
            }
        )
    }

    // F039
    @Test func aLongListOfFilesFromAnotherProgramIsReadInSlices() async throws {
        let urls = (0..<3_000).map { box.url("src/f\($0).txt") }
        writeAsAnotherProgram(urls)
        let items = try #require(pasteboard.pasteboardItems)
        // Read from a job's thread, the main thread does the reading a slice at a time.
        let reading = FileListReading(items, on: pasteboard)
        let flag = CancellationFlag()
        let outcome: FileListReading.Outcome = await withCheckedContinuation { done in
            Thread.detachNewThread {
                done.resume(returning: reading.run(cancellation: flag) { _, _ in })
            }
        }
        #expect(outcome == .read(urls))
        #expect(reading.slices >= 1)
        // Cancelled: nothing comes of it.
        let cancelled = FileListReading(items, on: pasteboard)
        flag.cancel()
        let abandoned: FileListReading.Outcome = await withCheckedContinuation { done in
            Thread.detachNewThread {
                done.resume(returning: cancelled.run(cancellation: flag) { _, _ in })
            }
        }
        #expect(abandoned == .abandoned)
        // The clipboard got other contents after the reading was set up: what was read is of
        // no use, and nothing is pasted from it.
        let stale = FileListReading(items, on: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("something else", forType: .string)
        #expect(stale.run(cancellation: CancellationFlag()) { _, _ in } == .abandoned)
    }

    @Test func aSliceIsShortAndOnlyFileLocationsAreTaken() {
        // A slice may take a few thousandths of a second, so that the main thread gets its
        // turn between two of them.
        #expect(FileListReading.sliceTime <= 10_000_000)
        let item = NSPasteboardItem()
        item.setString("file:///tmp/a%20b.txt", forType: .fileURL)
        #expect(FileListReading.fileURL(of: item)?.path == "/tmp/a b.txt")
        let text = NSPasteboardItem()
        text.setString("https://example.invalid/x", forType: .fileURL)
        #expect(FileListReading.fileURL(of: text) == nil)
        let none = NSPasteboardItem()
        none.setString("just text", forType: .string)
        #expect(FileListReading.fileURL(of: none) == nil)
    }

    @Test func aLongListFromAnotherProgramIsPastedWhole() throws {
        let count = ClipboardPlugin.readAtOnce + 44
        var urls: [URL] = []
        for index in 0..<count { urls.append(try box.file("src/f\(index).txt", "\(index)")) }
        writeAsAnotherProgram(urls)
        bench.right.focus()
        #expect(commands.isEnabled(.pasteFromClipboard))
        commands.perform(.pasteFromClipboard)
        #expect(bench.jobService.titles.contains("Reading the clipboard:"))
        #expect(namesOnDisk(box.url("t")).count == count && box.read("t/f\(count - 1).txt") == "\(count - 1)")
        // A short one is read as before, without a job of its own.
        try box.folder("u")
        bench.right.show(box.url("u"))
        writeAsAnotherProgram(Array(urls.prefix(3)))
        let before = bench.jobService.titles.filter { $0 == "Reading the clipboard:" }.count
        commands.perform(.pasteFromClipboard)
        #expect(namesOnDisk(box.url("u")) == ["f0.txt", "f1.txt", "f2.txt"])
        #expect(bench.jobService.titles.filter { $0 == "Reading the clipboard:" }.count == before)
    }

    // F040: the failure path.
    @Test func aTextThatCannotBeWrittenLeavesNoDraftBehind() {
        struct DiskFull: LocalizedError {
            var errorDescription: String? { "The disk is full." }
        }
        pasteboard.clearContents()
        pasteboard.setString("some text", forType: .string)
        probe.writeFailure = DiskFull()
        #expect(commands.isEnabled(.pasteFromClipboard))
        commands.perform(.pasteFromClipboard)
        #expect(probe.base.allPaths == ["/A", "/A/one.txt"], "\(probe.base.allPaths)")
        #expect(bench.ui.log.contains("inform: The clipboard cannot be pasted as a file!"))
        // And when it can be written, the file is there under its own name only.
        probe.writeFailure = nil
        commands.perform(.pasteFromClipboard)
        #expect(
            probe.base.allPaths == ["/A", "/A/Clipboard.txt", "/A/one.txt"]
                && probe.base.contents("/A/Clipboard.txt") == "some text"
        )
    }

    @Test func whetherThereIsSomethingToPasteIsAskedOncePerStateOfTheClipboard() {
        pasteboard.clearContents()
        pasteboard.setString("text", forType: .string)
        #expect(commands.isEnabled(.pasteFromClipboard) && commands.isEnabled(.pasteFromClipboard))
        // Another state of the clipboard is another answer, at once.
        pasteboard.clearContents()
        pasteboard.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("org.example.afm-test-unknown"))
        #expect(!commands.isEnabled(.pasteFromClipboard))
        pasteboard.clearContents()
        pasteboard.setString("again", forType: .string)
        #expect(commands.isEnabled(.pasteFromClipboard))
    }
}

// MARK: - File properties

@Suite struct Review2FileopsP2Properties {
    let box: Sandbox
    let fileSystems = FileSystemRegistry()
    let memory = MemoryFileSystem()
    let probe = P2ProbeFileSystem()

    init() throws {
        box = try Sandbox()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(memory)
        fileSystems.register(probe)
    }

    // V070, T024
    @Test func measuringAFolderOnAServerThatStoppedAnsweringEndsWithTheJob() throws {
        memory.addFile("/s/dir/sub/f.txt", "12345")
        memory.addFile("/s/file.txt", "123")
        let items = try memory.list(memory.url("/s"), showHidden: true)
        let flag = CancellationFlag()
        let calculator = SpaceCalculator(fileSystems: fileSystems, cancellation: flag)
        #expect(calculator.measure(items).reduce(SpaceTotals(), +).bytes == 8)
        memory.stallsListings = true
        // Written by the other thread before the wait ends, read here after it.
        nonisolated(unsafe) var totals: [SpaceTotals] = []
        p2CancelSoon(flag)
        let ended = p2Finishes(rescue: { memory.releaseStalls() }) { totals = calculator.measure(items) }
        #expect(ended)
        // What was not read is not "unreadable": the calculation was stopped, and says so elsewhere.
        #expect(totals.reduce(SpaceTotals(), +).unreadable == 0 && totals.count == items.count)
    }

    // V070, T024, T047
    @Test func changingAttributesBelowAFolderThatStoppedAnsweringEndsWithTheJob() throws {
        memory.addFile("/s/dir/sub/f.txt")
        let items = try memory.list(memory.url("/s"), showHidden: true)
        memory.stallsListings = true
        let flag = CancellationFlag()
        var change = AttributeChange()
        change.recurse = true
        change.timestamp = .current
        let job = AttributeJob(change: change, fileSystems: fileSystems, cancellation: flag)
        // Written by the other thread before the wait ends, read here after it.
        nonisolated(unsafe) var outcome = AttributeJob.Outcome()
        p2CancelSoon(flag)
        let ended = p2Finishes(rescue: { memory.releaseStalls() }) { outcome = job.run(items) }
        #expect(ended && outcome.cancelled)
        // Nothing "failed": the job was stopped.
        #expect(outcome.failed == 0 && outcome.failures.isEmpty)
    }

    @Test func aTreeIsChangedOnAllCoresWithNothingLeftOut() throws {
        // Folders in folders, each with files: the calls for them are made from inside calls.
        var files = 0
        var folders = 1
        for a in 0..<6 {
            folders += 1
            for b in 0..<5 {
                folders += 1
                for c in 0..<70 {
                    try box.file("tree/a\(a)/b\(b)/f\(c).txt", "x")
                    files += 1
                }
            }
            try box.file("tree/a\(a)/own.txt", "x")
            files += 1
        }
        let items = try LocalFileSystem().list(box.root, showHidden: true).filter { $0.name == "tree" }
        var change = AttributeChange()
        change.recurse = true
        change.permissions = try #require(PermissionChange("go-rwx"))
        let outcome = AttributeJob(change: change, fileSystems: fileSystems).run(items)
        #expect(outcome.changed == files + folders && outcome.failed == 0 && !outcome.cancelled)
        var info = stat()
        #expect(lstat(box.url("tree/a5/b4/f69.txt").path, &info) == 0 && info.st_mode & 0o077 == 0)
        #expect(lstat(box.url("tree/a0/b0").path, &info) == 0 && info.st_mode & 0o077 == 0)
    }

    // V070: the comment column's threads.
    @Test func nobodyWaitsForEverForACommentFileThatIsNotComing() {
        probe.base.addFile("/A/descript.ion", "a.txt the comment\r\n")
        probe.base.addFile("/A/a.txt")
        let store = CommentStore(fileSystems: fileSystems)
        let folder = probe.base.url("/A")
        #expect(store.comments(in: folder)["a.txt"] == "the comment")
        store.forget(folder)
        let alreadyRead = probe.reads.count
        // From now on the file does not arrive: its reads wait until they are interrupted.
        probe.base.stallsReads = true
        let (first, second) = (CancellationFlag(), CancellationFlag())
        // Guarded by `lock`.
        nonisolated(unsafe) var answers: [[String: String]] = [[:], [:], [:]]
        let lock = NSLock()
        let reader = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let comments = store.comments(in: folder, cancellation: first)
            lock.withLock { answers[0] = comments }
            reader.signal()
        }
        // The first thread has the file open before the others ask.
        for _ in 0..<60_000 where probe.reads.count == alreadyRead { usleep(1_000) }
        #expect(probe.reads.count == alreadyRead + 1)
        // A thread that waits for that reading gives up when its own flag is set…
        p2CancelSoon(second, after: 0.1)
        #expect(
            p2Finishes(rescue: { probe.base.releaseStalls() }) {
                let comments = store.comments(in: folder, cancellation: second)
                lock.withLock { answers[1] = comments }
            }
        )
        // …and one without a flag when its patience runs out.
        store.waitLimit = 0.2
        #expect(
            p2Finishes(rescue: { probe.base.releaseStalls() }) {
                let comments = store.comments(in: folder)
                lock.withLock { answers[2] = comments }
            }
        )
        // Nobody opened the file a second time meanwhile.
        #expect(probe.reads.count == alreadyRead + 1)
        // The reader itself ends with its flag, and what it did not read is not remembered.
        first.cancel()
        #expect(reader.wait(timeout: .now() + 60) == .success)
        #expect(lock.withLock { answers } == [[:], [:], [:]])
        probe.base.stallsReads = false
        #expect(store.comments(in: folder)["a.txt"] == "the comment")
    }

    @Test func aCommentThatIsBeingSavedIsNotWrittenFromAReadingThatWasStopped() throws {
        memory.addFile("/A/descript.ion", "a.txt old\r\nb.txt other\r\n")
        let store = CommentStore(fileSystems: fileSystems)
        let flag = CancellationFlag()
        flag.cancel()
        #expect(throws: (any Error).self) {
            try store.setComment("new", for: "a.txt", in: memory.url("/A"), hidden: false, cancellation: flag)
        }
        #expect(memory.contents("/A/descript.ion") == "a.txt old\r\nb.txt other\r\n")
        #expect(memory.allPaths.filter { $0.hasPrefix("/A/") } == ["/A/descript.ion"])
        try store.setComment("new", for: "a.txt", in: memory.url("/A"), hidden: false)
        #expect(memory.contents("/A/descript.ion") == "a.txt new\r\nb.txt other\r\n")
    }

    // G002: the six reproducers the fuzzer kept, through the checks that failed.
    @Test func theCommentFilesThatWereMisreadOrLostAreReadAndRewrittenWhole() throws {
        func bytes(_ name: String) throws -> [UInt8] {
            let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fuzz/repro/misc/\(name)")
            return Array(try Data(contentsOf: file))
        }
        // One well-formed line: a name without separators, a space, a comment.
        for (name, quoted) in [
            ("descript-line-misread-prepend-char.bin", false),
            ("descript-quoted-line-misread-combining-mark.bin", true)
        ] {
            let input = try bytes(name)
            let take = min(Int(input[0] % 32), input.count - 1)
            var fileName = String(decoding: input[1..<(1 + take)], as: UTF8.self)
            fileName.unicodeScalars.removeAll { " \"\r\n".unicodeScalars.contains($0) || $0.value == 0xFEFF }
            var comment = String(decoding: input[(1 + take)...], as: UTF8.self)
            comment.unicodeScalars.removeAll { "\r\n".unicodeScalars.contains($0) }
            comment = DescriptIon.normalized(comment)
            // The harness leaves such inputs out; the reproducers are not among them.
            try #require(!fileName.isEmpty && !comment.isEmpty)
            let line = (quoted ? "\"" + fileName + "\"" : fileName) + " " + comment + "\r\n"
            let file = DescriptIon(data: Data([0xEF, 0xBB, 0xBF] + Array(line.utf8)))
            #expect(file.entries.count == 1, "\(name)")
            #expect(file.entries.first.map { Array($0.name.utf8) } == Array(fileName.utf8), "\(name)")
            #expect(file.entries.first.map { Array($0.comment.utf8) } == Array(comment.utf8), "\(name)")
        }
        // Written again, as any change of a comment does, every entry is still there.
        for name in ["descript-rewrite-bom-collision.bin", "descript-rewrite-prepend-char.bin"] {
            let data = Data(try bytes(name))
            let file = DescriptIon(data: data)
            #expect(!file.entries.isEmpty && DescriptIon(strict: data) == file, "\(name)")
            #expect(DescriptIon(data: file.data()).entries == file.entries, "\(name)")
        }
        // Through the store: a comment is added and every other one is as it was.
        for name in ["descript-store-bom-name-lost.bin", "descript-store-file-unreadable-after-edit.bin"] {
            memory.removeTree("/d")
            let folder = memory.addDirectory("/d")
            let writer = try memory.write(folder.appending(name: DescriptIon.fileName))
            try writer.write(Data(try bytes(name)))
            try writer.close(attributes: FileAttributes())
            let store = CommentStore(fileSystems: fileSystems)
            let before = store.comments(in: folder)
            try store.setComment("fresh\ncomment", for: "new.txt", in: folder, hidden: false)
            let after = store.comments(in: folder)
            #expect(after["new.txt"] == "fresh\ncomment", "\(name)")
            for (entry, comment) in before where entry != "new.txt" {
                #expect(after[entry] == comment, "\(name): \(entry.debugDescription)")
            }
            #expect(after.count == before.count + (before["new.txt"] == nil ? 1 : 0), "\(name)")
        }
    }
}

@MainActor @Suite struct Review2FileopsP2PropertyCommands {
    let box: Sandbox
    let ui = ScriptedInteraction()
    let jobs = P2DeferredJobs()
    let bench: P2Bench

    init() throws {
        box = try Sandbox()
        try box.file("d/a.txt", "a")
        try box.file("d/b.txt", "b")
        try box.folder("d/folder")
        try box.file("d/folder/inside.txt", "12345")
        try box.folder("other")
        try box.file("files/only.txt", "x")
        bench = P2Bench(
            plugins: [FilePropertiesPlugin(launchesApplications: false), SelectionPlugin()],
            fileSystems: [LocalFileSystem()],
            left: box.url("d"),
            right: box.url("other"),
            ui: ui,
            jobs: jobs
        )
    }

    // F037: a dialog about what the panel showed when the command was given.
    @Test func aDialogIsNotShownOnceThePanelShowsAnotherFolder() throws {
        bench.left.moveCursor(toName: "a.txt")
        for command in [CommandID.setAttributes, .editComment] {
            #expect(bench.commands.perform(command))
            // The job has read what the dialog needs; the user has gone elsewhere meanwhile.
            bench.left.show(box.url("other"))
            jobs.deliver()
            #expect(!ui.log.contains { $0.hasPrefix("form") }, "\(command)")
            bench.left.show(box.url("d"))
            bench.left.moveCursor(toName: "a.txt")
        }
        try FileManager.default.createSymbolicLink(
            at: box.url("d/link"),
            withDestinationURL: box.url("files/only.txt")
        )
        bench.left.reload()
        bench.left.moveCursor(toName: "link")
        #expect(bench.commands.perform(.showLinkTarget))
        bench.left.show(box.url("other"))
        jobs.deliver()
        // The panel stays where the user took it.
        #expect(bench.left.model.directory.isSameLocation(as: box.url("other")))
        // In the folder the command was given in, the dialog comes and the link is followed.
        bench.left.show(box.url("d"))
        bench.left.moveCursor(toName: "a.txt")
        #expect(bench.commands.perform(.setAttributes))
        jobs.deliver()
        #expect(ui.log.contains("form: Change attributes: a.txt"))
        bench.left.moveCursor(toName: "link")
        #expect(bench.commands.perform(.showLinkTarget))
        jobs.deliver()
        #expect(bench.left.model.directory.isSameLocation(as: box.url("files")))
    }

    // F038: the names of owner and group are asked for in the job.
    @Test func ownerAndGroupAreLookedUpBeforeTheDialogNotWhileItIsMade() throws {
        bench.left.moveCursor(toName: "a.txt")
        var afterWork = -1
        jobs.afterWork = { afterWork = LocalInfo.nameLookups }
        #expect(bench.commands.perform(.setAttributes))
        let details = try #require(LocalInfo.details(box.url("d/a.txt")))
        #expect(afterWork >= 0)
        // The dialog shows both names…
        jobs.deliver()
        let fields = try #require(ui.forms.last)
        #expect(fields.contains { $0.label.contains("now \(LocalInfo.userName(details.ownerID))") })
        // …and found them known: nothing was asked of the system after the job's work.
        #expect(LocalInfo.nameLookups == afterWork)
    }

    // F070
    @Test func allFolderSizesAreOfferedOnlyWhereThereAreFolders() {
        #expect(bench.commands.isEnabled(.countDirectoryContents))
        bench.left.show(box.url("files"))
        #expect(!bench.commands.isEnabled(.countDirectoryContents))
        bench.left.show(box.url("d"))
        #expect(bench.commands.perform(.countDirectoryContents))
        jobs.deliver()
        #expect(bench.left.model.items.first { $0.name == "folder" }?.computedSize == 5)
        // The sizes belong to the list they were worked out for.
        #expect(bench.commands.perform(.countDirectoryContents))
        bench.left.show(box.url("other"))
        jobs.deliver()
        #expect(bench.left.model.items.allSatisfy { $0.computedSize == nil })
    }

    @Test func theSizesAreShownAlsoWhenTheListChangedWhileTheyWereWorkedOut() throws {
        #expect(bench.commands.perform(.countDirectoryContents))
        // The same folder, another list: a file was added while the job ran.
        try box.file("d/zz-new.txt", "new")
        bench.left.reload()
        jobs.deliver()
        #expect(bench.left.model.items.first { $0.name == "folder" }?.computedSize == 5)
    }

    // F010, and the sizes and marks after Calculate Occupied Space.
    @Test func whatACommandChangedIsShownInThePanelAfterwards() {
        bench.left.moveCursor(toName: "a.txt")
        #expect(bench.commands.perform(.setAttributes, .text("= +m600")))
        jobs.deliver()
        #expect(bench.left.model.items.first { $0.name == "a.txt" }?.permissions == 0o600)
        bench.left.model.setSelection(names: ["folder", "b.txt"])
        #expect(bench.commands.perform(.occupiedSpace))
        jobs.deliver()
        #expect(ui.log.contains("inform: Total space occupied:"))
        #expect(bench.left.model.items.first { $0.name == "folder" }?.computedSize == 5)
        #expect(bench.left.model.selectionCount == 2)
    }
}
