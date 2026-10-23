import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin
@testable import VirtualFoldersPlugin

/// The viewer reads a file that a branch view names, from a server that stops answering.
@Suite
internal struct ViewerThroughVirtualFolders {
    /// A read that waits on the server ends with an error once its flag is set, and the source
    /// reads again with another flag.
    @Test
    internal func aBlockedReadEndsWhenItsFlagIsSet() throws {
        let memory = MemoryFileSystem()
        let probe = ProbeFileSystem(memory)
        let registry = FileSystemRegistry()
        registry.register(probe)
        let virtual = VirtualFileSystem(fileSystems: registry)
        registry.register(virtual)
        memory.addFile("/far/big.txt", String(repeating: "line of text\n", count: 8_000))
        let gate = DispatchSemaphore(value: 0)
        probe.onRead = { gate.signal() }
        let source = try ProviderByteSource.open(
            virtual.branch(of: memory.url("/far/big.txt")),
            fileSystems: registry,
            cancellation: CancellationFlag()
        )
        memory.stallsReads = true
        let flag = CancellationFlag()
        let outcome = Shared<Result<Data, any Error>?>(nil)
        let finished = DispatchSemaphore(value: 0)
        Thread {
            outcome.value = Result { try source.read(at: 10, count: 5_000, cancellation: flag) }
            finished.signal()
        }
        .start()
        Thread {
            _ = gate.wait(timeout: .now() + Wait.ceiling)
            flag.cancel()
        }
        .start()
        #expect(finished.wait(timeout: .now() + Wait.ceiling) == .success)
        if case .success? = outcome.value { Issue.record("The read was not ended") }
        #expect(memory.interruptions >= 1)
        // The source is usable again afterwards, with another flag.
        memory.stallsReads = false
        #expect(try source.read(at: 0, count: 13, cancellation: CancellationFlag()) == Data("line of text\n".utf8))
    }
}
