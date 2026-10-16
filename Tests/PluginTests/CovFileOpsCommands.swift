import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// The commands of the file operations with the inputs the other tests do not give: switches, dialogs that are
/// cancelled or answered oddly, names that are no names, failures that are many, a log on a volume to eject.
@MainActor
@Suite
internal struct CovFileOpsCommands {
    private let memory = MemoryFileSystem()
    private let box: Sandbox

    /// `/A/one.txt`, `/A/two.txt` and `/B` in memory, and an empty sandbox.
    internal init() throws {
        box = try Sandbox()
        memory.addFile("/A/one.txt", "1")
        memory.addFile("/A/two.txt", "2")
        memory.addDirectory("/B")
    }

    // MARK: Copy and move

    /// Switches turn verifying, keeping going and ignoring protection on and off, and an overwrite mode out of
    /// range is to ask; Move to Other Panel moves.
    @Test
    internal func switchesSetTheOptionsAndMoveOnlyMoves() {
        let bench = bench(clipboard: nil)
        bench.left.moveCursor(toName: "one.txt")
        bench.commands.perform(.copy, .text("V1 S0 H1 O99 G T=\"mem:/B/\""))
        #expect(memory.contents("/B/one.txt") == "1")
        bench.left.moveCursor(toName: "two.txt")
        bench.commands.perform(.moveOnly, .text("G T=\"mem:/B/\""))
        #expect(memory.contents("/B/two.txt") == "2" && !memory.exists("/A/two.txt"))
    }

