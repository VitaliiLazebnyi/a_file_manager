import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import VirtualFoldersPlugin

/// The pure parts of virtual folders beyond the other suites: locations that are not ours,
/// list files that are damaged or too large, and the corners of a branch walk.
@Suite
internal struct CoverageVirtualFormats {
    /// The hex labels a location writes for a prefix.
    private func hex(_ text: String) -> String {
        text.utf8.map { String(format: "%02x", $0) }.joined()
    }

    /// A URL from a text the test knows to be one.
    private func url(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    /// Locations whose host or prefix is not one of ours are not virtual; one without a path is
    /// the root.
    @Test
    internal func locationsThatAreNotOurs() throws {
        #expect(VirtualLocation(try url("vfolder://./x")) == nil)
        #expect(VirtualLocation(try url("vfolder://branch.h" + hex("sftp://h/p") + "/x")) == nil)
        #expect(VirtualLocation(try url("vfolder://pick.h" + hex("file://") + "/x")) == nil)
        #expect(VirtualLocation(try url("vfolder://branch.h666/x")) == nil)
        let root = VirtualLocation(try url("vfolder://branch.h" + hex("file://")))
        #expect(root == .branch(real: URL(fileURLWithPath: "/", isDirectory: false)))
    }

    /// A list knows it is one; a location without an authority keeps having none.
    @Test
    internal func listsAndLocationsWithoutAuthority() throws {
        #expect(VirtualLocation.list(id: 1, title: "T", origin: nil).isList)
        #expect(!VirtualLocation.branch(real: URL(fileURLWithPath: "/")).isList)
        let plain = try url("x:/a/b")
        let back = VirtualLocation(VirtualLocation.branch(real: plain).url)?.realDirectory
        #expect(back?.scheme == "x" && back?.path == "/a/b")
        let bare = try url("sftp://host")
        #expect(VirtualLocation(VirtualLocation.branch(real: bare).url)?.realDirectory?.path == "/")
    }

    /// Lines that are not text in UTF-8 are read as Latin-1; UTF-16 that does not read is no
    /// lines at all; empty lines are skipped.
    @Test
    internal func linesInOtherEncodings() {
        #expect(FileListFile.lines(in: Data([0xE9, 0x0A, 0x20, 0x20, 0x0A, 0x61])) == ["é", "a"])
        #expect(FileListFile.lines(in: Data([0xFF, 0xFE, 0x00, 0xD8])).isEmpty)
    }

    /// A quoted line with a quote inside or an escape that is not ours is taken as it stands.
    @Test
    internal func damagedQuotedLinesAreTakenAsTheyStand() {
        for damaged in [
            "\"a\"b\"", "\"a\\\"", "\"\\u41\"", "\"\\u{41\"", "\"\\u{zz}\"", "\"\\u{D800}\"", "\"\\q\""
        ] {
            #expect(FileListFile.unquoted(damaged) == nil, "\(damaged)")
            #expect(FileListFile.lines(in: Data(damaged.utf8)) == [damaged], "\(damaged)")
        }
    }

    /// A name that needs quotes has its backslashes escaped; no names make an empty file.
    @Test
    internal func namesWithBackslashesAndNoNames() {
        let line = FileListFile.line(for: " a\\b")
        #expect(line == "\" a\\\\b\"" && FileListFile.unquoted(line) == " a\\b")
        #expect(FileListFile.text(for: []).isEmpty)
    }

    /// A list file larger than the limit is refused; local files named in it are taken.
    @Test
    internal func largeListFilesAreRefusedAndLocalFilesTaken() throws {
        let memory = MemoryFileSystem()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        fileSystems.register(memory)
        memory.addFile("/big.txt", String(repeating: "x", count: FileListFile.sizeLimit + 1))
        #expect(throws: FileListFile.TooLarge.self) {
            try FileListFile.read(memory.url("/big.txt"), fileSystems: fileSystems, relativeTo: memory.url("/"))
        }
        #expect(FileListFile.TooLarge().errorDescription == "The list of files is too large to load.")
        memory.addFile("/local.txt", "file:///tmp/a.txt\n")
        let files = try FileListFile.read(
            memory.url("/local.txt"),
            fileSystems: fileSystems,
            relativeTo: memory.url("/")
        )
        #expect(files.map(\.path) == ["/tmp/a.txt"])
    }

