import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Where the reproducers of the fuzzing run are kept.
private func reproducer(_ name: String) throws -> Data {
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: tests.appendingPathComponent("Fuzz/repro/net/" + name))
}

/// What a server sends is read in time that grows with its length and nothing else, and is
/// taken only as far as it makes sense (review 2: N001, N004, N023, N024, N025, N074, N155).
@Suite
internal struct Review2NetworkHostileServers {
    @Test
    internal func theLineThatMadeTheListingHangIsReadAtOnce() throws {
        let line = String(decoding: try reproducer("ftplist-regex-backtracking.txt"), as: UTF8.self)
        // With the patterns it was read with before, each of these took seconds (one of 16 KB a
        // minute). Two hundred of them, and of the worst that fit into a line, are nothing now.
        let digits = "-rwxrwxrwx " + String(repeating: "9", count: FTPListParser.longestLine - 11)
        let spaces = "01-01-24  03:04" + String(repeating: " ", count: FTPListParser.longestLine - 20) + "x"
        let started = Date()
        for _ in 0..<200 {
            _ = FTPListParser.list(line)
            #expect(FTPListParser.list(digits) == nil)
            #expect(FTPListParser.list(spaces) == nil)
        }
        #expect(Date().timeIntervalSince(started) < 30)
    }

    @Test
    internal func aLineThatIsTooLongIsNoEntry() {
        let name = String(repeating: "n", count: FTPListParser.longestLine)
        #expect(FTPListParser.list("-rw-r--r-- 1 o g 5 Jan 01 2020 " + name) == nil)
        #expect(FTPListParser.mlsd("type=file;size=5; " + name) == nil)
        #expect(FTPListParser.list("-rw-r--r-- 1 o g 5 Jan 01 2020 " + String(name.prefix(200)))?.name.count == 200)
    }

