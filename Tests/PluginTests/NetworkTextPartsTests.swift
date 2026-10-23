import AFMKernel
import Foundation
import Testing

@testable import NetworkPlugin

/// The other pure pieces: line ends, name encodings, download lists and mounted volumes.
@Suite
internal struct NetworkTextPartsTests {
    /// ASCII transfers turn CR LF into LF and back, also when a line end is split between blocks.
    @Test
    internal func lineEnds() {
        var incoming = LineEndConverter()
        #expect(incoming.toLocal(Data("a\r\nb\r".utf8)) == Data("a\nb".utf8))
        // The CR at the end of one block and the LF at the start of the next are one line end.
        #expect(incoming.toLocal(Data("\nc\rd\r".utf8)) == Data("\nc\rd".utf8))
        let rest = incoming.finishLocal()
        #expect(rest == Data("\r".utf8))
        var outgoing = LineEndConverter()
        #expect(outgoing.toNetwork(Data("a\nb\r\nc\r".utf8)) == Data("a\r\nb\r\nc\r".utf8))
        #expect(outgoing.toNetwork(Data("\n\n".utf8)) == Data("\n\r\n".utf8))
    }

    /// Names are decoded and encoded in the chosen encoding; automatic falls back to Latin 1.
    @Test
    internal func nameEncodings() throws {
        #expect(NameEncoding.automatic.decode(Data("Grüße".utf8)) == "Grüße")
        // Not UTF-8: read as Western Latin 1 instead of being dropped.
        #expect(NameEncoding.automatic.decode(Data([0x47, 0x72, 0xFC, 0xDF, 0x65])) == "Grüße")
        #expect(NameEncoding.windowsCyrillic.decode(Data([0xCF, 0xF0, 0xE8])) == "При")
        #expect(try NameEncoding.koi8R.encode("При", names: nil) == Data([0xF0, 0xD2, 0xC9]))
        // Decomposed names from the Mac's file system are sent composed.
        #expect(try NameEncoding.utf8.encode("u\u{308}", names: nil) == Data("ü".utf8))
        #expect(NameEncoding.allCases.allSatisfy { !$0.title.isEmpty })
    }

    /// A download list's lines become downloads, copies, moves and pauses; others are kept as unsupported.
    @Test
    internal func downloadLists() {
        let text =
            "\u{FEFF}ftps://127.0.0.1:2122/a.txt -> /tmp/b/a.txt\r\nftp://host/dir/file.zip\n\nput:/src/file.zip -> ftp://host/dir/file.zip\n"
            + "copy:/a -> /b\nmove:/a -> /b\nsleep:1500\nheader: Referer: http://x\ncopyflags: 3\n"
        #expect(
            DownloadList.parse(text) == [
                .download(source: "ftps://127.0.0.1:2122/a.txt", target: "/tmp/b/a.txt"),
                .download(source: "ftp://host/dir/file.zip", target: nil),
                .copy(source: "/src/file.zip", target: "ftp://host/dir/file.zip"), .copy(source: "/a", target: "/b"),
                .move(source: "/a", target: "/b"), .pause(1.5), .unsupported("header: Referer: http://x"),
                .unsupported("copyflags: 3")
            ]
        )
        #expect(
            DownloadList.line(source: "ftp://h/a", target: "/t/a") == "ftp://h/a -> /t/a"
                && DownloadList.line(source: "x", target: nil) == "x"
        )
    }

    /// A path under /Volumes gives its volume; other paths and remote locations give none.
    @Test
    internal func volumes() {
        #expect(
            ServerSchemes.mountedVolume(of: URL(fileURLWithPath: "/Volumes/Share/a/b"))
                == URL(fileURLWithPath: "/Volumes/Share", isDirectory: true)
        )
        #expect(ServerSchemes.mountedVolume(of: URL(fileURLWithPath: "/Users/x")) == nil)
        #expect(ServerSchemes.mountedVolume(of: URL(fileURLWithPath: "/Volumes")) == nil)
        #expect(ServerSchemes.mountedVolume(of: ServerKey(scheme: "ftp", host: "h").url(path: "/Volumes/x")) == nil)
    }
}
