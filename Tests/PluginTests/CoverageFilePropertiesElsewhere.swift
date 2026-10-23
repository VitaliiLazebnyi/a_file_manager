import AFMContracts
import AFMKernel
import TestSupport
import Testing

@testable import FilePropertiesPlugin

/// The commands of file properties on a file system that fails, is cancelled or names its root
/// without a name.
@MainActor
@Suite
internal struct CoverageFilePropertiesElsewhere {
    /// The files: `/A` with one file, `/B` empty.
    private let memory = MemoryFileSystem()
    /// The memory files behind a layer that fails what a test names.
    private let files: CoverageSmallFiles

    /// The files.
    internal init() {
        memory.addFile("/A/one.txt", "1")
        memory.addDirectory("/B")
        files = CoverageSmallFiles(memory)
    }

    /// A kernel with the plugin, its jobs run as `jobs` says.
    private func bench(_ jobs: CoverageSmallJobs.Mode) -> CoverageSmallBench {
        CoverageSmallBench(
            jobs,
            plugins: [FilePropertiesPlugin(launchesApplications: false)],
            fileSystems: [files],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
    }

    /// The properties of a root that has no name are titled by its path.
    @Test
    internal func aRootWithoutANameIsTitledByItsPath() {
        let bench = bench(.cancelledFrom(first: 9))
        files.namesRootEmpty = true
        memory.removeTree("/A")
        memory.removeTree("/B")
        bench.left.show(memory.url("/"))
        bench.commands.perform(.properties)
        #expect(bench.interaction.log == ["form: Properties: \(memory.displayPath(memory.url("/")))"])
    }

    /// In a root without entries there is no comment to edit.
    @Test
    internal func noCommentInAnEmptyRoot() {
        let bench = bench(.cancelledFrom(first: 9))
        memory.removeTree("/A")
        memory.removeTree("/B")
        bench.left.show(memory.url("/"))
        #expect(!bench.commands.isEnabled(.editComment))
    }

    /// A comment whose reading is cancelled is not edited; one whose saving is cancelled is not
    /// saved and nothing is said.
    @Test
    internal func cancelledCommentsAreNeitherEditedNorSaved() {
        let reading = bench(.cancelled)
        reading.left.moveCursor(toName: "one.txt")
        reading.commands.perform(.editComment)
        #expect(reading.interaction.log.isEmpty && reading.jobService.titles == ["Reading comment:"])
        let saving = bench(.cancelledFrom(first: 1))
        saving.left.moveCursor(toName: "one.txt")
        saving.interaction.formAnswers = [.values(["comment": .text("new")])]
        saving.commands.perform(.editComment)
        #expect(saving.jobService.titles == ["Reading comment:", "Saving comment:"])
        #expect(saving.interaction.log == ["form: File comment"] && !memory.exists("/A/descript.ion"))
    }

    /// A comment that cannot be saved is reported.
    @Test
    internal func aCommentThatCannotBeSavedIsReported() {
        let bench = bench(.cancelledFrom(first: 9))
        files.fails = [.write]
        bench.left.moveCursor(toName: "one.txt")
        bench.interaction.formAnswers = [.values(["comment": .text("new")])]
        bench.commands.perform(.editComment)
        #expect(bench.interaction.log == ["form: File comment", "inform: The comment of one.txt cannot be saved!"])
    }
}
