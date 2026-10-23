import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// The questions a running job asks through its bridge: every answer of the Overwrite dialog and its More menu,
/// names that are no names, comparing first, merging, other volumes, and an answer the dialog does not have.
@MainActor
@Suite
internal struct CovFileOpsBridge {
    private let memory = MemoryFileSystem()
    private let fileSystems = FileSystemRegistry()
    private let interaction = ScriptedInteraction()
    private let monitor = CovFileOpsMonitor()

    private var bridge: JobBridge {
        JobBridge(monitor: monitor, interaction: interaction, fileSystems: fileSystems)
    }

    private var job: FileJob {
        FileJob(kind: .copy, sources: [], target: nil, fileSystems: fileSystems)
    }

    /// `/A/new.txt` (two bytes) and `/B/old.txt` (one byte), and `/B/same.txt` like the new one.
    internal init() {
        fileSystems.register(memory)
        memory.addFile("/A/new.txt", "ab")
        memory.addFile("/B/old.txt", "a")
        memory.addFile("/B/same.txt", "ab")
    }

    /// The everyday answers and Rename, after names that are none.
    @Test
    internal func theEverydayAnswersAndRename() {
        interaction.choiceAnswers = [3, 4]
        #expect(conflict() == .skipAll && conflict() == .overwriteAllOlder)
        interaction.choiceAnswers = [5, 5, 5]
        interaction.promptAnswers = [.cancel, .text("a/b"), .text(" new ")]
        #expect(conflict() == .rename("new"))
    }

    /// Every entry of More…, after a More… that was closed and a renaming of the target that was cancelled.
    @Test
    internal func everyEntryOfMore() {
        let expected: [(row: Int, answer: ConflictChoice)] = [
            (1, .append), (2, .resume), (4, .autoRenameCopied), (5, .autoRenameExisting),
            (6, .renameOlderSkipNewer), (7, .overwriteAllOlderOrSame), (8, .copyAllLarger), (9, .copyAllSmaller)
        ]
        for (row, answer) in expected {
            interaction.choiceAnswers = [6]
            interaction.formAnswers = [.values(["row": .index(row)])]
            #expect(conflict() == answer, "row \(row)")
        }
        interaction.choiceAnswers = [6, 6, 6]
        interaction.formAnswers = [.cancel, .values(["row": .index(3)]), .values(["row": .index(3)])]
        interaction.promptAnswers = [.cancel, .text("kept.txt")]
        #expect(conflict() == .renameExisting("kept.txt"))
    }

    /// Compare tells whether the files are the same, different or could not be read, and asks again; cancelled
    /// meanwhile, the job is.
    @Test
    internal func compareTellsAndAsksAgain() {
        for (target, told) in [
            ("/B/same.txt", "inform: The two files have the same content!"),
            ("/B/old.txt", "inform: The two files are different!"),
            ("/B/gone.txt", "inform: The two files could not be compared.")
        ] {
            interaction.choiceAnswers = [6, 7]
            interaction.formAnswers = [.values(["row": .index(0)])]
            #expect(conflict(target: target) == .cancel)
            #expect(interaction.log.contains(told), "\(target)")
        }
        monitor.cancellation.cancel()
        interaction.choiceAnswers = [6]
        interaction.formAnswers = [.values(["row": .index(0)])]
        #expect(conflict() == .cancel)
    }

    /// Merging into a folder, emptying another volume by a move, and an answer the dialog does not have.
    @Test
    internal func mergingOtherVolumesAndOddAnswers() {
        let folder = FileItem(url: memory.url("/B"), name: "B", kind: .directory)
        interaction.choiceAnswers = [1, 1, 9]
        #expect(bridge.job(job, mergeInto: folder, source: folder) == .mergeAll)
        #expect(bridge.job(job, crossVolumeAt: folder, purpose: .move) == .proceed)
        #expect(interaction.log.last?.contains("Moving it would move everything on that volume away") == true)
        #expect(bridge.job(job, confirmDeleteNonEmpty: memory.url("/B")) == .cancel)
    }

    /// The Overwrite dialog for `/A/new.txt` over `target`.
    private func conflict(target: String = "/B/old.txt") -> ConflictChoice {
        let size = Int64(memory.contents(target)?.utf8.count ?? 1)
        let old = FileItem(url: memory.url(target), name: "old.txt", stat: .init(size: size))
        let new = FileItem(url: memory.url("/A/new.txt"), name: "new.txt", stat: .init(size: 2))
        return bridge.job(job, conflictAt: old, source: new)
    }
}