    @Test
    internal func theFormatsAreStillRead() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2_024, month: 6, day: 15)))
        func list(_ line: String) -> RemoteEntry? { FTPListParser.list(line, now: now, calendar: calendar) }
        func day(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date? {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
        }
        var entry = try #require(list("-rw-r--r--   1 owner    group        1234 Jan 31  2024 a file  with spaces.txt"))
        #expect(
            entry.name == "a file  with spaces.txt" && entry.size == 1_234 && entry.modified == day(2_024, 1, 31)
                && entry.permissions == 0o644
        )
        // The time instead of the year means the last months; a date ahead of today is last year's.
        #expect(list("-rw-r--r-- 1 o g 7 Mar  5 12:30 r.txt")?.modified == day(2_024, 3, 5, 12, 30))
        #expect(list("-rw-r--r-- 1 o g 7 Dec 24 08:00 r.txt")?.modified == day(2_023, 12, 24, 8, 0))
        // No group, device numbers, a name that starts with a space, a link.
        #expect(list("drwxr-xr-x 2 owner 4096 Feb 29 2024 dir")?.isDirectory == true)
        entry = try #require(list("crw-rw-rw- 1 root wheel 3, 2 Jan  1  2020 null"))
        #expect(entry.name == "null" && entry.size == 2 && entry.isSpecial)
        #expect(list("-rw-r--r-- 1 o g 5 Jan 01 2020  lead")?.name == " lead")
        entry = try #require(list("lrwxrwxrwx 1 o g 9 Jan 01 2020 link -> /some/where"))
        #expect(entry.name == "link" && entry.linkTarget == "/some/where" && entry.isSymlink)
        // The day before the month, other languages, ISO dates with and without a zone, NetWare.
        #expect(list("-rw-r--r-- 1 o g 5 31. Jan 2024 e.txt")?.modified == day(2_024, 1, 31))
        #expect(list("-rw-r--r-- 1 o g 5 déc. 24 2023 f.txt")?.modified == day(2_023, 12, 24))
        #expect(list("-rw-r--r-- 1 o g 5 2024-01-31 12:34 iso.txt")?.modified == day(2_024, 1, 31, 12, 34))
        entry = try #require(list("-rw-r--r-- 1 o g 5 2024-01-31 12:34:56.789 +0100 zone.txt"))
        #expect(entry.name == "zone.txt" && entry.size == 5)
        #expect(list("-rw-r--r-- 1 o g 5 2024-01-31 12:34 +0100")?.name == "+0100")
        #expect(list("d [RWCEAFMS] owner 512 Jan 16 18:53 login")?.isDirectory == true)
        // A name that looks like a date does not move the date.
        #expect(list("-rw-r--r-- 1 o g 5 Jan 01 2020 Feb 02 2021 x")?.name == "Feb 02 2021 x")
        // Windows.
        entry = try #require(list("01-31-24  03:04PM              1,234 report final.doc"))
        #expect(entry.name == "report final.doc" && entry.size == 1_234 && entry.modified == day(2_024, 1, 31, 15, 4))
        #expect(list("01-31-2024  15:04       <DIR>          Program Files")?.isDirectory == true)
        #expect(list("12-01-99  12:05AM  7 old.txt")?.modified == day(1_999, 12, 1, 0, 5))
        #expect(list("01-31-24  03:04PM       <NOPE>         x") == nil && list("01-31-24  03:04PM 12") == nil)
        // Lines that are no entry.
        for line in [
            "total 12", "", "-rw-r--r-- 1 o g 5 Jan 01 2020 .", "-rw-r--r-- 1 o g 5 Jan 41 2020 x",
            "-rw-r--r-- 1 o g Jan 01 2020"
        ] {
            #expect(list(line) == nil, "\(line)")
        }
    }

    @Test
    internal func sizesAndDatesAreTakenAsFarAsTheyMakeSense() {
        let huge = String(repeating: "9", count: 40)
        #expect(FTPListParser.list("-rw-r--r-- 1 o g \(huge) Jan 01 2020 big")?.size == .max)
        #expect(FTPListParser.mlsd("type=file;size=\(huge); big")?.size == .max)
        #expect(FTPListParser.mlsd("type=file;size=-5; neg")?.size == 0)
        #expect(FTPListParser.mlsd("type=file;size=abc; odd")?.size == 0)
        #expect(FTPListParser.list("+s\(huge),\tbig")?.size == .max)
        #expect(FTPListParser.list("01-31-24  03:04PM  \(huge) big")?.size == .max)
        // Dates that are none give no date, and no trap.
        #expect(FTPListParser.list("+m1e300,\tx")?.modified == nil)
        #expect(FTPListParser.list("+m-5,\tx")?.modified == nil)
        #expect(FTPListParser.list("+m\(huge),\tx")?.modified == nil)
        #expect(FTPListParser.list("+m824255902,\tx")?.modified == Date(timeIntervalSince1970: 824_255_902))
        #expect(FTPListParser.list("-rw-r--r-- 1 o g 5 Jan 01 0000 x")?.modified == nil)
        #expect(FTPListParser.list("-rw-r--r-- 1 o g 5 2024-13-45 99:99 x")?.modified == nil)
        #expect(FTPListParser.mlsd("type=file;modify=00000000000000; x")?.modified == nil)
        #expect(FTPSyntax.time("99999999999999") == nil)
        #expect(FTPListParser.list("+up7777777,\tx")?.permissions == nil)
    }

    @Test
    internal func aListingIsCutIntoLinesByteByByteOnce() {
        let text = "one\r\ntwo\n\nlast without end"
        var whole = LineSplitter()
        #expect(whole.feed(Data(text.utf8)).map { String(decoding: $0, as: UTF8.self) } == ["one", "two", ""])
        #expect(whole.finish().map { String(decoding: $0, as: UTF8.self) } == "last without end")
        // The same, whatever the sizes of the blocks.
        var bytewise = LineSplitter()
        var lines: [Data] = []
        for byte in Data(text.utf8) { lines += bytewise.feed(Data([byte])) }
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["one", "two", ""])
        #expect(bytewise.finish() == Data("last without end".utf8))

        // A megabyte without a line end is dropped as it comes; what follows it is read.
        var hostile = LineSplitter()
        for _ in 0..<1_024 { #expect(hostile.feed(Data(repeating: 0x39, count: 1_024)).isEmpty) }
        #expect(hostile.feed(Data("\nfine\n".utf8)) == [Data("fine".utf8)])
        #expect(hostile.dropped == 1 && hostile.finish() == nil)
        // The longest line that is kept, and one byte more.
        var edge = LineSplitter()
        #expect(
            edge.feed(Data(repeating: 0x61, count: FTPLimits.lineLength) + Data("\r\n".utf8)).first?.count
                == FTPLimits.lineLength
        )
        #expect(
            edge.feed(Data(repeating: 0x61, count: FTPLimits.lineLength + 2) + Data("\n".utf8)).isEmpty
                && edge.dropped == 1
        )
    }

    @Test
    internal func aReplyIsKeptOnlyUpToItsLargestSize() {
        var parser = FTPReplyParser()
        #expect(parser.feed("220-Welcome") == nil)
        for index in 0..<50_000 { #expect(parser.feed(" line \(index) " + String(repeating: "x", count: 100)) == nil) }
        #expect(parser.linesOfOpenReply == 50_001)
        let reply = parser.feed("220 Ready")
        #expect(reply?.code == 220 && reply?.lines.last == "Ready" && reply?.lines.first == "Welcome")
        #expect((reply?.lines.count ?? .max) <= FTPLimits.replyLines + 1)
        #expect((reply?.lines.reduce(0) { $0 + $1.utf8.count } ?? .max) <= FTPLimits.replyBytes + FTPLimits.lineLength)
        // The parser starts clean for the next reply.
        #expect(parser.feed("200 OK") == FTPReply(code: 200, lines: ["OK"]) && parser.linesOfOpenReply == 0)
    }
}

