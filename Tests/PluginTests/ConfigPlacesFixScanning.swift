import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import PlacesPlugin

/// A scan with the lean reader on the real disk, and its paths.
@Suite
internal struct ConfigPlacesFixScanning {
    /// The lean reader of the disk lists folders sorted and leaves out files, packages, links and, unless
    /// shown, hidden folders.
    @Test
    internal func theLeanReaderHonoursHiddenFoldersPackagesAndLinks() throws {
        let box = try Sandbox()
        try box.folder("b/inner")
        try box.folder("a")
        try box.folder(".hid/in")
        try box.folder("Some.app/Contents")
        try box.file("file.txt")
        try box.file("b/inner/file.txt")
        try FileManager.default.createSymbolicLink(at: box.url("link"), withDestinationURL: box.url("a"))
        for hidden in [false, true] {
            let scanner = TreeScanner(root: box.root, provider: LocalFileSystem(), showHidden: hidden)
            var levels: [TreeScanner.Level] = []
            #expect(scanner.run { levels += $0 })
            #expect(
                levels.first?.children == (hidden ? [".hid", "a", "b"] : ["a", "b"]) && levels.allSatisfy(\.isSorted)
            )
            #expect(
                scanner.paths == (hidden ? [".hid", "a", "b", ".hid/in", "b/inner"] : ["a", "b", "b/inner"])
                    && scanner.unscanned.isEmpty
            )
        }
    }

    /// Folders left out and folders a stopped scan did not reach are recorded as unread.
    @Test
    internal func excludedAndUnreachedFoldersAreRecorded() {
        let memory = MemoryFileSystem()
        memory.addDirectory("/V/Volumes/Other")
        memory.addDirectory("/V/keep/inner")
        let excluded = memory.url("/V/Volumes").locationKey
        let scanner = TreeScanner(root: memory.url("/V"), provider: memory) { $0.locationKey == excluded }
        let completed = scanner.run { _ in
            // What it found is checked below.
        }
        #expect(completed)
        #expect(scanner.paths == ["keep", "Volumes", "keep/inner"] && scanner.unscanned == ["Volumes"])

        let stopped = TreeScanner(root: memory.url("/V"), provider: memory, batchSize: 1)
        #expect(!stopped.run { _ in stopped.cancellation.cancel() })
        #expect(stopped.unscanned.contains("keep") && !stopped.paths.isEmpty)
    }
}
