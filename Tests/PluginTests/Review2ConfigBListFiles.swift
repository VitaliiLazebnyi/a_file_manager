import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import VirtualFoldersPlugin

/// List files of names (review 2): line breaks, old files, size and schemes.
@Suite
internal struct Review2ConfigBListFiles {
    /// Names with line breaks and other awkward characters survive a list file.
    @Test
    internal func namesWithLineBreaksSurviveAListFile() {
        let names = [
            "/tmp/plain.txt", "/tmp/with\nbreak.txt", "/tmp/with\r\nboth", "/tmp/tab\there", " /tmp/leading",
            "/tmp/trailing ", "\"/quoted\"",
            "/tmp/back\\slash", "/tmp/ctrl\u{7}bell", "/tmp/sep\u{2028}line"
        ]
        let text = FileListFile.text(for: names)
        #expect(!text.contains("with\nbreak"))
        #expect(FileListFile.lines(in: Data(text.utf8)) == names)
    }

    /// Old list files, without escapes, are read as they were.
    @Test
    internal func oldListFilesAreReadAsTheyWere() {
        let old = "/a/b.txt\r\nC:\\dir\\file.txt\n  /spaced/path  \n\"half\n\\n/not/an/escape\n\"/with\\q\"\n"
        #expect(
            FileListFile.lines(in: Data(old.utf8)) == [
                "/a/b.txt", "C:\\dir\\file.txt", "/spaced/path", "\"half", "\\n/not/an/escape", "\"/with\\q\""
            ]
        )
    }

    /// A list file over the line limit is refused; of a small one only its own and local locations are taken.
    @Test
    internal func aHugeListFileIsRefused() throws {
        let memory = MemoryFileSystem()
        let registry = FileSystemRegistry()
        registry.register(memory)
        registry.register(LocalFileSystem())
        registry.register(Review2WatchFileSystem(scheme: "sftp"))
        memory.addFile("/L/big.lst", String(repeating: "/x\n", count: FileListFile.lineLimit + 1))
        #expect(throws: (any Error).self) {
            _ = try FileListFile.read(memory.url("/L/big.lst"), fileSystems: registry, relativeTo: memory.url("/L"))
        }
        memory.addFile("/L/small.lst", "mem:/A/one\n/Users/x/local\nsftp://evil.example/x\n")
        let urls =
            (try? FileListFile.read(memory.url("/L/small.lst"), fileSystems: registry, relativeTo: memory.url("/L")))
            ?? []
        // The file's own file system and local files only: no connection is made for the third line.
        #expect(urls.count == 2 && !urls.contains { $0.scheme == "sftp" })
    }
}