/// Paths, addresses and saved connections from text that anybody may have written
/// (review 2: N002, N008, N041, N101).
@Suite
internal struct Review2NetworkAddresses {
    /// What the fuzzer checks of a normalised path, read as text the way the rest of the program reads it.
    private func isClean(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("//") && !path.split(separator: "/").contains("..")
            && !path.split(separator: "/").contains(".")
    }

    @Test
    internal func aPathIsCutAtTheBytesOfTheSlash() throws {
        let mark = String(decoding: try reproducer("remotepath-slash-joins-combining-mark.bin"), as: UTF8.self)
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
            RemotePath.parent(of: "/") == nil && RemotePath.parent(of: "/a") == "/" && RemotePath.name(of: "/") == ""
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

    @Test
    internal func aSavedConnectionWithAPortThatIsNoneDoesNotTrap() throws {
        let saved = try JSONDecoder()
            .decode(
                [SavedConnection].self,
                from: try reproducer("saved-connection-port-trap.json")
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
        let partial = try JSONDecoder()
            .decode(
                SavedConnection.self,
                from: Data(
                    #"{"id":"00000000-0000-0000-0000-000000000001","host":"h","port":2121,"kind":99,"passive":"yes","user":"u"}"#
                        .utf8
                )
            )
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

/// What a download list may hold and what it says (review 2: N016, N020, N033, N070, N075).
@Suite
internal struct Review2NetworkDownloadLists {
    @Test
    internal func aNameWithALineBreakIsNotWritten() {
        #expect(DownloadList.canHold(source: "ftp://h/pub/a b.txt", target: "/Users/me/Downloads/a b.txt"))
        #expect(DownloadList.canHold(source: "ftp://h/a", target: nil))
        for breaker in ["\n", "\r", "\u{2028}", "\u{2029}", "\u{85}", "\u{B}", "\u{C}", "\0"] {
            #expect(
                !DownloadList.canHold(source: "ftp://h/pub/payload" + breaker + "sleep:1", target: nil),
                "\(breaker.debugDescription)"
            )
            #expect(!DownloadList.canHold(source: "ftp://h/a", target: "/t/a" + breaker + "move:/x -> ftp://evil/x"))
        }
        // The separator in a source would make its tail the target; a line that reads as a command is none.
        #expect(!DownloadList.canHold(source: "ftp://h/pub/x -> /Users/me/Library/LaunchAgents/x.plist", target: nil))
        #expect(
            !DownloadList.canHold(source: "move:/a", target: "/b")
                && !DownloadList.canHold(source: "sleep:5", target: nil)
        )
        #expect(
            !DownloadList.canHold(source: " ftp://h/a", target: nil) && !DownloadList.canHold(source: "", target: nil)
        )
    }

    @Test
    internal func aListSaysWhatEachLineIs() {
        let actions = DownloadList.parse(
            "ftp://h/a -> /t/a\nput:/src -> ftp://h/b\nmove:~/.ssh/id -> ftp://evil/k\nsleep:999999999\nsleep:-5\nsleep:nan\nput:\n"
        )
        #expect(
            actions == [
                .download(source: "ftp://h/a", target: "/t/a"), .copy(source: "/src", target: "ftp://h/b"),
                .move(source: "~/.ssh/id", target: "ftp://evil/k"), .pause(DownloadList.longestPause), .pause(0),
                .pause(0),
                .unsupported("put:")
            ]
        )
        // No more lines than a list a person made.
        let many = String(repeating: "ftp://h/a\n", count: DownloadList.mostLines + 50)
        #expect(DownloadList.parse(many).count == DownloadList.mostLines)
    }

