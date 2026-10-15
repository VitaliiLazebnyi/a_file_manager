import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// Commands cancelled while a folder is being made for them, renames on a volume that cannot rename exclusively,
/// and renames to no new name.
@MainActor
@Suite
internal struct CovFileOpsCancelling {
    private let memory = MemoryFileSystem()

    /// `/A/one.txt` and `/B` in memory.
    internal init() {
        memory.addFile("/A/one.txt", "1")
        memory.addDirectory("/B")
    }

    /// Cancelled while the target folder or the folder of a new file is made, nothing is told and nothing is made.
    @Test
    internal func cancelledWhileAFolderIsMadeNothingIsTold() async {
        // The copy asks nothing; the new file is named by the prompt.
        let commands: [(CommandID, CommandArgument)] = [
            (.copy, .text("G T=\"mem:/B/new/\"")), (.newTextFile, .text("1"))
        ]
        for (command, argument) in commands {
            let bench = CoverageSmallBench(
                .background,
                plugins: [FileOperationsPlugin { nil }],
                fileSystems: [memory],
                left: memory.url("/A"),
                right: memory.url("/B")
            )
            bench.left.moveCursor(toName: "one.txt")
            bench.interaction.promptAnswers = [.text("sub/new.txt")]
            memory.stallsChanges = true
            bench.commands.perform(command, argument)
            #expect(Wait.until { memory.stalledChanges > 0 }, "\(command)")
            bench.jobService.cancelAll()
            #expect(await bench.jobService.settle { !bench.jobService.isBusy })
            memory.stallsChanges = false
            #expect(!bench.interaction.log.contains { $0.hasPrefix("inform:") }, "\(command)")
            #expect(!memory.exists("/B/new") && !memory.exists("/A/sub/new.txt"))
        }
    }

    /// Cancelled while it looks whether the name is free, a new folder is not made and nothing is told.
    @Test
    internal func aNewFolderCancelledWhileItsNameIsLookedAtIsNotMade() {
        let hooked = CoverageArchivesFSHookedMemory()
        hooked.base.addDirectory("/A")
        let bench = CoverageSmallBench(
            .cancelledFrom(first: 99),
            plugins: [FileOperationsPlugin { nil }],
            fileSystems: [hooked],
            left: hooked.base.url("/A"),
            right: hooked.base.url("/A")
        )
        // The hook runs on the job's thread; cancelling is for any thread.
        let jobs = Shared(bench.jobService)
        hooked.onNextItem { jobs.value.cancelAll() }
        bench.commands.perform(.makeDirectory, .text("made"))
        #expect(!hooked.base.exists("/A/made") && bench.interaction.log.isEmpty)
    }

    /// On a volume that cannot rename exclusively, a name that differs in case only renames the file itself; a
    /// name that is empty or the same changes nothing.
    @Test
    internal func aCaseOnlyRenameOnAVolumeThatCannotRenameExclusively() throws {
        let box = try Sandbox()
        try box.file("dir/a.txt", "a")
        let bench = TestBench(
            plugins: [FileOperationsPlugin { nil }],
            fileSystems: [CovFileOpsExclusiveDisk()],
            left: box.url("dir"),
            right: box.root
        )
        bench.left.moveCursor(toName: "a.txt")
        bench.commands.perform(.renameOnly, .text(""))
        bench.commands.perform(.renameOnly, .text("a.txt"))
        bench.commands.perform(.renameOnly, .text("A.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.url("dir").path) == ["A.txt"])
        #expect(bench.interaction.log.isEmpty)
    }
}
