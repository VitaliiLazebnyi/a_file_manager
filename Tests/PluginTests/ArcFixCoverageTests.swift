import AFMKernel
import Compression
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The last failure paths of the archives: a coder the system cannot start, and names that
/// lead outside the folder that is unpacked into, met by Unpack's own check.
@Suite
internal struct ArcFixCoverageTests {
    private typealias Support = CoverageArchivesFormatsSupport

    /// A coder the system refuses to start is not supported, both ways.
    @Test(arguments: [true, false])
    internal func aCoderTheSystemCannotStartIsNotSupported(encoding: Bool) {
        let unknown = compression_algorithm(rawValue: 0x7FFF)
        #expect(
            Support.failure { _ = try XZCoder(encoding: encoding, algorithm: unknown) }
                == ArchiveError.unsupported("LZMA compression").errorDescription
        )
    }

    /// Paths that the archive's directory would never let through (an archive's own folder
    /// named `..`, or `/`) are refused by Unpack itself: nothing is made outside the target,
    /// and each says why; the rest of the archive is unpacked.
    @Test
    internal func namesThatLeadOutsideAreRefusedByUnpackItself() throws {
        let bench = try ArchiveBench()
        let box = bench.box
        let url = box.url("names.zip")
        try bench.pack([try box.file("kept.txt", "kept")], to: url)
        let archive = try bench.store.archive(at: url)
        // Put straight into the open archive, past the paths of its file system.
        try archive.makeDirectory("../escape")
        try archive.makeDirectory("/")
        let target = try box.folder("target")
        let result = try bench.unpack(url, to: target)
        let outside = "the name leads outside the folder that is unpacked into"
        #expect(Set(result.problems) == ["..: \(outside)", "../escape: \(outside)", "/: \(outside)"])
        #expect(result.unpacked == 1)
        #expect(try String(contentsOf: target.appendingPathComponent("kept.txt"), encoding: .utf8) == "kept")
        #expect(!FileManager.default.fileExists(atPath: box.url("escape").path))
    }
}
