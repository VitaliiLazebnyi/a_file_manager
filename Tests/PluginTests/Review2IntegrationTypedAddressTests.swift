import AFMContracts
import AFMKernel
import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

// Review round 2, integration: an address the user types into a dialog is reported to the
// plugin that connects to servers (N071), so that only addresses that came out of files are
// asked "Connect to X?".

/// Notes what it is told the user chose.
internal final class IntegrationConsent: ServerConsentService {
    internal private(set) var chosen: [URL] = []
    internal func userChose(_ location: URL) { chosen.append(location) }
}

@MainActor
@Suite
internal struct Review2IntegrationTypedAddresses {
    internal let memory = MemoryFileSystem()
    internal let server = MemoryFileSystem(scheme: "srv")
    internal let consent = IntegrationConsent()
    internal let bench: TestBench

    internal init() {
        memory.addFile("/A/one.txt", "one")
        memory.addDirectory("/B")
        server.addDirectory("/in")
        bench = TestBench(
            plugins: [FileOperationsPlugin()],
            fileSystems: [memory, server],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
        bench.kernel.services.register((any ServerConsentService).self, consent)
    }

    @Test
    internal func onlyTextWithAnAddressThatWasNotTheProposalIsReported() {
        let base = memory.url("/A")
        // An ordinary path, relative or not, is no address.
        bench.kernel.userTyped(location: "sub/folder", relativeTo: base)
        bench.kernel.userTyped(location: "mem:/B", relativeTo: base)
        #expect(consent.chosen.isEmpty)
        // What the program proposed and the user left alone was not typed.
        bench.kernel.userTyped(location: " srv://in/x ", relativeTo: base, proposal: "srv://in/x")
        #expect(consent.chosen.isEmpty)
        bench.kernel.userTyped(location: "srv://in/x", relativeTo: base, proposal: "srv://in/")
        #expect(consent.chosen.map(\.scheme) == ["srv"])
    }

    @Test
    internal func aTargetTypedIntoTheCopyDialogIsTheUsersOwnChoice() {
        bench.left.moveCursor(toName: "one.txt")
        bench.interaction.promptAnswers = [.text("srv://in/")]
        bench.commands.perform(.copy)
        #expect(consent.chosen.count == 1 && consent.chosen.first?.scheme == "srv")
        #expect(server.contents("/in/one.txt") == "one")
    }

    @Test
    internal func aProposedTargetThatIsLeftAsItIsWasNotTyped() {
        // The other panel shows a place on the server (say, a tab that a file restored).
        bench.right.show(server.url("/in"))
        bench.left.moveCursor(toName: "one.txt")
        bench.interaction.promptAnswers = [.accept]
        bench.commands.perform(.copy)
        #expect(consent.chosen.isEmpty)
        #expect(server.contents("/in/one.txt") == "one")
    }
}

// A list of files from anywhere says that its entries can only be removed (`.removeOnly`,
// fileops request 12): the commands that make something new in the panel's folder are
// withheld there, and Delete is not.
@MainActor
@Suite
internal struct Review2IntegrationLists {
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
