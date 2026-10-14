import AFMKernel
import Foundation
import TestSupport
import Testing

/// Names and locations: extensions, masks, being inside or the same, and locations built
/// from the text alone.
@Suite
internal struct NameTests {
    /// Checks that the extension is what follows the last dot, never a leading or trailing one.
    @Test
    internal func splitsNameAndExtension() {
        #expect(FileItem.split("report.txt") == ("report", "txt"))
        #expect(FileItem.split("archive.tar.gz") == ("archive.tar", "gz"))
        #expect(FileItem.split(".zshrc") == (".zshrc", ""))
        #expect(FileItem.split("no_extension") == ("no_extension", ""))
        #expect(FileItem.split("trailing.") == ("trailing.", ""))
    }

    /// Checks masks without case, with several patterns, with `?`, and `*.*` for names without
    /// an extension.
    @Test
    internal func fileMasks() {
        #expect(FileMask("*.txt").matches("Report.TXT"))
        #expect(!FileMask("*.txt").matches("report.md"))
        #expect(FileMask("*.txt;*.md").matches("report.md"))
        #expect(FileMask("report_??.*").matches("report_01.txt"))
        #expect(FileMask("*.*").matches("no_extension"))
    }

    /// Checks that a trailing slash does not make another place, that only what lies below is
    /// inside, and that another file system is another place.
    @Test
    internal func locations() {
        let plain = URL(fileURLWithPath: "/tmp/a")
        let slash = URL(fileURLWithPath: "/tmp/a/", isDirectory: true)
        #expect(plain.isSameLocation(as: slash))
        #expect(URL(fileURLWithPath: "/tmp/a/b").isInside(plain))
        #expect(!URL(fileURLWithPath: "/tmp/ab").isInside(plain))
        #expect(!plain.isInside(plain))
        #expect(!plain.isSameLocation(as: MemoryFileSystem().url("/tmp/a")))
    }

    /// The plain Foundation call looks at the disk to decide about a trailing slash, which on a network share is a trip
    /// to the server per file.
    ///
    /// This one works on the text alone: the result is the same whether or not the name exists or is a folder.
    @Test
    internal func buildingTheLocationOfAnEntryNeverAsksTheDisk() {
        let tmp = URL(fileURLWithPath: "/tmp", isDirectory: true)
        #expect(URL(fileURLWithPath: "/", isDirectory: true).appending(name: "tmp").absoluteString == "file:///tmp")
        #expect(tmp.appending(name: "no-such-entry").absoluteString == "file:///tmp/no-such-entry")
        #expect(tmp.appending(name: "a/b c.txt").path == "/tmp/a/b c.txt")
        #expect(URL(fileURLWithPath: "/", isDirectory: true).appending(name: "tmp").isSameLocation(as: tmp))
        #expect(MemoryFileSystem().url("/work").appending(name: "x.txt").path == "/work/x.txt")
    }

    /// Checks that the host and the port are part of the place: one path on two servers, or on
    /// two ports, is two places, and nothing on one server is inside a folder of the other.
    @Test
    internal func theSamePathOnTwoServersIsTwoPlaces() throws {
        let alpha = try #require(URL(string: "sftp://alpha/home/x.txt"))
        let beta = try #require(URL(string: "sftp://beta/home/x.txt"))
        #expect(!alpha.isSameLocation(as: beta))
        let (port22, port2222) = (
            try #require(URL(string: "sftp://alpha:22/home")), try #require(URL(string: "sftp://alpha:2222/home"))
        )
        #expect(!port22.isSameLocation(as: port2222))
        #expect(alpha.isInside(try #require(URL(string: "sftp://alpha/home"))))
        #expect(!alpha.isInside(try #require(URL(string: "sftp://beta/home"))))
    }
}
