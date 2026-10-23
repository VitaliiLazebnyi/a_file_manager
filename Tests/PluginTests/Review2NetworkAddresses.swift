import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Paths, addresses and saved connections from text that anybody may have written
/// (review 2: N002, N008, N041, N101).
@Suite
internal struct Review2NetworkAddresses {
    /// What the fuzzer checks of a normalised path, read as text the way the rest of the program reads it.
    private func isClean(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("//") && !path.split(separator: "/").contains("..")
            && !path.split(separator: "/").contains(".")
    }

    /// A slash followed by a combining mark still separates names, and every result is a clean path.
    @Test
    internal func aPathIsCutAtTheBytesOfTheSlash() throws {
        let mark = try NetworkReproducers.text("remotepath-slash-joins-combining-mark.bin")
        #expect(mark.unicodeScalars.count == 1)
        // A slash followed by a combining mark is one character; it is a separator all the same.
        #expect(RemotePath.normalized("/a/" + mark + "/../b") == "/a/b")
        #expect(RemotePath.normalized("a/\u{301}../x").unicodeScalars.contains("\u{301}"))
        #expect(RemotePath.name(of: "/a/\u{301}b") == "\u{301}b")
        #expect(RemotePath.parent(of: "/a/\u{301}b") == "/a")
        #expect(
            RemotePath.normalized("/a/./b/../c//d/") == "/a/c/d" && RemotePath.normalized("") == "/"
                && RemotePath.normalized("../..") == "/"
        )
        #expect(
            RemotePath.parent(of: "/") == nil && RemotePath.parent(of: "/a") == "/" && RemotePath.name(of: "/").isEmpty
        )
        // Whatever the text, the result reads as an absolute path with whole names.
        for text in [
            mark, "/" + mark, "x/" + mark + "..", "\u{600}/..", "a\u{600}/b", "/\u{200D}/..", "\u{1F1E9}/\u{1F1EA}",
            "é/e\u{301}"
        ] {
            #expect(
                isClean(RemotePath.normalized(text)),
                "\(text.debugDescription) -> \(RemotePath.normalized(text).debugDescription)"
            )
            #expect(isClean(RemotePath.join(text, text)))
        }
        // A name that would melt into the slash next to it is told, and is no name for an entry of a listing.
        #expect(!RemotePath.hasSeparableNames("/a/" + mark) && RemotePath.hasSeparableNames("/a/é/e\u{301}"))
        #expect(
            !RemoteEntry.isSafeName(mark + "x") && !RemoteEntry.isSafeName("x\u{600}")
                && RemoteEntry.isSafeName("e\u{301}")
        )
        #expect(FTPListParser.mlsd("type=file;size=1; " + mark + "x") == nil)
        #expect(FTPListParser.mlsd("type=file;size=1;" + " " + "ok")?.name == "ok")
    }

    /// Texts made of the troublesome pieces in any order normalise to clean paths that stay as they are.
    @Test
    internal func anyTextGivesACleanPath() {
        // What the fuzzer does, in small: texts made of the pieces that matter, in every order.
        let pieces = [
            "/", ".", "..", "a", "\u{301}", "\u{600}", "\u{200D}", "é", " ", "\u{1F1E9}", "//", "\u{FFFD}", "\u{FE0F}"
        ]
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        for _ in 0..<20_000 {
            let text = (0..<next(9)).map { _ in pieces[next(pieces.count)] }.joined()
            let path = RemotePath.normalized(text)
            guard isClean(path) else {
                Issue.record("\(text.debugDescription) -> \(path.debugDescription)")
                return
            }
            // Normalising again changes nothing, and the parent and the name are parts of it.
            #expect(RemotePath.normalized(path) == path)
            if let parent = RemotePath.parent(of: path) {
                #expect(isClean(parent) && RemotePath.normalized(parent) == parent)
            }
        }
    }

    /// An address whose path holds such a name is refused before any connection is made.
    @Test
    internal func theFileSystemRefusesAPathWithSuchAName() throws {
        let center = ConnectionCenter()
        // Used by the callbacks, which run one at a time while the calls below wait for them.
        nonisolated(unsafe) var made = 0
        center.makeSession = { _, _ in
            made += 1
            return nil
        }
        let fileSystem = RemoteFileSystem(scheme: "ftp", center: center)
        let url = try #require(URL(string: "ftp://host.invalid/dir/%CC%81name"))
        #expect(throws: FileSystemError.self) { try fileSystem.remove(url) }
        #expect(throws: FileSystemError.self) { _ = try fileSystem.list(url, showHidden: true) }
        #expect(made == 0, "no connection is made for it")
    }

    /// A saved connection with an impossible port, or members of the wrong kind, is read without a trap.
    @Test
    internal func aSavedConnectionWithAPortThatIsNoneDoesNotTrap() throws {
        let saved = try JSONDecoder()
            .decode(
                [SavedConnection].self,
                from: try NetworkReproducers.data("saved-connection-port-trap.json")
            )
        let connection = try #require(saved.first)
        #expect(connection.port == nil && connection.key.port == 21)
        _ = connection.key.url()
        _ = connection.key.description
        _ = connection.listTitle
        _ = connection.hostText
        _ = connection.profile
        // The key itself takes no port that is none either.
        for port in [-2, 0, 65_536, Int.max, Int.min] {
            let key = ServerKey(scheme: "sftp", host: "h.example", port: port)
            #expect(key.port == 22 && key.url(path: "/x").absoluteString == "sftp://h.example/x")
        }
        // Members that are missing or of the wrong kind take their usual values; the rest is kept.
        let json =
            #"{"id":"00000000-0000-0000-0000-000000000001","host":"h","port":2121,"#
            + #""kind":99,"passive":"yes","user":"u"}"#
        let partial = try JSONDecoder().decode(SavedConnection.self, from: Data(json.utf8))
        #expect(
            partial.host == "h" && partial.port == 2_121 && partial.kind == .ftp && partial.passive
                && partial.user == "u"
        )
        #expect(throws: (any Error).self) { try JSONDecoder().decode(SavedConnection.self, from: Data("{}".utf8)) }
        // What is written is read back the same.
        var full = SavedConnection()
        (full.name, full.host, full.port, full.kind, full.encoding, full.listing) = (
            "n", "h", 990, .ftpImplicitTLS, .koi8R, .mlsd
        )
        #expect(try JSONDecoder().decode(SavedConnection.self, from: JSONEncoder().encode(full)) == full)
    }

    /// A host the system cannot write in a URL gives no address, or one whose URL names that same host.
    @Test
    internal func aHostWithoutAURLIsNoAddress() throws {
        for text in [
            "ftp://ho%st/", "ftp://a#b/", "ftp://a?b", "ftp://a\"b/", "ftp://a<b/", "ftp://a^b/", "ftp://a{b/",
            "ftp://a|b/", "a\u{202E}b"
        ] {
            if let address = ServerAddress(text) {
                // Where the system can write the host in a URL after all, the URL names that host.
                #expect(ServerKey(address.url) == address.key, "\(text)")
            }
        }
        // A key made by hand from such a host never points at the local disk.
        let key = ServerKey(scheme: "ftp", host: "a b")
        #expect(!key.url(path: "/etc").isFileURL && key.url(path: "/etc").scheme == "ftp")
        #expect(key.validURL() == nil || ServerKey(key.url()) == key)
        // A name with letters beyond ASCII is the same server however it is spelled.
        let typed = try #require(ServerAddress("ftp://B\u{FC}cher.example/pub"))
        #expect(ServerKey(typed.url) == typed.key)
        #expect(ServerKey(scheme: "ftp", host: typed.key.host) == typed.key)
        #expect(typed.url.path == "/pub")
    }
}
