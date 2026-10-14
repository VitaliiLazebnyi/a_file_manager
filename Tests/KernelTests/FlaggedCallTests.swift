import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// The file-system calls that take a cancellation flag (review 2, second pass): what the
/// kernel's defaults do with the flag, and what a file system that says no more gets.
@Suite
internal struct FlaggedCallTests {
    /// A file system that offers only the plain copy, of the memory file system's files; the
    /// copy with a flag is the kernel's default.
    internal final class PlainCopier: ListingOnly {
        /// `plain`.
        internal let scheme = "plain"
        /// Writing.
        internal let capabilities: FileSystemCapabilities = [.write]
        /// Where the files are.
        internal let memory: MemoryFileSystem

        /// Copies the files of `memory`.
        internal init(_ memory: MemoryFileSystem) { self.memory = memory }

        /// Every folder is empty.
        internal func list(_: URL, showHidden _: Bool) -> [FileItem] { [] }

        /// There is no folder above.
        internal func parent(of _: URL) -> URL? { nil }

        /// Copies the file of the same path in `memory`.
        internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
            try memory.copy(memory.url(source.path), to: memory.url(destination.path), progress: progress)
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The kernel's copy with a flag begins nothing when the flag is set before, stops at the next
    /// block when somebody else sets it during the copy, and copies when it is left alone.
    @Test
    internal func aCopyWithAFlagStopsWhenTheFlagIsSetAndSaysSo() throws {
        let memory = MemoryFileSystem()
        memory.copyBlockSize = 4
        memory.addFile("/a.bin", String(repeating: "x", count: 64))
        let provider: any FileSystemProvider = PlainCopier(memory)
        let from = try #require(URL(string: "plain:///a.bin"))
        let target = try #require(URL(string: "plain:///b.bin"))
        // Set before the call: nothing is begun.
        let set = CancellationFlag()
        set.cancel()
        var asked = 0
        #expect(throws: CocoaError.self) {
            try provider.copy(from, to: target, cancellation: set) { _ in
                asked += 1
                return true
            }
        }
        #expect(asked == 0)
        #expect(!memory.exists("/b.bin"))
        // Set while it runs, by somebody other than `progress`: the copy stops at the next block.
        let flag = CancellationFlag()
        var reports: [Int64] = []
        #expect(throws: CocoaError.self) {
            try provider.copy(from, to: target, cancellation: flag) { copied in
                reports.append(copied)
                if copied == 12 {
                    flag.cancel()
                }
                return true
            }
        }
        #expect(reports == [4, 8, 12])
        #expect(!memory.exists("/b.bin"))
        // Left alone, it copies.
        try provider.copy(from, to: target, cancellation: CancellationFlag()) { _ in true }
        #expect(memory.contents("/b.bin")?.count == 64)
    }

    /// An exclusive folder is refused where something has its name; without `exclusive` it is
    /// made as before, with the flag passed on, and a flag set beforehand makes nothing.
    @Test
    internal func aFolderThatMustBeNewIsRefusedWhenSomethingHasItsName() throws {
        let memory = MemoryFileSystem()
        let provider: any FileSystemProvider = memory
        try provider.createDirectory(at: memory.url("/new/inner"), exclusive: true, cancellation: CancellationFlag())
        #expect(memory.exists("/new/inner"))
        #expect(throws: FileSystemError.self) {
            try provider.createDirectory(
                at: memory.url("/new/inner"),
                exclusive: true,
                cancellation: CancellationFlag()
            )
        }
        // Not exclusive: as before, with the flag passed on.
        try provider.createDirectory(at: memory.url("/new/inner"), exclusive: false, cancellation: CancellationFlag())
        #expect(memory.flaggedChanges == ["createDirectory /new/inner"])
        let set = CancellationFlag()
        set.cancel()
        #expect(throws: CocoaError.self) {
            try provider.createDirectory(at: memory.url("/other"), exclusive: true, cancellation: set)
        }
        #expect(!memory.exists("/other"))
    }

    /// The default commit with progress asks once, (0, 0), and does not commit when its progress
    /// or its flag says stop; removing below a root is plain removing without links.
    @Test
    internal func aCommitAsksItsProgressOnceWhereAFileSystemSaysNoMore() throws {
        let memory = MemoryFileSystem()
        memory.addFile("/a.txt")
        let provider: any FileSystemProvider = memory
        var reports: [Int64] = []
        try provider.commit(memory.url("/"), cancellation: CancellationFlag()) { done, total in
            reports += [done, total]
            return true
        }
        #expect(reports == [0, 0])
        #expect(memory.commits == ["/"])
        // Stopped by its progress, or by its flag: not committed.
        #expect(throws: CocoaError.self) {
            try provider.commit(memory.url("/"), cancellation: CancellationFlag()) { _, _ in false }
        }
        let set = CancellationFlag()
        set.cancel()
        #expect(throws: CocoaError.self) { try provider.commit(memory.url("/"), cancellation: set) { _, _ in true } }
        #expect(memory.commits == ["/"])
        // Deleting below a root is plain deleting where a file system knows no links.
        try provider.remove(memory.url("/a.txt"), below: memory.url("/"), cancellation: CancellationFlag())
        #expect(!memory.exists("/a.txt"))
        #expect(memory.flaggedChanges == ["remove below / /a.txt"])
        #expect(FileSystemCapabilities([.write, .removeOnly]).contains(.removeOnly))
        #expect(!memory.capabilities.contains(.removeOnly))
    }
}
