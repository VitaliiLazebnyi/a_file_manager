import Foundation
import Testing

@testable import ArchivesPlugin

/// The URLs of the archive file systems read back from text this code did not write, and
/// what the formats and errors say of themselves.
@Suite
internal struct CoverageArchivesFSLocationTests {
    /// An archive URL with `host` in place of the one `ArchiveURL.make` writes.
    private static func url(host: String, path: String = "/a.zip/x") throws -> URL {
        var components = URLComponents()
        components.scheme = ArchiveURL.writableScheme
        components.host = host
        components.path = path
        return try #require(components.url)
    }

    private static func hex(_ text: String) -> String {
        text.utf8.map { String(format: "%02x", $0) }.joined()
    }

    /// A URL without a scheme is no archive URL.
    @Test
    internal func aURLWithoutASchemeIsNoArchiveURL() throws {
        #expect(!ArchiveURL.isArchiveURL(try #require(URL(string: "relative/a.zip"))))
    }

    /// A host whose third part is not the hexadecimal text of a URL prefix is not read.
    @Test
    internal func aHostWhosePrefixIsNotHexadecimalIsNotRead() throws {
        let made = ArchiveURL.make(
            scheme: ArchiveURL.writableScheme,
            archive: try #require(URL(string: "ftp://server/a.zip"))
        )
        let parts = try #require(made.host).split(separator: "-")
        #expect(parts.count == 3 && ArchiveURL.parse(made) != nil)
        // An odd number of digits, a character that is no digit, and bytes that are no UTF-8.
        for prefix in ["abc", "zz", "ff"] {
            #expect(ArchiveURL.parse(try Self.url(host: "\(parts[0])-\(parts[1])-\(prefix)")) == nil)
        }
    }

    /// A prefix that is hexadecimal text, but of something that is no URL, is not read.
    @Test
    internal func aPrefixThatIsNoURLIsNotRead() throws {
        let host = "d1-00000000-" + Self.hex("http://[broken")
        #expect(ArchiveURL.parse(try Self.url(host: host)) == nil)
    }

    /// An archive whose URL has no authority (or no scheme) is named by its scheme alone, and
    /// read back as such.
    @Test
    internal func anArchiveWithoutAnAuthorityIsNamedByItsSchemeAlone() throws {
        let opaque = try #require(URL(string: "x:/folder/a.zip"))
        let made = ArchiveURL.make(scheme: ArchiveURL.writableScheme, archive: opaque, innerPath: "inner")
        let expected = try #require(URL(string: "x:///folder/a.zip"))
        #expect(ArchiveURL.parse(made) == .inside(ArchiveLocation(archive: expected, innerPath: "inner")))
        let relative = try #require(URL(string: "folder/a.zip"))
        let local = ArchiveURL.make(scheme: ArchiveURL.writableScheme, archive: relative)
        #expect(ArchiveURL.location(of: local)?.archive.isFileURL == true)
    }

    /// Archives that only the system's tools read have no ending of their own and cannot be
    /// changed.
    @Test
    internal func otherArchivesHaveNoEndingOfTheirOwn() {
        let foreign = ArchiveFormat.foreign
        #expect(foreign.title == "archive" && foreign.defaultExtension.isEmpty && foreign.extensions.isEmpty)
        #expect(!foreign.isEditable && foreign.prefix.isEmpty)
    }

    /// Every error says in words what happened.
    @Test
    internal func everyErrorSaysWhatHappened() {
        let cases: [(ArchiveError, String)] = [
            (.wrongPassword("a.zip"), "Wrong password for a.zip."),
            (.notFound("x/y"), "x/y does not exist in the archive."),
            (.notADirectory("x"), "x is not a folder."),
            (.readOnly("a.7z"), "Archives of this type cannot be changed (a.7z)."),
            (
                .noScratchRoom("big.zip"),
                "There is not enough room on the startup disk to open big.zip: it has to be copied there first."
            ),
            (
                .nameCollision("x.txt"),
                "Several files would be stored under the name x.txt. Pack with path names, or pack them one by one."
            ),
            (.toolFailed("bsdtar failed."), "bsdtar failed."),
            (.retired, "The archive was read again; please repeat the operation.")
        ]
        for (error, text) in cases {
            #expect(error.errorDescription == text)
        }
    }
}
