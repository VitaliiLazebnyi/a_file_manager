import AFMContracts
import AFMKernel
import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

/// Review round 2, integration: an address the user types into a dialog is reported to the
/// plugin that connects to servers (N071), so that only addresses that came out of files are
/// asked "Connect to X?".
@MainActor
@Suite
internal struct Review2IntegrationTypedAddresses {
    /// Notes what it is told the user chose.
    internal final class Consent: ServerConsentService {
        /// The addresses the user chose, in that order.
        internal private(set) var chosen: [URL] = []

        /// Notes `location` as chosen.
        internal func userChose(_ location: URL) { chosen.append(location) }

        deinit {
            // Nothing to release.
        }
    }

    /// The panels' file system, in memory: `/A/one.txt` and an empty `/B`.
    internal let memory = MemoryFileSystem()
    /// A server's file system, in memory, with an empty `/in`.
    internal let server = MemoryFileSystem(scheme: "srv")
    /// The consent service the kernel reports typed addresses to.
    internal let consent = Consent()
    /// The kernel with the file operations, both file systems and the consent service.
    internal let bench: TestBench

    /// Panels on `/A` and `/B`, with the consent service registered.
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

    /// Only typed text that is an address and is not what the program proposed is reported.
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

    /// A server typed as the target of a copy is reported as the user's own choice, and the copy
    /// goes there.
    @Test
    internal func aTargetTypedIntoTheCopyDialogIsTheUsersOwnChoice() {
        bench.left.moveCursor(toName: "one.txt")
        bench.interaction.promptAnswers = [.text("srv://in/")]
        bench.commands.perform(.copy)
        #expect(consent.chosen.count == 1 && consent.chosen.first?.scheme == "srv")
        #expect(server.contents("/in/one.txt") == "one")
    }

    /// A server the copy dialog proposed and the user accepted as it was is not reported.
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