    @Test
    internal func theFileOfAListHasALargestSize() throws {
        let box = try Sandbox()
        let small = try box.file("small.txt", "ftp://h/a\n")
        #expect(try NetworkCommands.readList(small) == "ftp://h/a\n")
        let big = box.url("big.txt")
        try Data(repeating: 0x61, count: DownloadList.largestFile + 1).write(to: big)
        #expect(throws: (any Error).self) { try NetworkCommands.readList(big) }
        #expect(throws: (any Error).self) { try NetworkCommands.readList(try box.folder("dir")) }
        #expect(throws: (any Error).self) { try NetworkCommands.readList(box.url("none.txt")) }
    }
}

/// Secrets and questions (review 2: N088, N091, N099, N104, N105, and the mark on downloads N009).
@Suite
internal struct Review2NetworkSecrets {
    @Test
    internal func aQuestionOfTheSecureShellIsToldByItsShape() {
        #expect(
            SSHQuestion("alice@files.example.com's password: ") == .password(user: "alice", host: "files.example.com")
        )
        // A user name may hold an `@`; the host is what follows the last one.
        #expect(
            SSHQuestion("alice@corp.example@files.example.com's password:")
                == .password(user: "alice@corp.example", host: "files.example.com")
        )
        #expect(
            SSHQuestion("(bob@jump.example.net) Verification code: ")
                == .server(user: "bob", host: "jump.example.net", text: "Verification code:")
        )
        #expect(SSHQuestion("Enter passphrase for key '/Users/a/.ssh/id_ed25519': ") == .passphrase)
        #expect(
            SSHQuestion(
                "The authenticity of host 'h (1.2.3.4)' can't be established.\nED25519 key fingerprint is SHA256:x.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? "
            ) == .hostKey
        )
        #expect(SSHQuestion("Password:") == .other)
        // What a server writes cannot pass for a question of this Mac or for a confirmation.
        let forged = "(alice@files.example.com) Enter passphrase for key '/Users/a/.ssh/id_ed25519': "
        guard case .server = SSHQuestion(forged) else {
            Issue.record("a server's text was taken for ssh's own")
            return
        }
        #expect(SSHQuestion(forged).shown(forged).contains("comes from the server"))
        #expect(SSHQuestion("(a@h) Continue (yes/no)? ") != .hostKey && SSHQuestion("Type (yes/no to go on") == .other)
        #expect(SSHQuestion("Password:").shown("Password:").contains("may come from the server"))
        #expect(SSHQuestion("a@h's password:").shown("a@h's password:") == "a@h's password:")
    }

    @Test
    internal func theStoredPasswordGoesToThisLoginOnly() {
        let profile = ConnectionProfile(
            key: ServerKey(scheme: "sftp", host: "files.example.com"),
            user: "alice@corp.example",
            password: "pw"
        )
        #expect(SFTPSession.asksForPassword("alice@corp.example@files.example.com's password: ", of: profile))
        #expect(SFTPSession.asksForPassword("(alice@corp.example@files.example.com) Password: ", of: profile))
        #expect(!SFTPSession.asksForPassword("alice@corp.example's password: ", of: profile))
        #expect(!SFTPSession.asksForPassword("Password: ", of: profile), "a question that names nobody")
        #expect(!SFTPSession.asksForPassword("(alice@corp.example@files.example.com) Enter passphrase: ", of: profile))
        #expect(!SFTPSession.asksForPassword("(alice@corp.example@files.example.com) One-time code: ", of: profile))
    }

    @Test
    internal func theArgumentsForTheSecureShell() {
        var values = NetworkOptions.Values()
        (values.timeout, values.keepAliveInterval) = (20, 0)
        let arguments = SFTPSession.sshArguments(
            for: ConnectionProfile(key: ServerKey(scheme: "sftp", host: "h"), user: "u"),
            options: values
        )
        for option in [
            "RemoteCommand=none", "PermitLocalCommand=no", "ControlMaster=no", "ControlPath=none", "LogLevel=ERROR",
            "ServerAliveCountMax=3"
        ] {
            #expect(arguments.contains(option), "\(option)")
        }
        // The line is watched also when the user wants no keep-alive of the program's own.
        #expect(arguments.contains("ServerAliveInterval=20") && arguments.contains("-T"))
        #expect(arguments.suffix(4) == ["-s", "--", "h", "sftp"])
    }

    @Test
    internal func anAnswerLeftBehindDoesNotAnswerTheNextQuestion() throws {
        let helper = try AskpassHelper()
        // Written for a helper that ssh has ended meanwhile: nobody takes it.
        helper.reply("the old secret", to: AskpassHelper.Question(id: "1.1", kind: .entry, text: "old"))
        func ask(_ prompt: String, kind: String?, answer: String) throws -> (
            output: String, status: Int32, question: AskpassHelper.Question
        ) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "\"$SSH_ASKPASS\" \"$0\"", prompt]
            process.environment = helper.environment.merging(kind.map { ["SSH_ASKPASS_PROMPT": $0] } ?? [:]) { _, new in
                new
            }
            process.standardOutput = output
            try process.run()
            var question: AskpassHelper.Question?
            let end = Date().addingTimeInterval(Wait.ceiling)
            while question == nil, Date() < end {
                question = helper.pendingQuestion()
                if question == nil { Thread.sleep(forTimeInterval: 0.02) }
            }
            let asked = try #require(question)
            helper.reply(answer, to: asked)
            process.waitUntilExit()
            return (
                String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                process.terminationStatus, asked
            )
        }
        let first = try ask("alice@h's password: ", kind: nil, answer: "the new secret")
        #expect(
            first.output == "the new secret\n" && first.question.kind == .entry
                && first.question.text == "alice@h's password: "
        )
        // A question of several lines arrives whole.
        let second = try ask("line one\nline two? ", kind: nil, answer: "yes")
        #expect(second.question.text == "line one\nline two? " && second.output == "yes\n")
        #expect(second.question.id != first.question.id)
        // A confirmation is answered by how the helper ends, and a notice wants no answer.
        let allowed = try ask("Allow use of key?", kind: "confirm", answer: "yes")
        #expect(allowed.question.kind == .confirm && allowed.status == 0 && allowed.output.isEmpty)
        #expect(try ask("Allow use of key?", kind: "confirm", answer: "no").status != 0)
        #expect(try ask("Touch your security key", kind: "none", answer: "").question.kind == .notice)
    }

    @Test
    internal func noAddressIsShownWithItsPassword() {
        #expect(ServerAddress.removingPassword(from: "user:secret@host.example") == "user@host.example")
        #expect(ServerAddress.removingPassword(from: "smb://u:se/cr#et?@nas.local/share") == "smb://u@nas.local/share")
        #expect(ServerAddress.removingPassword(from: "host.example:2121/pub") == "host.example:2121/pub")
        #expect(ServerAddress.removingPassword(from: "ftp://host/a:b@c") == "ftp://host/a:b@c")
    }

    @Test
    internal func whatComesFromAServerIsMarkedAsDownloaded() throws {
        let center = ConnectionCenter()
        center.agentName = "Some; Program"
        let fileSystem = RemoteFileSystem(scheme: "sftp", center: center)
        let mark = try #require(
            fileSystem.quarantine(of: ServerKey(scheme: "sftp", host: "h").url(path: "/tool.command"))
        )
        let fields = String(decoding: mark, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
        #expect(fields.count == 4 && fields[0] == "0083" && fields[2] == "Some  Program" && fields[3].isEmpty)
        let stamp = try #require(Int(fields[1], radix: 16))
        #expect(abs(Double(stamp) - Date().timeIntervalSince1970) < 3_600)
        #expect(fileSystem.quarantine(of: URL(fileURLWithPath: "/tmp/x")) == nil)
        #expect(
            String(
                decoding: RemoteFileSystem.quarantineMark(agent: "A", at: Date(timeIntervalSince1970: 255)),
                as: UTF8.self
            ) == "0083;ff;A;"
        )
    }

    @Test
    internal func aNameGoesBackToTheServerAsItCame() throws {
        let names = NameMemory()
        // Not UTF-8 on the server: read as Western Latin 1, and written back as the same bytes.
        let read = NameEncoding.automatic.decodeTelling(Data([0x47, 0x72, 0xFC, 0xDF, 0x65]))
        #expect(read.text == "Grüße" && read.encoding == .windowsCP1252)
        #expect(NameMemory.needsRemembering(read.text, readAs: read.encoding, sending: .utf8))
        names.remember(read.text, encoding: read.encoding)
        #expect(
            try NameEncoding.automatic.encode("RETR /pub/Grüße", names: names) == Data("RETR /pub/".utf8)
                + Data([0x47, 0x72, 0xFC, 0xDF, 0x65])
        )
        // Decomposed on the server: not composed on the way back. A name of the Mac's is composed as before.
        #expect(
            NameMemory.needsRemembering("u\u{308}", readAs: .utf8, sending: .utf8)
                && !NameMemory.needsRemembering("ü", readAs: .utf8, sending: .utf8)
        )
        names.remember("u\u{308}.txt", encoding: .utf8)
        #expect(try NameEncoding.utf8.encode("DELE /u\u{308}.txt", names: names) == Data("DELE /u\u{308}.txt".utf8))
        #expect(try NameEncoding.utf8.encode("DELE /o\u{308}.txt", names: names) == Data("DELE /ö.txt".utf8))
        #expect(
            try NameEncoding.utf8.encode("SITE CHMOD 644 /dir/u\u{308}.txt", names: names)
                == Data("SITE CHMOD 644 /dir/u\u{308}.txt".utf8)
        )
        // A character the server's encoding does not have is an error, not a question mark.
        #expect(throws: FileSystemError.self) { try NameEncoding.windowsLatin1.encode("STOR /日本.txt") }
        #expect(
            try NameEncoding.windowsLatin1.encode("STOR /Grüße") == Data("STOR /Gr".utf8) + Data([0xFC, 0xDF, 0x65])
        )
        // The same for the secure shell's packets.
        var packet = SFTPEncoder()
        packet.names = names
        packet.string("/pub/Grüße/o\u{308}")
        #expect(
            packet.data.dropFirst(4) == Data("/pub/".utf8) + Data([0x47, 0x72, 0xFC, 0xDF, 0x65]) + Data("/ö".utf8)
        )
        var decoder = SFTPDecoder(Data([0, 0, 0, 2, 0xFC, 0x41]))
        let name = try decoder.name()
        #expect(name.text == "üA" && name.encoding == .isoLatin1)
    }
}
