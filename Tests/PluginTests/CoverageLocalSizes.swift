import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// Adding up a tree: without bulk reads, a read that fails half way, a caller that stops.
@Suite
internal struct CoverageLocalSizes {
    /// A tree without bulk reads is measured by listing.
    @Test
    internal func aTreeWithoutBulkReadsIsMeasuredByListing() throws {
        let box = try Sandbox()
        try box.file("a.txt", "12345")
        try box.file("sub/b.txt", "123")
        let everywhere = CoverageLocalProbes.failing("getattrlistbulk", endingIn: "", ENOTSUP)
        #expect(everywhere.totalSize(of: box.root, cancellation: CancellationFlag()) == 8)
        let below = CoverageLocalProbes.failing("getattrlistbulk", endingIn: "/sub", ENOTSUP)
        #expect(below.totalSize(of: box.root, cancellation: CancellationFlag()) == 8)
    }

    /// A folder whose read fails half way counts as nothing.
    @Test
    internal func aFolderWhoseReadFailsHalfWayCountsAsNothing() throws {
        let box = try Sandbox()
        try box.file("a.txt", "12345")
        let local = CoverageLocalProbes.failing("getattrlistbulk", endingIn: box.root.lastPathComponent, EIO, after: 1)
        #expect(local.totalSize(of: box.root, cancellation: CancellationFlag()) == 0)
        // A read that a signal nobody sent ended is made again.
        let once = Shared(false)
        var probes = LocalProbes()
        probes.fault = { call, _ in
            guard call == "getattrlistbulk", !once.value else {
                return nil
            }
            once.value = true
            return EINTR
        }
        #expect(LocalFileSystem(probes: probes).totalSize(of: box.root, cancellation: CancellationFlag()) == 5)
    }

    /// A measurement stopped at a folder counts nothing more.
    @Test
    internal func aMeasurementStoppedAtAFolderCountsNothingMore() throws {
        let box = try Sandbox()
        try box.file("a.txt", "12345")
        let flag = CancellationFlag()
        var probes = LocalProbes()
        probes.willAsk = { _ in flag.cancel() }
        #expect(LocalFileSystem(probes: probes).totalSize(of: box.root, cancellation: flag) == 0)
    }

    /// An entry counts for what it is.
    @Test
    internal func anEntryCountsForWhatItIs() throws {
        let box = try Sandbox()
        try box.file("f.txt", "1234")
        try box.folder("d")
        var entry = LocalFileSystem.Entry()
        #expect(LocalFileSystem.measured(entry, in: box.root.path) == nil)
        entry.name = "x"
        entry.type = VDIR.rawValue
        #expect(LocalFileSystem.measured(entry, in: "/")?.folder == "/x")
        entry.type = VLNK.rawValue
        #expect(LocalFileSystem.measured(entry, in: box.root.path) == nil)
        entry.failed = true
        entry.name = "f.txt"
        let file = LocalFileSystem.measured(entry, in: box.root.path)
        #expect(file?.folder == nil && file?.size == 4)
        entry.name = "d"
        #expect(LocalFileSystem.measured(entry, in: box.root.path)?.folder == box.url("d").path)
        entry.name = "gone"
        #expect(LocalFileSystem.measured(entry, in: box.root.path) == nil)
    }
}