    /// A target folder that cannot be made is told; cancelled while the target is read, nothing is said.
    @Test
    internal func aTargetThatCannotBeMadeIsTold() throws {
        let bench = TestBench(
            plugins: [FileOperationsPlugin { nil }],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
        bench.left.moveCursor(toName: "one.txt")
        let file = try box.file("file", "not a folder")
        bench.commands.perform(.copy, .text("G T=\"\(file.absoluteString)/sub/\""))
        #expect(bench.interaction.log.last?.hasPrefix("inform: The given target path") == true)
        let cancelled = smallBench(.cancelled)
        cancelled.left.moveCursor(toName: "one.txt")
        cancelled.commands.perform(.copy, .text("G T=\"mem:/B/\""))
        #expect(cancelled.interaction.log.isEmpty && !memory.exists("/B/one.txt"))
    }

    /// With keep going on errors, more failures than are listed end in an ellipsis.
    @Test
    internal func moreFailuresThanListedEndInAnEllipsis() throws {
        for number in 0..<21 {
            try box.file("from/file\(number).txt", "x")
        }
        let locked = try box.folder("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let bench = TestBench(
            plugins: [FileOperationsPlugin { nil }],
            fileSystems: [LocalFileSystem()],
            left: box.url("from"),
            right: locked
        )
        bench.left.model.selectAll()
        bench.commands.perform(.copy, .text("S1 G"))
        #expect(bench.interaction.log.last == "inform: 21 item(s) could not be processed.")
    }

    /// The options dialog takes an overwrite mode and a link handling out of range as the usual ones.
    @Test
    internal func theOptionsDialogTakesOddAnswersAsTheUsualOnes() {
        let bench = bench(clipboard: nil)
        bench.left.moveCursor(toName: "one.txt")
        bench.interaction.formAnswers = [
            .values(["overwrite": .index(99), "links": .index(9), "target": .text("mem:/B/")])
        ]
        bench.commands.perform(.copyWithOptions)
        #expect(memory.contents("/B/one.txt") == "1")
    }

    // MARK: Rename

    /// A name with a slash is refused; a name that differs in case only renames the file itself.
    @Test
    internal func namesWithASlashOrAnotherCase() throws {
        try box.file("dir/a.txt", "a")
        let bench = TestBench(
            plugins: [FileOperationsPlugin { nil }],
            fileSystems: [LocalFileSystem()],
            left: box.url("dir"),
            right: box.root
        )
        bench.left.moveCursor(toName: "a.txt")
        bench.commands.perform(.renameOnly, .text("x/y"))
        #expect(bench.interaction.log.last == "inform: a.txt cannot be renamed!")
        bench.commands.perform(.renameSingleFile, .text("A.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.url("dir").path) == ["A.txt"])
    }

    /// Without a name the name is edited in place; with several items marked they are renamed by a mask.
    @Test
    internal func renamingWithoutANameOrSeveralItems() {
        let bench = bench(clipboard: nil)
        bench.left.moveCursor(toName: "one.txt")
        bench.commands.perform(.renameOnly)
        bench.commands.perform(.renameSingleFile)
        bench.left.model.setSelection(names: ["one.txt", "two.txt"])
        // Cancelled; an empty mask; a mask with a slash; a mask that keeps every name.
        bench.interaction.formAnswers = [
            .cancel, .values(["mask": .text(" ")]), .values(["mask": .text("a/*.*")]), .values(["mask": .text("*.*")])
        ]
        for _ in 0..<4 {
            bench.commands.perform(.renameOnly)
        }
        #expect(memory.exists("/A/one.txt") && memory.exists("/A/two.txt"))
        // Each separately: given up at the first, or every name kept.
        bench.interaction.formAnswers = [.values(["each": .flag(true)]), .values(["each": .flag(true)])]
        bench.interaction.promptAnswers = [.cancel, .accept, .accept]
        bench.commands.perform(.renameOnly)
        bench.commands.perform(.renameOnly)
        #expect(memory.exists("/A/one.txt") && memory.exists("/A/two.txt"))
    }

    // MARK: New folders and files

    /// Names given with switches, names that are none, a dialog that is cancelled, and `[X]` without a clipboard.
    @Test
    internal func newFolderNamesThatAreNone() {
        let bench = bench(clipboard: nil)
        bench.commands.perform(.makeDirectory, .text("T=\"other\" G"))
        bench.commands.perform(.makeDirectory, .text("N=\"made\" G"))
        bench.commands.perform(.makeDirectory, .text("  "))
        bench.commands.perform(.makeDirectory)
        #expect(memory.exists("/A/made") && !memory.exists("/A/G"))
        bench.commands.perform(.makeDirectory, .text("<x[X]"))
        #expect(bench.interaction.log.last == "inform: The folder <x[X] cannot be created!")
        let clipped = self.bench(clipboard: "clip")
        clipped.commands.perform(.makeDirectory, .text("<x[X]"))
        #expect(memory.exists("/A/xclip"))
    }

    /// A new file asks for a free name, is not made when the dialog is cancelled or empty, and `[X]` without a
    /// clipboard is told.
    @Test
    internal func newFilesAndTheirNames() {
        let bench = bench(clipboard: nil)
        bench.interaction.promptAnswers = [.cancel, .text("  "), .text("<one[C].txt"), .text("<x[X]")]
        for _ in 0..<4 {
            bench.commands.perform(.newTextFile, .text("1"))
        }
        #expect(memory.exists("/A/one2.txt"))
        #expect(bench.interaction.log.last == "inform: The file <x[X] cannot be created!")
    }

    /// Cancelled before anything is made, a new file is not made and the panel stays.
    @Test
    internal func aCancelledNewFileIsNotMade() {
        let bench = smallBench(.cancelled)
        bench.interaction.promptAnswers = [.text("fresh.txt")]
        bench.commands.perform(.newTextFile, .text("1"))
        #expect(!memory.exists("/A/fresh.txt"))
    }

    /// A new file that cannot be written is told.
    @Test
    internal func aNewFileThatCannotBeWrittenIsTold() throws {
        let locked = try box.folder("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let bench = TestBench(
            plugins: [FileOperationsPlugin { nil }],
            fileSystems: [LocalFileSystem()],
            left: locked,
            right: box.root
        )
        bench.interaction.promptAnswers = [.text("new.txt")]
        bench.commands.perform(.newTextFile, .text("1"))
        #expect(bench.interaction.log.last == "inform: The file new.txt cannot be created!")
    }

    // MARK: The log

    /// A log on a volume to be ejected writes what it has; one elsewhere, or none, is left alone; quitting waits
    /// for no log when there is none.
    @Test
    internal func aLogOnAVolumeToBeEjectedIsWritten() async throws {
        let plugin = FileOperationsPlugin { nil }
        let quit = CancellationFlag()
        let unstarted = FileOperationsPlugin { nil }
        await withCheckedContinuation { done in unstarted.prepareToQuit(cancellation: quit) { done.resume() } }
        let settings = MemorySettings()
        let bench = TestBench(
            plugins: [plugin],
            fileSystems: [memory, LocalFileSystem()],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: settings
        )
        await withCheckedContinuation { done in plugin.prepareToQuit(cancellation: quit) { done.resume() } }
        try bench.kernel.fileSystems.closeFiles(on: box.root, cancellation: CancellationFlag())
        settings.set(true, forKey: OperationSettings.logEnabled)
        settings.set(box.url("logs/operations.log").path, forKey: OperationSettings.logFile)
        bench.left.moveCursor(toName: "one.txt")
        bench.commands.perform(.copy, .text("G"))
        try bench.kernel.fileSystems.closeFiles(
            on: URL(fileURLWithPath: "/nonexistent"),
            cancellation: CancellationFlag()
        )
        try bench.kernel.fileSystems.closeFiles(on: box.root, cancellation: CancellationFlag())
        #expect(box.read("logs/operations.log")?.contains("Copy: mem:/A/one.txt -> mem:/B/one.txt") == true)
    }

    /// A bench with the file operations reading `clipboard`, `/A` on the left and `/B` on the right.
    private func bench(clipboard: String?) -> TestBench {
        TestBench(
            plugins: [FileOperationsPlugin { clipboard }],
            fileSystems: [memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
    }

    /// The same with jobs that run as `jobs` says.
    private func smallBench(_ jobs: CoverageSmallJobs.Mode) -> CoverageSmallBench {
        CoverageSmallBench(
            jobs,
            plugins: [FileOperationsPlugin { nil }],
            fileSystems: [memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
    }
}