    /// A path that is no mount point, and one that is not there, is not one.
    @Test
    internal func mountPoints() {
        #expect(BranchWalker.isMountPoint("/"))
        #expect(!BranchWalker.isMountPoint("/afm-there-is-no-such-folder"))
    }

    /// A walk from the root leaves the folders where other disks are mounted; a folder that is
    /// a start of its own is not walked a second time from its parent.
    @Test
    internal func walksLeaveMountFoldersAndFoldersSeenBefore() throws {
        let local = FileSystemRegistry()
        local.register(LocalFileSystem())
        var first: [String] = []
        try BranchWalker(fileSystems: local, showHidden: true, listsFolders: true)
            .walk([BranchWalker.Start(URL(fileURLWithPath: "/"))]) { batch in
                first = batch.map(\.name)
                return false
            }
        #expect(first.contains("Volumes") && first.contains("Users"))
        let box = try Sandbox()
        try box.file("A/sub/deep.txt")
        var names: [String] = []
        try BranchWalker(fileSystems: local, showHidden: false)
            .walk([BranchWalker.Start(box.url("A")), BranchWalker.Start(box.url("A/sub"), prefix: "sub/")]) { batch in
                names += batch.map(\.name)
                return true
            }
        #expect(names == ["sub/deep.txt"])
    }

    /// A walk cancelled while it hands over a batch stops before the next one.
    @Test
    internal func aWalkCancelledBetweenBatchesStops() throws {
        let memory = MemoryFileSystem()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(memory)
        for index in 0...BranchWalker.directoriesPerBatch { memory.addFile("/T/d\(index)/f.txt") }
        let flag = CancellationFlag()
        var batches = 0
        let visited = try BranchWalker(fileSystems: fileSystems, showHidden: false)
            .walk([BranchWalker.Start(memory.url("/T"))], cancellation: flag) { _ in
                batches += 1
                flag.cancel()
                return true
            }
        // The folder itself and the first batch of its folders were read; the rest was not.
        #expect(batches == 1 && visited.count == BranchWalker.directoriesPerBatch + 1)
    }

    /// The part in front of a real path keeps a user, an IPv6 host and a port; a location
    /// without a scheme is taken as a local one.
    @Test
    internal func prefixesOfEveryKind() throws {
        let server = try url("sftp://us%40er@[::1]:22/srv")
        #expect(
            VirtualLocation(VirtualLocation.branch(real: server).url)?.realDirectory?.absoluteString
                == "sftp://us%40er@[::1]:22/srv"
        )
        let relative = try url("a/b")
        #expect(VirtualLocation(VirtualLocation.branch(real: relative).url)?.realDirectory?.isFileURL == true)
    }

    /// A walk that crosses disks passes over a folder where a disk is mounted, and walks into a
    /// folder of another disk that is no mount point (a firmlink).
    @Test
    internal func mountedFoldersAreLeftOut() throws {
        let box = try Sandbox()
        try box.file("L/top.txt")
        try box.file("L/mnt/inside.txt")
        try box.file("L/firm/linked.txt")
        let local = FileSystemRegistry()
        local.register(LocalFileSystem())
        var walker = BranchWalker(fileSystems: local, showHidden: false)
        let system = VolumeProbe.system
        walker.volumes = VolumeProbe(
            identity: { path, follows in
                system.identity(path, follows)
                    .map { path.hasSuffix("/mnt") || path.hasSuffix("/firm") ? (99, $0.inode) : $0 }
            },
            isMountPoint: { $0.hasSuffix("/mnt") },
            crossesDisks: { _ in true }
        )
        var names: [String] = []
        try walker.walk([BranchWalker.Start(box.url("L"))]) { batch in
            names += batch.map(\.name)
            return true
        }
        #expect(names.sorted() == ["firm/linked.txt", "top.txt"])
    }
}
