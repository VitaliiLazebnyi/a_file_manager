import AFMKernel
import TestSupport
import Testing

@testable import NetworkPlugin
@testable import VirtualFoldersPlugin

/// What is left of a part of the program whose owner has gone while it still had work: it does
/// not read the owner (a read of a reference that is not kept ends the program).
@MainActor
internal struct CrashesLifetimeTests {
    /// The virtual file system outlives its registry when its work still runs (a list prepared in
    /// the background, a listing): then it finds no file systems, and lists nothing.
    @Test
    internal func aVirtualFolderWhoseRegistryHasGoneFindsNoFileSystems() throws {
        let memory = MemoryFileSystem()
        memory.addFile("/A/one.txt")
        var registry: FileSystemRegistry? = FileSystemRegistry()
        let virtual = VirtualFileSystem(fileSystems: try #require(registry))
        registry?.register(memory)
        let branch = virtual.branch(of: memory.url("/A"))
        #expect(try virtual.list(branch, showHidden: false).map(\.name) == ["one.txt"])
        registry = nil
        #expect(throws: (any Error).self) { try virtual.list(branch, showHidden: false) }
        #expect(virtual.volume(of: branch) == nil)
    }

    /// A connection that asks a question after the kernel has gone (a test that ended while it
    /// connected) is refused, and nothing reads the kernel.
    @Test
    internal func questionsOfAConnectionAfterTheKernelHasGoneAreRefused() {
        let plugin = NetworkPlugin(launchesApplications: false, passwords: MemoryPasswords())
        let memory = MemoryFileSystem()
        weak var gone: Kernel?
        do {
            let bench = TestBench(
                plugins: [plugin],
                fileSystems: [memory],
                left: memory.url("/"),
                right: memory.url("/")
            )
            gone = bench.kernel
            #expect(gone != nil)
        }
        #expect(gone == nil)
        let environment = plugin.center.environment
        let profile = ConnectionProfile(key: ServerKey(scheme: "ftp", host: "files.example.com"))
        let certificate = CertificateInfo(fingerprint: "AA:BB", subject: "files", problem: "self-signed")
        #expect(environment.askCredentials(profile, "") == nil)
        #expect(!environment.askToConnect(profile))
        #expect(!environment.askToSendPasswordUnprotected(profile))
        #expect(!environment.askToTrust(profile, certificate))
        #expect(!environment.askToTrustChanged(profile, certificate, ["CC:DD"]))
        #expect(environment.askSecret(profile, "Accept the key?", false) == nil)
    }
}
