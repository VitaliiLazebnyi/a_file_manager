import AFMKernel
import Foundation
import Testing

@testable import NetworkPlugin

/// The parts of the network plugin that are pure text: listings, replies, addresses.
@Suite struct NetworkParsers {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 15 June 2024, 12:00 UTC: "now" for listings without a year.
    static let now = date(2024, 6, 15, 12, 0)

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0)
        -> Date
    {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    func d(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        NetworkParsers.date(year, month, day, hour, minute, second)
    }

    func list(_ line: String) -> RemoteEntry? {
        FTPListParser.list(line, now: NetworkParsers.now, calendar: NetworkParsers.utc)
    }

    // MARK: LIST

    @Test func unixListings() {
        // GNU ls, as vsftpd and ProFTPD send it.
        var entry = list("-rw-r--r--    1 1000     1000         1234 Jan 05 10:30 report.txt")
        #expect(
            entry
                == RemoteEntry(
                    name: "report.txt", isDirectory: false, size: 1234, modified: d(2024, 1, 5, 10, 30),
                    permissions: 0o644))
        entry = list("drwxr-xr-x   12 root     wheel        4096 Mar  3  2021 pub")
        #expect(
            entry
                == RemoteEntry(
                    name: "pub", isDirectory: true, size: 4096, modified: d(2021, 3, 3), permissions: 0o755))
        // A date later in the year than today belongs to last year.
        #expect(list("-rw-r--r-- 1 u g 5 Dec 24 08:00 gift.txt")?.modified == d(2023, 12, 24, 8, 0))
        // Names with spaces, also leading and doubled ones.
        #expect(list("-rw-r--r-- 1 u g 5 Jan 01 2020 My  Documents and more.txt")?.name == "My  Documents and more.txt")
        #expect(list("-rw-r--r-- 1 u g 5 Jan 01 2020  leading space")?.name == " leading space")
        // A name that itself looks like a date.
        #expect(list("-rw-r--r-- 1 u g 77 Feb 02 2019 7 Jan 01 2020 notes")?.name == "7 Jan 01 2020 notes")
        // Symbolic links carry their target.
        entry = list("lrwxrwxrwx 1 root root 11 May 10 2022 latest -> release-2.4")
        #expect(
            entry?.name == "latest" && entry?.isSymlink == true && entry?.linkTarget == "release-2.4"
                && entry?.isDirectory == false)
        // No group column (BSD `ls -lo`, some embedded servers).
        #expect(list("-rw-r--r--   1 ftp          512 Apr 12 09:15 nogroup.bin")?.size == 512)
        // Group names with spaces and numbers, huge sizes.
        entry = list("-rw-rw-r--   1 jdoe   Domain Users 9876543210 Jun 14 23:59 big.iso")
        #expect(entry?.size == 9_876_543_210 && entry?.name == "big.iso" && entry?.modified == d(2024, 6, 14, 23, 59))
        // ACL and extended-attribute marks after the mode.
        #expect(list("-rw-r--r--+  1 u g 10 Jan 01 2020 acl.txt")?.permissions == 0o644)
        #expect(list("drwx------@  5 u g 160 Jan 01 2020 Library")?.isDirectory == true)
        #expect(list("-rw-r--r--.  1 u g 10 Jan 01 2020 selinux.txt")?.name == "selinux.txt")
        // Set-id and sticky bits.
        #expect(list("-rwsr-sr-t 1 u g 10 Jan 01 2020 special")?.permissions == 0o7755)
        #expect(list("drwxrwxrwT 2 u g 10 Jan 01 2020 tmp")?.permissions == 0o1776)
        // Device files have "major, minor" where the size is.
        #expect(list("crw-rw-rw- 1 root wheel 3, 2 Jan 01 2020 null")?.name == "null")
        // Seconds in the time, ISO dates (`ls --time-style=long-iso`).
        #expect(list("-rw-r--r-- 1 u g 42 Jun 01 07:08:09 secs.log")?.modified == d(2024, 6, 1, 7, 8, 9))
        entry = list("-rw-r--r-- 1 u g 42 2023-11-30 16:45 iso.log")
        #expect(entry?.name == "iso.log" && entry?.modified == d(2023, 11, 30, 16, 45) && entry?.size == 42)
        // Month names of other languages, with and without a dot; day before month.
        #expect(list("-rw-r--r-- 1 u g 1 Okt 03 2022 deutsch.txt")?.modified == d(2022, 10, 3))
        #expect(list("-rw-r--r-- 1 u g 1 déc. 25 2022 noel.txt")?.modified == d(2022, 12, 25))
        #expect(list("-rw-r--r-- 1 u g 1 25 Mai 2022 tag-zuerst.txt")?.modified == d(2022, 5, 25))
        // NetWare.
        entry = list("d [R----F--] supervisor            512       Jan 16 18:53    login")
        #expect(entry?.isDirectory == true && entry?.size == 512)
        entry = list("- [R----F--] rhesus             214059       Oct 20 15:27    cx.exe")
        #expect(entry?.isDirectory == false && entry?.size == 214_059 && entry?.modified == d(2023, 10, 20, 15, 27))
        // Carriage returns that survived, and what is no entry at all.
        #expect(list("-rw-r--r-- 1 u g 5 Jan 01 2020 cr.txt\r")?.name == "cr.txt")
        for line in [
            "total 48", "", "drwxr-xr-x 2 u g 4096 Jan 01 2020 .", "drwxr-xr-x 2 u g 4096 Jan 01 2020 ..",
            "226 Transfer complete",
            "ls: cannot access x: No such file", "-rw-r--r-- garbage"
        ] {
            #expect(list(line) == nil)
        }
    }

    @Test func windowsListings() {
        var entry = list("01-31-24  03:04PM       <DIR>          Program Files")
        #expect(entry == RemoteEntry(name: "Program Files", isDirectory: true, modified: d(2024, 1, 31, 15, 4)))
        entry = list("12-07-98  12:30AM              1048576 setup.exe")
        #expect(
            entry
                == RemoteEntry(
                    name: "setup.exe", isDirectory: false, size: 1_048_576, modified: d(1998, 12, 7, 0, 30)))
        // Four-digit years and a 24-hour clock, thousands separators.
        entry = list("02-29-2024  17:45            1,234,567 leap year.zip")
        #expect(
            entry?.size == 1_234_567 && entry?.name == "leap year.zip" && entry?.modified == d(2024, 2, 29, 17, 45))
        #expect(list("07-04-05  12:00PM                    0 empty")?.modified == d(2005, 7, 4, 12, 0))
        #expect(list("07-04-05  09:00AM       <JUNCTION>     link")?.isSymlink == true)
    }

    @Test func eplfListings() {
        var entry = list("+i8388621.29609,m824255902,/,\tdev")
        #expect(
            entry == RemoteEntry(name: "dev", isDirectory: true, modified: Date(timeIntervalSince1970: 824_255_902)))
        entry = list("+i8388621.44468,m839956783,r,s10376,up644,\tRFCEPLF with spaces")
        #expect(
            entry
                == RemoteEntry(
                    name: "RFCEPLF with spaces", isDirectory: false, size: 10376,
                    modified: Date(timeIntervalSince1970: 839_956_783), permissions: 0o644))
    }

    @Test func mlsdListings() {
        var entry = FTPListParser.mlsd(
            "type=file;size=4096;modify=20261011035043;UNIX.mode=0640; a file; with semicolon.txt")
        #expect(
            entry
                == RemoteEntry(
                    name: "a file; with semicolon.txt", isDirectory: false, size: 4096,
                    modified: d(2026, 10, 11, 3, 50, 43),
                    permissions: 0o640))
        entry = FTPListParser.mlsd("modify=20261011035043.123;perm=eldfmMTcp;size=4096;type=dir; docs")
        #expect(entry?.isDirectory == true && entry?.name == "docs" && entry?.modified == d(2026, 10, 11, 3, 50, 43))
        #expect(FTPListParser.mlsd("Type=cdir;Modify=20200101000000; .") == nil)
        #expect(FTPListParser.mlsd("type=pdir; ..") == nil)
        entry = FTPListParser.mlsd("type=OS.unix=slink:/srv/target;size=7; link")
        #expect(entry?.isSymlink == true && entry?.linkTarget == "/srv/target")
        #expect(
            FTPListParser.mlsd("Type=file;Size=3; UPPER") == RemoteEntry(name: "UPPER", isDirectory: false, size: 3))
        // No facts at all: only the name.
        #expect(FTPListParser.mlsd(" just a name")?.name == "just a name")
        #expect(FTPListParser.mlsd("nonsense") == nil)
        // MLST indents its line and may give the whole path.
        #expect(
            FTPListParser.mlst(" type=file;size=9; /pub/dir/file name.txt")
                == RemoteEntry(name: "file name.txt", isDirectory: false, size: 9))
    }

    @Test func largeListingsAreParsedInOrder() {
        let lines = (0..<5000).map { "-rw-r--r-- 1 u g \($0) Jan 01 2020 file\($0).txt" } + ["total 5000"]
        let entries = FTPListParser.entries(of: lines, asMLSD: false)
        #expect(entries.count == 5000 && entries[4999].size == 4999 && entries[17].name == "file17.txt")
        let facts = (0..<5000).map { "type=file;size=\($0); f\($0)" }
        #expect(FTPListParser.entries(of: facts, asMLSD: true).map(\.size) == (0..<5000).map(Int64.init))
    }

    // MARK: Replies

    @Test func replies() {
        var parser = FTPReplyParser()
        #expect(parser.feed("220 Welcome") == FTPReply(code: 220, lines: ["Welcome"]))
        #expect(parser.feed("230-First line") == nil)
        #expect(parser.feed(" indented text") == nil)
        #expect(parser.feed("230-Second") == nil)
        #expect(parser.feed("123 a number inside") == nil)
        let reply = parser.feed("230 Logged in")
        #expect(
            reply
                == FTPReply(
                    code: 230, lines: ["First line", " indented text", "Second", "123 a number inside", "Logged in"]))
        #expect(reply?.isSuccess == true && reply?.message == "230 Logged in")
        #expect(parser.feed("226") == FTPReply(code: 226, lines: [""]))
        #expect(parser.feed("garbage") == nil && parser.feed("") == nil)
        #expect(FTPReply(code: 150, lines: []).isPreliminary && FTPReply(code: 331, lines: []).isIntermediate)

        var feat = FTPReplyParser()
        var features: [String: String] = [:]
        for line in ["211-Features:", " MDTM", " MLST type*;size*;modify*;", " REST STREAM", " UTF8", "211 End"] {
            if let reply = feat.feed(line) { features = FTPSyntax.features(reply) }
        }
        #expect(features == ["MDTM": "", "MLST": "type*;size*;modify*;", "REST": "STREAM", "UTF8": ""])
    }

    @Test func replySyntax() {
        #expect(FTPSyntax.extendedPassivePort("Entering Extended Passive Mode (|||6446|)") == 6446)
        #expect(FTPSyntax.extendedPassivePort("Extended (!!!50000!) ok") == 50000)
        #expect(FTPSyntax.extendedPassivePort("Entering Extended Passive Mode") == nil)
        #expect(FTPSyntax.extendedPassivePort("(|||99999|)") == nil)
        var endpoint = FTPSyntax.passiveEndpoint("Entering Passive Mode (192,168,1,20,19,137).")
        #expect(endpoint?.host == "192.168.1.20" && endpoint?.port == 19 * 256 + 137)
        endpoint = FTPSyntax.passiveEndpoint("Entering Passive Mode 10,0,0,5,200,1")
        #expect(endpoint?.host == "10.0.0.5" && endpoint?.port == 51201)
        #expect(FTPSyntax.passiveEndpoint("Entering Passive Mode (1,2,3,4,5)") == nil)
        #expect(FTPSyntax.passiveEndpoint("Entering Passive Mode (1,2,3,400,5,6)") == nil)
        #expect(FTPSyntax.portArgument(host: "127.0.0.1", port: 51201) == "127,0,0,1,200,1")
        #expect(FTPSyntax.portArgument(host: "::1", port: 80) == nil)
        #expect(FTPSyntax.extendedPortArgument(host: "::1", port: 5282) == "|2|::1|5282|")
        #expect(FTPSyntax.extendedPortArgument(host: "10.0.0.1", port: 21) == "|1|10.0.0.1|21|")
        #expect(FTPSyntax.quotedPath("\"/home/user\" is the current directory") == "/home/user")
        #expect(FTPSyntax.quotedPath("\"/a \"\"quoted\"\" name\" created") == "/a \"quoted\" name")
        #expect(FTPSyntax.quotedPath("no quotes") == nil && FTPSyntax.quotedPath("\"unfinished") == nil)
        let time = NetworkParsers.date(2026, 10, 11, 3, 50, 43)
        #expect(FTPSyntax.time("20261011035043") == time && FTPSyntax.time("20261011035043.999") == time)
        #expect(FTPSyntax.time("2026101103") == nil && FTPSyntax.timeText(time) == "20261011035043")
        #expect(
            FTPServerConfig.initCommands(from: "CWD /test/a;;b;;c;PWD; ;SITE X") == [
                "CWD /test/a;b;c", "PWD", "SITE X"
            ])
    }

    // MARK: Addresses

    @Test func addresses() throws {
        var address = try #require(ServerAddress("ftp.example.com"))
        #expect(
            address.scheme == "ftp" && address.port == 21 && address.user == nil && address.path == "/"
                && !address.hasPath)
        #expect(address.url.absoluteString == "ftp://ftp.example.com/")

        address = try #require(ServerAddress("myself@myserver.com:1021"))
        #expect(
            address.user == "myself" && address.password == nil && address.host == "myserver.com"
                && address.port == 1021)
        #expect(address.url.absoluteString == "ftp://myserver.com:1021/")

        address = try #require(ServerAddress("ftp://anna:p%40ss:w@rd@Host.Example.com:2121/home/my%20user/"))
        #expect(
            address.user == "anna" && address.password == "p@ss:w@rd" && address.path == "/home/my user"
                && address.hasPath)
        // The URL for the panel carries no credentials; the remembered text no password.
        #expect(address.url.absoluteString == "ftp://host.example.com:2121/home/my%20user")
        #expect(address.textWithoutPassword == "ftp://anna@host.example.com:2121/home/my%20user")
        #expect(!address.textWithoutPassword.contains("ss"))

        address = try #require(ServerAddress("FTPS://secure.example.com"))
        #expect(address.scheme == "ftps" && address.tls == .explicit && address.port == 21)
        #expect(ServerAddress("ftps://secure.example.com:990")?.tls == .implicit)
        address = try #require(ServerAddress("ftpis://secure.example.com"))
        #expect(
            address.tls == .implicit && address.port == 990
                && address.url.absoluteString == "ftps://secure.example.com:990/")
        address = try #require(ServerAddress("ftpes://secure.example.com:990/x"))
        #expect(address.tls == .explicit && address.port == 990)
        address = try #require(ServerAddress("sftp://deploy@box.local/var/www"))
        #expect(
            address.scheme == "sftp" && address.port == 22 && address.user == "deploy"
                && address.url.absoluteString == "sftp://box.local/var/www")

        address = try #require(ServerAddress("[1234:56:789A:BC::DE]:2100"))
        #expect(address.host == "1234:56:789A:BC::DE" && address.port == 2100)
        #expect(ServerKey(address.url) == address.key && address.key.host == "1234:56:789a:bc::de")
        #expect(ServerAddress("::1")?.host == "::1")

        for bad in ["", "http://www.example.com", "host:port", "host:99999", "ftp://", "two words", "[::1", "user@"] {
            #expect(ServerAddress(bad) == nil)
        }
    }

    @Test func serverKeysAndPaths() throws {
        let key = ServerKey(scheme: "FTP", host: "Example.COM", port: nil)
        #expect(
            key.description == "ftp://example.com"
                && key.url(path: "pub/a b").absoluteString == "ftp://example.com/pub/a%20b")
        #expect(ServerKey(scheme: "sftp", host: "h").port == 22)
        #expect(URL(string: "ftp://example.com:21/x").flatMap(ServerKey.init) == key)
        #expect(
            ServerKey(URL(fileURLWithPath: "/tmp")) == nil
                && URL(string: "http://example.com/").flatMap(ServerKey.init) == nil)
        let odd = key.url(path: "/a#b?c%d;e")
        #expect(RemotePath.of(odd) == "/a#b?c%d;e" && ServerKey(odd) == key)
        #expect(
            RemotePath.normalized("a//b/./c/../d/") == "/a/b/d" && RemotePath.normalized("") == "/"
                && RemotePath.normalized("/../..") == "/")
        #expect(
            RemotePath.parent(of: "/a/b") == "/a" && RemotePath.parent(of: "/a") == "/"
                && RemotePath.parent(of: "/") == nil)
        #expect(RemotePath.name(of: "/a/b.txt") == "b.txt" && RemotePath.join("/a/", "b") == "/a/b")
    }

    @Test func savedConnections() {
        var connection = SavedConnection()
        var accepted = connection.setHost("ftp.example.com:2121", kind: .ftp)
        #expect(accepted && connection.port == 2121 && connection.hostText == "ftp.example.com:2121")
        #expect(connection.key.description == "ftp://ftp.example.com:2121")
        accepted = connection.setHost("ftpis://anna@secure.example.com/start", kind: .ftp)
        #expect(
            accepted && connection.kind == .ftpImplicitTLS && connection.port == nil && connection.key.port == 990
                && connection.user == "anna")
        #expect(
            connection.remoteDirectory == "/start" && connection.profile.tls == .implicit
                && connection.profile.user == "anna")
        accepted = connection.setHost("box", kind: .sftp)
        #expect(accepted && connection.key == ServerKey(scheme: "sftp", host: "box", port: 22))
        accepted = connection.setHost("not a host", kind: .ftp)
        #expect(!accepted)
        connection.anonymous = true
        connection.listing = .list
        connection.initCommands = "SITE A;SITE B"
        let profile = connection.profile
        #expect(
            profile.user == nil && profile.anonymous && profile.usesMLSD == false
                && profile.initCommands == ["SITE A", "SITE B"])
        #expect(profile.savedID == connection.id)
    }

    // MARK: Other pure pieces

    @Test func lineEnds() {
        var down = LineEndConverter()
        #expect(down.toLocal(Data("a\r\nb\r".utf8)) == Data("a\nb".utf8))
        // The CR at the end of one block and the LF at the start of the next are one line end.
        #expect(down.toLocal(Data("\nc\rd\r".utf8)) == Data("\nc\rd".utf8))
        let rest = down.finishLocal()
        #expect(rest == Data("\r".utf8))
        var up = LineEndConverter()
        #expect(up.toNetwork(Data("a\nb\r\nc\r".utf8)) == Data("a\r\nb\r\nc\r".utf8))
        #expect(up.toNetwork(Data("\n\n".utf8)) == Data("\n\r\n".utf8))
    }

    @Test func nameEncodings() throws {
        #expect(NameEncoding.automatic.decode(Data("Grüße".utf8)) == "Grüße")
        // Not UTF-8: read as Western Latin 1 instead of being dropped.
        #expect(NameEncoding.automatic.decode(Data([0x47, 0x72, 0xFC, 0xDF, 0x65])) == "Grüße")
        #expect(NameEncoding.windowsCyrillic.decode(Data([0xCF, 0xF0, 0xE8])) == "При")
        #expect(try NameEncoding.koi8R.encode("При") == Data([0xF0, 0xD2, 0xC9]))
        // Decomposed names from the Mac's file system are sent composed.
        #expect(try NameEncoding.utf8.encode("u\u{308}") == Data("ü".utf8))
        #expect(NameEncoding.allCases.allSatisfy { !$0.title.isEmpty })
    }

    @Test func downloadLists() {
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
            ])
        #expect(
            DownloadList.line(source: "ftp://h/a", target: "/t/a") == "ftp://h/a -> /t/a"
                && DownloadList.line(source: "x", target: nil) == "x")
    }

    @Test func volumes() {
        #expect(
            ServerSchemes.mountedVolume(of: URL(fileURLWithPath: "/Volumes/Share/a/b"))
                == URL(fileURLWithPath: "/Volumes/Share", isDirectory: true))
        #expect(ServerSchemes.mountedVolume(of: URL(fileURLWithPath: "/Users/x")) == nil)
        #expect(ServerSchemes.mountedVolume(of: URL(fileURLWithPath: "/Volumes")) == nil)
        #expect(ServerSchemes.mountedVolume(of: ServerKey(scheme: "ftp", host: "h").url(path: "/Volumes/x")) == nil)
    }
}
