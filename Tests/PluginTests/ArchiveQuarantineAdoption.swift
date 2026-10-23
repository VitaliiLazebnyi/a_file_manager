import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The kernel's quarantine, as the archives adopt it: members carry the mark of the file the archive lies in.
@Suite
internal struct ArchiveQuarantineAdoption: ArchiveFixSuite {
    /// The archive file systems and the sandbox of the test.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// Members carry the quarantine mark of their archive, the outermost one for nested archives, so that a copy can
    /// pass it on.
    @Test
    internal func membersCarryTheMarkOfTheirArchiveSoThatACopyCanPassItOn() throws {
        let archive = try makeZip()
        let value = "0083;65f0a1b2;Safari;F643CD5F-6071-46AB-83AB-390BA944DEC5"
        mark(archive, with: value)
        let member = bench.inside(archive, "tree/readme.txt")
        #expect(bench.zip.quarantine(of: member) == Data(value.utf8))
        #expect(
            bench.readOnly.quarantine(of: bench.inside(archive, "tree", scheme: ArchiveURL.readOnlyScheme))
                == Data(value.utf8)
        )
        // Read once for the open archive.
        removexattr(archive.path, "com.apple.quarantine", 0)
        #expect(bench.zip.quarantine(of: member) == Data(value.utf8))
        // What Unpack puts on the files is the same value: files are not marked twice differently.
        let result = try bench.unpack(archive, to: box.url("out"))
        #expect(result.problems.isEmpty && quarantineMark(of: box.url("out/tree/readme.txt")) == value)

        // An archive inside an archive has the outermost file's mark; one without has none.
        try bench.pack([box.url("tree")], to: box.url("inner.tar")) { $0.format = .tar }
        try bench.pack([box.url("inner.tar")], to: box.url("outer.zip"))
        mark(box.url("outer.zip"), with: value)
        let inner = bench.inside(box.url("outer.zip"), "inner.tar", scheme: ArchiveURL.readOnlyScheme)
        #expect(bench.readOnly.quarantine(of: inner.appending(name: "tree")) == Data(value.utf8))
        #expect(bench.zip.quarantine(of: bench.inside(try makeZip("clean.zip"), "tree")) == nil)
    }

    /// The quarantine mark of an archive on another file system is that file system's word, and places outside the
    /// archive are marked there.
    @Test
    internal func theMarkOfAnArchiveOnAnotherFileSystemIsThatFileSystemsWord() throws {
        let tree = try bench.makeTree()
        let onServer = bench.memory.url("/store/tree.zip")
        try bench.pack([tree], to: onServer)
        bench.memory.quarantineValue = Data("0081;downloaded".utf8)
        let root = ArchiveURL.make(scheme: "zip", archive: onServer, innerPath: "")
        #expect(bench.zip.quarantine(of: root.appending(name: "tree")) == Data("0081;downloaded".utf8))
        // For places outside the archive the file system is asked, and marked.
        let place = try outside(root, "/store/other.txt")
        #expect(bench.zip.quarantine(of: place) == Data("0081;downloaded".utf8))
        _ = bench.memory.addFile("/store/other.txt", "x")
        try bench.zip.setQuarantine(Data("0081;mark".utf8), of: place)
        #expect(bench.memory.quarantineMarks == ["/store/other.txt": Data("0081;mark".utf8)])
        // Inside the archive nothing can carry one.
        try bench.zip.setQuarantine(Data("0081;mark".utf8), of: root.appending(name: "tree"))
        #expect(bench.memory.quarantineMarks.count == 1)
    }
}
