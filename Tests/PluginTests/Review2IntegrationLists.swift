import AFMContracts
import AFMKernel
import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

/// A list of files from anywhere says that its entries can only be removed (`.removeOnly`,
/// fileops request 12): the commands that make something new in the panel's folder are
/// withheld there, and Delete is not.
@MainActor
@Suite
internal struct Review2IntegrationLists {
    /// In a list of files, New Folder and New Text File are off while Delete and Copy stay on.
    @Test
    internal func nothingNewIsOfferedInAListOfFilesAndDeleteIs() {
        let memory = MemoryFileSystem()
        memory.addFile("/A/one.txt", "one")
        memory.addFile("/A/two.txt", "two")
        memory.addDirectory("/B")
        let lists = MemoryFileSystem(scheme: "listed")
        lists.addFile("/found/one.txt", "one")
        lists.capabilitiesAt = { _ in [.write, .removeOnly] }
        let bench = TestBench(
            plugins: [FileOperationsPlugin()],
            fileSystems: [memory, lists],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
        #expect(bench.commands.isEnabled(.makeDirectory) && bench.commands.isEnabled(.newTextFile))
        bench.left.show(lists.url("/found"))
        bench.left.moveCursor(toName: "one.txt")
        #expect(!bench.commands.isEnabled(.makeDirectory) && !bench.commands.isEnabled(.newTextFile))
        #expect(bench.commands.isEnabled(.delete) && bench.commands.isEnabled(.copy))
    }
}
