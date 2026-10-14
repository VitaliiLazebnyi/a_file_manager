import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// What the test file system itself offers of the newer calls, for the plugins' tests.
@Suite
internal struct MemoryFileSystemExtraTests {
    private let memory = MemoryFileSystem()

    /// Appending is offered only with the capability, cuts the file at the offset first, and
    /// keeps or takes the date as told.
    @Test
    internal func aFileIsContinuedWhereItWasCut() throws {
        let file = memory.addFile("/part.bin", "0123456789")
        #expect(throws: FileSystemError.self) { try memory.append(to: file, at: 4, cancellation: CancellationFlag()) }
        memory.capabilities.insert(.append)
        let resumed = try memory.append(to: file, at: 4, cancellation: CancellationFlag())
        #expect(memory.contents("/part.bin") == "0123")
        try resumed.write(Data("abc".utf8))
        try resumed.close(attributes: FileAttributes(modified: Date(timeIntervalSince1970: 5)))
        #expect(memory.contents("/part.bin") == "0123abc")
        #expect(memory.item(at: file)?.modified == Date(timeIntervalSince1970: 5))
        let appended = try memory.append(to: file, at: nil, cancellation: CancellationFlag())
        try appended.write(Data("!".utf8))
        try appended.close(attributes: FileAttributes())
        #expect(memory.contents("/part.bin") == "0123abc!")
        #expect(throws: FileSystemError.self) { try memory.append(to: file, at: 100, cancellation: CancellationFlag()) }
        #expect(throws: MemoryFileSystem.NotFound.self) {
            try memory.append(to: memory.url("/none"), at: 0, cancellation: CancellationFlag())
        }
    }

    /// Commits, quarantine marks and copied metadata are recorded; a commit fails when told to,
    /// and metadata is copied only when the file system keeps it.
    @Test
    internal func commitsMarksAndMetadataAreRecorded() throws {
        let file = memory.addFile("/in/a.txt")
        try memory.commit(memory.url("/in"), cancellation: CancellationFlag())
        memory.commitFailure = FileSystemError.notSupported("Writing the archive")
        #expect(throws: FileSystemError.self) { try memory.commit(memory.url("/in"), cancellation: CancellationFlag()) }
        #expect(memory.commits == ["/in", "/in"])
        #expect(memory.quarantine(of: file) == nil)
        memory.quarantineValue = Data("0081;mark".utf8)
        #expect(memory.quarantine(of: file) == Data("0081;mark".utf8))
        try memory.setQuarantine(Data("0081;mark".utf8), of: file)
        #expect(memory.quarantineMarks == ["/in/a.txt": Data("0081;mark".utf8)])
        #expect(throws: FileSystemError.self) { try memory.copyMetadata(from: file, to: memory.url("/in")) }
        memory.keepsMetadata = true
        try memory.copyMetadata(from: file, to: memory.url("/in"))
        #expect(memory.metadataCopies.map(\.to) == ["/in"])
    }
}
