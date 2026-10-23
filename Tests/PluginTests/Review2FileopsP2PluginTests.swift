import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// Second pass of review round 2 for the commands of the file-operation plugin: the fixes of the first pass that
/// had no test of their own (F008, F009, F027), the default buttons of the questions that destroy something (F055),
/// the operation log and new folders.
@MainActor
@Suite
internal struct Review2FileopsP2PluginTests {
    /// The temporary folder on the local disk.
    internal let box: Sandbox
    /// The memory file system the panels show: `/A` with three files, and the empty `/B`.
    internal let memory = MemoryFileSystem()
    /// Keeps every question and answers it.
    internal let interaction = P2RecordingUI()

    /// A fresh sandbox, and the files in memory.
    internal init() throws {
        box = try Sandbox()
        memory.addFile("/A/one.txt", "1")
        memory.addFile("/A/two.txt", "2")
        memory.addFile("/A/three.txt", "3")
        memory.addDirectory("/B")
    }

    /// A kernel with `plugins`, the local disk and `memory`, its left panel on `left` (`/A` by default) and its
    /// right one on `/B`.
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
            interaction: interaction,
            jobs: ImmediateJobService(),
            settings: settings
        )
    }

    /// Return does not confirm a deletion that cannot be undone (F055).
    @Test
    internal func returnDoesNotConfirmADeletionThatCannotBeUndone() throws {
        let bench = bench()
        bench.left.moveCursor(toName: "one.txt")
        // Nobody chooses a button: Return.
        #expect(bench.commands.perform(.deleteDirectly))
        let question = try #require(interaction.questions.last)
        #expect(
            question.message == "Permanently delete" && question.buttons == ["Yes", "No"] && question.defaultButton == 1
        )
        #expect(memory.exists("/A/one.txt"))
        // Chosen, it is done.
        interaction.answer = { _ in 0 }
        #expect(bench.commands.perform(.deleteDirectly) && !memory.exists("/A/one.txt"))
    }

    /// What goes to the Trash is still confirmed with Return.
    @Test
    internal func whatGoesToTheTrashIsStillConfirmedWithReturn() throws {
        try box.file("d/keep.txt", "kept")
        let bench = bench(left: box.url("d"))
        bench.left.moveCursor(toName: "keep.txt")
        // Answered with No all the same: the test moves nothing to the user's Trash.
        interaction.answer = { _ in 1 }
        #expect(bench.commands.perform(.delete))
        let question = try #require(interaction.questions.last)
        #expect(question.message == "Test" && question.defaultButton == 0 && box.exists("d/keep.txt"))
    }

    /// The questions of a job that destroy something default to Skip, and say so.
    @Test
    internal func theQuestionsOfAJobThatDestroySomethingDefaultToSkip() {
        let fileSystems = FileSystemRegistry()
        fileSystems.register(memory)
        let bridge = JobBridge(monitor: P2DeferredJobs.Monitor(), interaction: interaction, fileSystems: fileSystems)
        let job = FileJob(kind: .copy, sources: [], fileSystems: fileSystems)
        let old = FileItem(url: memory.url("/B/one.txt"), name: "one.txt", stat: .init(size: 1))
        let new = FileItem(url: memory.url("/A/one.txt"), name: "one.txt", stat: .init(size: 2))
        // Each is answered with Return.
        #expect(bridge.job(job, conflictAt: old, source: new) == .skip)
        #expect(interaction.questions.last?.message == "Overwrite:" && interaction.questions.last?.defaultButton == 2)
        #expect(bridge.job(job, confirmDeleteNonEmpty: memory.url("/A")) == .skip)
        #expect(
            interaction.questions.last?.buttons == ["Delete", "All", "Skip", "Cancel"]
                && interaction.questions.last?.defaultButton == 2
        )
        for reason in [ProtectionQuestion.Reason.readOnly, .hidden, .locked, .noTrash] {
            #expect(
                bridge.job(job, confirm: ProtectionQuestion(reason: reason, purpose: .delete, item: old)) == .skip
            )
            #expect(interaction.questions.last?.defaultButton == 2)
        }
        #expect(
            bridge.job(job, confirm: ProtectionQuestion(reason: .readOnly, purpose: .overwrite, item: old)) == .skip
        )
        #expect(
            bridge.job(job, crossVolumeAt: old, purpose: .delete) == .skip
                && interaction.questions.last?.defaultButton == 0
        )
        // Every question of the bridge that can destroy said which button Return presses.
        #expect(interaction.questions.allSatisfy { $0.defaultButton != -1 })
        // A chosen answer is still the answer.
        interaction.answer = { _ in 0 }
        #expect(bridge.job(job, conflictAt: old, source: new) == .overwrite)
        #expect(bridge.job(job, confirmDeleteNonEmpty: memory.url("/A")) == .delete)
    }

    /// The operands of a command are counted without making the list of them (F008, F025).
    @Test
    internal func theOperandsAreCountedWithoutMakingTheListOfThem() throws {
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

    /// The marks of what was processed come off and the others stay, also when the list changed meanwhile.
    @Test
    internal func theMarksOfWhatWasProcessedComeOffAndTheOthersStay() {
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

    /// After a copy only the copied items lose their mark.
    @Test
    internal func afterACopyOnlyTheCopiedItemsLoseTheirMark() {
        let bench = bench()
        memory.addDirectory("/B/two.txt")  // a folder in the way of one of the three
        bench.right.reload()
        bench.left.model.selectAll()
        interaction.promptAnswer = \.self
        // The conflict is answered with Return, which skips; the error with Skip.
        #expect(bench.commands.perform(.copy))
        #expect(memory.contents("/B/one.txt") == "1" && memory.contents("/B/three.txt") == "3")
        #expect(bench.left.model.selectedNames == ["two.txt"])
    }

    /// Delete asks what the folder can do once, not once per item (F009).
    @Test
    internal func deleteAsksWhatTheFolderCanDoOnceNotPerItem() {
        for index in 0..<60 { memory.addFile("/many/f\(index).txt") }
        let bench = bench(left: memory.url("/many"))
        bench.left.model.selectAll()
        let asked = Shared(0)
        memory.capabilitiesAt = { _ in
            asked.modify { $0 += 1 }
            return [.write]
        }
        interaction.answer = { _ in 0 }
        #expect(bench.commands.perform(.deleteDirectly))
        #expect(!memory.allPaths.contains { $0.hasPrefix("/many/") })
        // The command's own check, the question, the job: a handful, not one per file.
        #expect(asked.value > 0 && asked.value < 10, "\(asked.value)")
    }

    /// The log's last lines are written while the program prepares to quit (F027).
    @Test
    internal func theLogIsWrittenWhileTheProgramPreparesToQuit() async {
        let settings = MemorySettings()
        settings.set(true, forKey: OperationSettings.logEnabled)
        settings.set(box.url("logs/operations.log").path, forKey: OperationSettings.logFile)
        let plugin = FileOperationsPlugin()
        let bench = bench([plugin, SelectionPlugin()], settings: settings)
        bench.left.moveCursor(toName: "one.txt")
        interaction.promptAnswer = \.self
        #expect(bench.commands.perform(.copy) && memory.contents("/B/one.txt") == "1")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            plugin.prepareToQuit(cancellation: CancellationFlag()) { done.resume() }
        }
        #expect(box.read("logs/operations.log")?.contains("Copy: mem:/A/one.txt -> mem:/B/one.txt") == true)
        // A plugin that has no log to write says so at once.
        // Set by the call before it returns, read here after it.
        nonisolated(unsafe) var answered = false
        FileOperationsPlugin().prepareToQuit(cancellation: CancellationFlag()) { answered = true }
        #expect(answered)
        plugin.stop()
    }

    /// A log that cannot be written holds up neither the quit nor its caller.
    @Test
    internal func aLogThatCannotBeWrittenHoldsUpNeitherTheQuitNorItsCaller() async {
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
        // Set by the call before it returns, read here after it.
        nonisolated(unsafe) var early = false
        log.flush(cancellation: flag) { early = true }
        #expect(early)
    }

    /// A pipe where the log should be is not opened, so the flush does not wait for a reader.
    @Test
    internal func aPipeWhereTheLogShouldBeIsNotOpened() throws {
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

    /// A new folder is not taken for one that appeared meanwhile: the name of a file that is there is told.
    @Test
    internal func aNewFolderIsNotTakenForOneThatAppearedMeanwhile() {
        let bench = bench()
        #expect(bench.commands.perform(.makeDirectory, .text("fresh|fresh/inner|one.txt")))
        #expect(memory.exists("/A/fresh/inner"))
        // The name of a file that is there: said, and nothing made.
        #expect(
            interaction.messages.contains { $0.contains("one.txt cannot be created") }
                && memory.contents("/A/one.txt") == "1"
        )
    }
}
