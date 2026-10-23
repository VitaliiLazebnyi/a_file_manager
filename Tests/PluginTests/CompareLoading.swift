import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import CompareContentPlugin

/// Loading two files through their file systems, checking them for being identical, and saving.
@Suite
internal struct CompareLoading {
    /// The local and the memory file system.
    internal let fileSystems = FileSystemRegistry()
    /// The files in memory.
    internal let memory = MemoryFileSystem()

    /// Both file systems, no files yet.
    internal init() {
        fileSystems.register(LocalFileSystem())
        fileSystems.register(memory)
    }

    /// Two text files are loaded and compared.
    @Test
    internal func textFilesAreLoadedAndCompared() {
        memory.addFile("/a.txt", "one\ntwo\nthree\n")
        memory.addFile("/b.txt", "one\n2\nthree\nfour\n")
        let result = CompareLoader.load(
            left: memory.url("/a.txt"),
            right: memory.url("/b.txt"),
            fileSystems: fileSystems
        )
        guard case .text(let left, let right, let diff, let width) = result.content else {
            Issue.record("not a text comparison")
            return
        }
        #expect(!result.isIdentical && result.message == nil && left.lines.count == 3 && right.lines.count == 4)
        #expect(diff.blocks == [1..<2, 3..<4] && width == 5)
    }

    /// Identical, binary, missing and cancelled loads.
    @Test
    internal func identicalAndBinaryAndMissingFiles() {
        memory.addFile("/a.txt", "same\n")
        memory.addFile("/b.txt", "same\n")
        memory.addFile("/c.txt", "SAME\n")
        memory.addFile("/x.bin", "ab\u{0}cd")
        memory.addDirectory("/folder")
        func load(_ left: String, _ right: String, binary: Bool = false) -> ComparedFiles {
            CompareLoader.load(
                left: memory.url(left),
                right: memory.url(right),
                fileSystems: fileSystems,
                forceBinary: binary,
                bytesPerLine: 8
            )
        }
        #expect(load("/a.txt", "/b.txt").isIdentical)
        // Equal for the options, but not the same content.
        let folded = load("/a.txt", "/c.txt")
        if case .text(_, _, let diff, _) = folded.content {
            #expect(diff.isIdentical)
        } else {
            Issue.record("not text")
        }
        #expect(!folded.isIdentical)

        if case .binary(_, _, let diff) = load("/x.bin", "/a.txt").content {
            #expect(diff.differingBytes == 5)
        } else {
            Issue.record("not binary")
        }
        if case .binary(_, _, let diff) = load("/a.txt", "/c.txt", binary: true).content {
            #expect(diff.differingBytes == 4 && diff.bytesPerLine == 8)
        } else {
            Issue.record("not binary")
        }
        #expect(load("/a.txt", "/missing.txt").message == "mem:/missing.txt is not a file.")
        #expect(load("/folder", "/a.txt").message == "mem:/folder is not a file.")
        let cancelled = CancellationFlag()
        cancelled.cancel()
        #expect(
            CompareLoader.load(
                left: memory.url("/a.txt"),
                right: memory.url("/c.txt"),
                fileSystems: fileSystems,
                cancellation: cancelled
            )
            .wasCancelled
        )
    }

    /// Large local files are checked for being identical in stretches on all cores.
    @Test
    internal func largeLocalFilesAreCheckedInStretchesOnAllCores() throws {
        let box = try Sandbox()
        var random = DiffChecks.Seeded(state: 1)
        var data = Data(count: 1_000_003)
        data.withUnsafeMutableBytes { bytes in
            for index in 0..<bytes.count { bytes[index] = UInt8(truncatingIfNeeded: random.next()) }
        }
        var lastByte = data
        lastByte[data.count - 1] ^= 1
        var middle = data
        middle[500_000] ^= 1
        for (name, content) in [("a", data), ("same", data), ("last", lastByte), ("middle", middle)] {
            try content.write(to: box.url(name))
        }
        func identical(_ name: String, stretch: Int = 64 * 1_024, _ flag: CancellationFlag = CancellationFlag()) throws
            -> Bool
        {
            try CompareLoader.identical(
                box.url("a"),
                box.url(name),
                size: Int64(data.count),
                fileSystems: fileSystems,
                cancellation: flag,
                stretch: stretch
            )
        }
        #expect(try identical("same") == true && identical("last") == false && identical("middle") == false)
        #expect(try identical("same", stretch: 1_000_003) == true && identical("last", stretch: 7_777) == false)
        let flag = CancellationFlag()
        flag.cancel()
        #expect(throws: CancellationError.self) { try identical("same", flag) }
        #expect(throws: (any Error).self) { try identical("missing") }
    }

    /// Files elsewhere are read once side by side, and in stretches where the file system is local.
    @Test
    internal func filesElsewhereAreReadOnceSideBySide() throws {
        memory.isLocal = false
        let text = String(repeating: "0123456789abcdef", count: 200_000)
        memory.addFile("/a", text)
        memory.addFile("/b", text)
        memory.addFile("/c", text.dropLast() + "!")
        func identical(_ name: String) throws -> Bool {
            try CompareLoader.identical(
                memory.url("/a"),
                memory.url(name),
                size: Int64(text.utf8.count),
                fileSystems: fileSystems,
                stretch: 4_096
            )
        }
        #expect(try identical("/b") == true && identical("/c") == false)
        // The same through the stretches, when the file system says it is local.
        memory.isLocal = true
        #expect(try identical("/b") == true && identical("/c") == false)
    }

    /// Saving replaces the file, keeps its permissions and leaves nothing behind.
    @Test
    internal func savingReplacesTheFileAndLeavesNothingBehind() throws {
        memory.addFile("/dir/file.txt", "old content", permissions: 0o600)
        try CompareLoader.replace(
            memory.url("/dir/file.txt"),
            with: Data("new content".utf8),
            fileSystems: fileSystems
        )
        #expect(memory.contents("/dir/file.txt") == "new content" && memory.allPaths == ["/dir", "/dir/file.txt"])
        #expect(memory.item(at: memory.url("/dir/file.txt"))?.permissions == 0o600)
        // A file that has gone meanwhile is written anew.
        try CompareLoader.replace(memory.url("/dir/fresh.txt"), with: Data("x".utf8), fileSystems: fileSystems)
        #expect(memory.contents("/dir/fresh.txt") == "x")
        #expect(throws: (any Error).self) {
            try CompareLoader.replace(memory.url("/nowhere/file.txt"), with: Data(), fileSystems: fileSystems)
        }

        let box = try Sandbox()
        try box.file("on-disk.txt", "before")
        try CompareLoader.replace(box.url("on-disk.txt"), with: Data("after".utf8), fileSystems: fileSystems)
        #expect(box.read("on-disk.txt") == "after" && namesOnDisk(box.root) == ["on-disk.txt"])
    }
}
