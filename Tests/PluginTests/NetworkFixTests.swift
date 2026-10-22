import AFMKernel
import Foundation
import Security
import TestSupport
import Testing

@testable import NetworkPlugin

/// Names from a server are one path component, whatever the server says (a name with a slash
/// would put a downloaded file outside the folder the user chose).
@Suite
internal struct NetworkFixNames {
    @Test
    internal func theSharedCheck() {
        #expect(RemoteEntry.isSafeName("report.txt"))
        #expect(RemoteEntry.isSafeName("..."))
        #expect(RemoteEntry.isSafeName(".hidden"))
        #expect(RemoteEntry.isSafeName("a\\b"))
        for bad in ["", ".", "..", "../x", "a/b", "/etc/passwd", "x/", "a\0b", "../../Library/LaunchAgents/x.plist"] {
            #expect(!RemoteEntry.isSafeName(bad), "\(bad)")
        }
        #expect(!RemoteEntry.isSafeName("a\\b", isDOSFormat: true))
    }

    @Test
    internal func mlsdAndMlstDropThem() {
        #expect(FTPListParser.mlsd("type=file;size=1; ../../x.plist") == nil)
        #expect(FTPListParser.mlsd("type=file;size=1; sub/x") == nil)
        #expect(FTPListParser.mlsd("type=file;size=1; nul\0x") == nil)
        #expect(FTPListParser.mlsd("type=file;size=1; fine.txt")?.name == "fine.txt")
        // MLST names a whole path, of which the last name is kept.
        #expect(FTPListParser.mlst(" type=file;size=1; /pub/fine.txt")?.name == "fine.txt")
        #expect(FTPListParser.mlst(" type=file;size=1; /pub/..") == nil)
    }

    @Test
    internal func listDropsThemInEveryFormat() {
        let unix = "-rw-r--r--   1 owner    group          12 Jan 31  2024 "
        #expect(FTPListParser.list(unix + "../../Library/x.plist") == nil)
        #expect(FTPListParser.list(unix + "a/b") == nil)
        #expect(FTPListParser.list(unix + "ok.txt")?.name == "ok.txt")
        // A backslash is an ordinary character in a Unix name.
        #expect(FTPListParser.list(unix + "a\\b")?.name == "a\\b")
        // A link whose own name is not safe.
        #expect(FTPListParser.list("lrwxrwxrwx   1 owner    group          12 Jan 31  2024 ../l -> target") == nil)
        #expect(
            FTPListParser.list("lrwxrwxrwx   1 owner    group          12 Jan 31  2024 l -> ../target")?.name == "l"
        )

        let dos = "01-31-24  03:04PM              1,234 "
        #expect(FTPListParser.list(dos + "..\\..\\evil.exe") == nil)
        #expect(FTPListParser.list(dos + "sub\\evil.exe") == nil)
        #expect(FTPListParser.list(dos + "../evil.exe") == nil)
        #expect(FTPListParser.list(dos + "ok.exe")?.name == "ok.exe")
        #expect(FTPListParser.list("01-31-24  03:04PM       <DIR>          ..\\up") == nil)

        #expect(FTPListParser.list("+i8388621.29609,m824255902,/,\t../../dev") == nil)
        #expect(FTPListParser.list("+i8388621.29609,m824255902,/,\ta/b") == nil)
        #expect(FTPListParser.list("+i8388621.29609,m824255902,/,\tdev")?.name == "dev")
    }

    @Test(arguments: [true, false])
    internal func aListingFromAServerKeepsOnlyTheSafeNames(mlsd: Bool) throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = mlsd
        options.injectedLines =
            mlsd
            ? ["type=file;size=3; ../../evil", "type=file;size=3; a/b", "type=file;size=3; injected.txt"]
            : [
                "-rw-r--r--   1 o g 3 Jan 01  2020 ../../evil", "-rw-r--r--   1 o g 3 Jan 01  2020 a/b",
                "-rw-r--r--   1 o g 3 Jan 01  2020 injected.txt"
            ]
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/real.txt", "r")
        let items = try fixture.fileSystem.list(fixture.url("/"), showHidden: true)
        #expect(items.map(\.name).sorted() == ["injected.txt", "real.txt"])
        // Every URL stays directly below the listed folder.
        #expect(items.allSatisfy { $0.url.deletingLastPathComponent().path == "/" })
    }

    @Test
    internal func theSFTPListingCheckIsTheSameFunction() {
        // The SFTP loop filters with `RemoteEntry.isSafeName`; the system's server cannot
        // be made to send such a name, so the rule itself is what is tested above.
        #expect(!RemoteEntry.isSafeName("../x") && !RemoteEntry.isSafeName("a/b"))
    }
}

/// Addresses and prompts that carry secrets.
@Suite
internal struct NetworkFixSecrets {
    @Test
    internal func aPasswordIsNotRemembered() {
        #expect(
            ServerAddress.removingPassword(from: "smb://alice:s3cret@files.example.com/share")
                == "smb://alice@files.example.com/share"
        )
        #expect(
            ServerAddress.removingPassword(from: "https://bob:p%40ss@dav.example.com:8443/a/b?x=1")
                == "https://bob@dav.example.com:8443/a/b?x=1"
        )
        #expect(ServerAddress.removingPassword(from: "afp://carol@host/vol") == "afp://carol@host/vol")
        #expect(
            ServerAddress.removingPassword(from: "nfs://host/export:with:colons@here")
                == "nfs://host/export:with:colons@here"
        )
        #expect(ServerAddress.removingPassword(from: "smb://") == "smb://")
        // Also without a scheme, and with a slash in the password.
        #expect(ServerAddress.removingPassword(from: "no scheme:pw@host") == "no scheme@host")
        #expect(ServerAddress.removingPassword(from: "smb://u:pa/ss@h/share") == "smb://u@h/share")
        #expect(ServerAddress.removingPassword(from: "smb://host:445/share/a@b") == "smb://host:445/share/a@b")
        #expect(ServerAddress.removingPassword(from: "smb://u:p:w@h/s") == "smb://u@h/s")
    }

    @Test
    internal func theStoredPasswordAnswersOnlyThisServersPrompt() {
        let profile = ConnectionProfile(
            key: ServerKey(scheme: "sftp", host: "Files.Example.com"),
            user: "alice",
            password: "pw"
        )
        let asks = { (question: String) in SFTPSession.asksForPassword(question, of: profile) }
        #expect(asks("alice@files.example.com's password: "))
        #expect(asks("(alice@files.example.com) Password: "))
        // A question that names nobody may come from anyone; the user is asked instead.
        #expect(!asks("Password: "))
        // A jump host, or the same host with another user, gets nothing.
        #expect(!asks("bob@jump.example.net's password: "))
        #expect(!asks("alice@jump.example.net's password: "))
        #expect(!asks("bob@files.example.com's password: "))
        #expect(!asks("(jumper@jump.example.net) Password: "))
        // Other questions are no request for the password.
        #expect(!asks("Enter passphrase for key '/Users/a/.ssh/id_ed25519': "))
        #expect(!asks("Are you sure you want to continue connecting (yes/no/[fingerprint])? "))

        let v6 = ConnectionProfile(key: ServerKey(scheme: "sftp", host: "[::1]"), user: "alice", password: "pw")
        #expect(SFTPSession.asksForPassword("alice@::1's password: ", of: v6))
        #expect(!SFTPSession.asksForPassword("alice@::2's password: ", of: v6))
        let anyUser = ConnectionProfile(key: ServerKey(scheme: "sftp", host: "h.example"), password: "pw")
        #expect(SFTPSession.asksForPassword("whoever@h.example's password: ", of: anyUser))
    }
}

/// Text-mode conversion in blocks, against the plain byte-by-byte rule.
@Suite
internal struct NetworkFixLineEnds {
    private struct Reference {
        var pendingCR = false
        mutating func toLocal(_ data: Data) -> Data {
            var result = Data()
            for byte in data {
                if pendingCR {
                    pendingCR = false
                    if byte != 0x0A { result.append(0x0D) }
                }
                if byte == 0x0D { pendingCR = true } else { result.append(byte) }
            }
            return result
        }
        mutating func finish() -> Data {
            defer { pendingCR = false }
            return pendingCR ? Data([0x0D]) : Data()
        }
        mutating func toNetwork(_ data: Data) -> Data {
            var result = Data()
            for byte in data {
                if byte == 0x0A, !pendingCR { result.append(0x0D) }
                pendingCR = byte == 0x0D
                result.append(byte)
            }
            return result
        }
    }

    @Test
    internal func agreesWithTheByteByByteRule() {
        var generator = SystemRandomNumberGenerator()
        let alphabet: [UInt8] = [0x0D, 0x0A, 0x41, 0x0D, 0x0A, 0x20]
        for _ in 0..<300 {
            // Random data cut into random blocks, rich in CR and LF.
            let data = Data(
                (0..<Int.random(in: 0...120, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }
            )
            var cuts = [0]
            while cuts.last! < data.count {
                cuts.append(min(data.count, cuts.last! + Int.random(in: 0...9, using: &generator)))
            }
            var (local, reference) = (LineEndConverter(), Reference())
            var (got, expected) = (Data(), Data())
            for index in 1..<cuts.count {
                let block = data.subdata(in: cuts[index - 1]..<cuts[index])
                got.append(local.toLocal(block))
                expected.append(reference.toLocal(block))
            }
            got.append(local.finishLocal())
            expected.append(reference.finish())
            #expect(got == expected)

            var (outgoing, outgoingReference) = (LineEndConverter(), Reference())
            var (sent, sentExpected) = (Data(), Data())
            for index in 1..<cuts.count {
                let block = data.subdata(in: cuts[index - 1]..<cuts[index])
                sent.append(outgoing.toNetwork(block))
                sentExpected.append(outgoingReference.toNetwork(block))
            }
            #expect(sent == sentExpected)
        }
        var converter = LineEndConverter()
        #expect(converter.toLocal(Data("a\r\nb\r\n".utf8)) == Data("a\nb\n".utf8))
        #expect(converter.toNetwork(Data("a\nb\r\nc\n".utf8)) == Data("a\r\nb\r\nc\r\n".utf8))
        #expect(converter.toLocal(Data()).isEmpty && converter.toNetwork(Data()).isEmpty)
    }
}

/// The directory cache keeps up with what this program does, and the cost of a copy stays linear.
@Suite
internal struct NetworkFixCache {
    private func lists(_ fixture: FTPFixture) -> Int {
        fixture.server.commands.filter { $0 == "LIST -la" || $0 == "LIST" }.count
    }

    @Test
    internal func manyUploadsToAServerWithoutMLSTListTheFolderOnce() throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = false
        let fixture = try FTPFixture(options)
        try fixture.box.folder("srv/in")
        _ = try fixture.center.connect(fixture.key)
        for index in 0..<12 {
            let target = fixture.url("/in/file\(index).dat")
            let content = Data(repeating: UInt8(index), count: 1_000 + index)
            // The checks a copy job makes before it writes.
            #expect(fixture.fileSystem.item(at: target) == nil)
            #expect(fixture.fileSystem.item(at: target) == nil)
            try fixture.upload(
                "/in/file\(index).dat",
                content,
                attributes: FileAttributes(modified: Date(timeIntervalSince1970: 1_600_000_000))
            )
            let item = try #require(fixture.fileSystem.item(at: target))
            #expect(item.size == Int64(content.count) && item.modified == Date(timeIntervalSince1970: 1_600_000_000))
        }
        // One listing for the first question, one for the first file; not three for each of twelve.
        #expect(lists(fixture) <= 3, "\(lists(fixture)) listings")
        #expect(try fixture.names("/in").count == 12)
    }

    @Test
    internal func removingFromAListedFolderAsksNoQuestions() throws {
        let fixture = try FTPFixture()
        for index in 0..<6 { try fixture.box.file("srv/d/f\(index).txt", "x") }
        try fixture.box.folder("srv/d/sub")
        _ = try fixture.names("/d")
        for index in 0..<6 { try fixture.fileSystem.remove(fixture.url("/d/f\(index).txt")) }
        try fixture.fileSystem.remove(fixture.url("/d/sub"))
        let commands = fixture.server.commands
        // Files go with DELE and the folder with RMD, without trying the wrong one first.
        #expect(commands.filter { $0.hasPrefix("DELE") }.count == 6)
        #expect(commands.filter { $0.hasPrefix("RMD") }.count == 1)
        let before = commands.count
        #expect(fixture.fileSystem.item(at: fixture.url("/d/f0.txt")) == nil)
        #expect(fixture.server.commands.count == before)
        #expect(try fixture.names("/d").isEmpty)
    }

    @Test
    internal func aRenameIsEnteredIntoTheListings() throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = false
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/a.txt", "abc")
        try fixture.box.folder("srv/sub")
        _ = try fixture.names("/")
        _ = try fixture.names("/sub")
        let before = lists(fixture)
        try fixture.fileSystem.move(fixture.url("/a.txt"), to: fixture.url("/sub/b.txt"), replacing: false)
        #expect(fixture.fileSystem.item(at: fixture.url("/a.txt")) == nil)
        #expect(fixture.fileSystem.item(at: fixture.url("/sub/b.txt"))?.size == 3)
        #expect(lists(fixture) == before)
        // A listing read again always asks the server.
        try fixture.box.file("srv/sub/outside.txt", "o")
        #expect(try fixture.names("/sub") == ["b.txt", "outside.txt"])
    }

    @Test
    internal func aFolderMadeIsKnownAtOnce() throws {
        let fixture = try FTPFixture()
        _ = try fixture.names("/")
        try fixture.fileSystem.createDirectory(at: fixture.url("/new"))
        let before = fixture.server.commands.count
        #expect(fixture.fileSystem.item(at: fixture.url("/new"))?.isDirectory == true)
        #expect(fixture.server.commands.count == before)
        // Making it again is no error and sends nothing.
        try fixture.fileSystem.createDirectory(at: fixture.url("/new"))
        #expect(fixture.server.commands.filter { $0.hasPrefix("MKD") }.count == 1)
    }

    @Test
    internal func anAbandonedUploadMakesTheFolderBeReadAgain() throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = false
        let fixture = try FTPFixture(options)
        _ = try fixture.center.connect(fixture.key)
        _ = try fixture.names("/")
        var writer: (any FileWriter)? = try fixture.fileSystem.write(fixture.url("/partial.bin"))
        try writer?.write(Data(repeating: 1, count: 100))
        // Dropped without close: what the folder holds is not known any more.
        writer = nil
        let before = fixture.server.commands.count
        _ = fixture.fileSystem.item(at: fixture.url("/partial.bin"))
        #expect(fixture.server.commands.count > before)
    }
}

/// The connections to an FTP server and what runs on them.
@Suite
internal struct NetworkFixConnections {
    @Test
    internal func downloadsAndCopiesStayWithinTheConnectionLimit() throws {
        let fixture = try FTPFixture { $0.parallelConnections = 2 }
        let content = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        for index in 0..<8 { try content.write(to: fixture.box.url("srv/f\(index).bin")) }
        _ = try fixture.center.connect(fixture.key)

        let failures = FailureBox()
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            do {
                // Like a copy job: a file is open for reading while another is written on the same server.
                let reader = try fixture.fileSystem.read(fixture.url("/f\(index).bin"))
                defer { reader.close() }
                var data = try #require(try reader.read(upToCount: 50_000))
                try fixture.upload("/copy\(index).bin", content)
                while let block = try reader.read(upToCount: 64 * 1_024) { data.append(block) }
                if data != content { failures.add("content \(index)") }
            } catch {
                failures.add("\(error)")
            }
        }
        #expect(failures.all.isEmpty, "\(failures.all)")
        for index in 0..<8 { #expect(try Data(contentsOf: fixture.box.url("srv/copy\(index).bin")) == content) }
        // Three slots for reading and three for writing, at the very most.
        #expect(fixture.server.mostConnectionsAtOnce <= 6, "\(fixture.server.mostConnectionsAtOnce) connections")
    }

    @Test
    internal func manyDownloadsAtOnceWaitForAFreeConnection() throws {
        let fixture = try FTPFixture { $0.parallelConnections = 2 }
        let content = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0) })
        for index in 0..<10 { try content.write(to: fixture.box.url("srv/f\(index).bin")) }
        _ = try fixture.center.connect(fixture.key)
        let failures = FailureBox()
        DispatchQueue.concurrentPerform(iterations: 10) { index in
            do {
                if try fixture.download("/f\(index).bin") != content { failures.add("content \(index)") }
            } catch {
                failures.add("\(error)")
            }
        }
        #expect(failures.all.isEmpty, "\(failures.all)")
        #expect(fixture.server.mostConnectionsAtOnce <= 3, "\(fixture.server.mostConnectionsAtOnce) connections")
    }

    @Test
    internal func aBusyServerIsAskedAgain() throws {
        let fixture = try FTPFixture { $0.parallelConnections = 3 }
        try fixture.box.file("srv/a.txt", "a")
        try fixture.box.file("srv/big.bin", String(repeating: "x", count: 100_000))
        _ = try fixture.center.connect(fixture.key)
        // A file held open takes the one connection; the listing needs another, and the server refuses twice.
        let reader = try fixture.fileSystem.read(fixture.url("/big.bin"))
        defer { reader.close() }
        _ = try reader.read(upToCount: 10)
        fixture.server.options.busyGreetings = 2
        #expect(try fixture.names("/") == ["a.txt", "big.bin"])
        #expect(fixture.server.connectionsOpened == 4)
    }

    @Test
    internal func aCommandWhoseReplyIsLostIsNotRepeated() throws {
        let fixture = try FTPFixture()
        _ = try fixture.names("/")
        let session = try fixture.center.session(for: fixture.key)
        fixture.server.options.dropReplyFor = "MKD"
        #expect(throws: NetworkError.self) { try session.makeDirectory("/made", cancellation: nil) }
        fixture.server.options.dropReplyFor = nil
        #expect(fixture.box.exists("srv/made"))
        #expect(fixture.server.commands.filter { $0.hasPrefix("MKD") }.count == 1)
        // A question is asked again on a new connection.
        fixture.server.dropConnections()
        #expect(try fixture.names("/") == ["made"])
    }

    @Test
    internal func closingAReaderEndsAReadThatWaitsForTheServer() throws {
        let fixture = try FTPFixture { $0.timeout = 600 }
        try fixture.box.file("srv/f.bin", String(repeating: "z", count: 1_000))
        fixture.server.options.stallRETR = true
        let reader = try fixture.fileSystem.read(fixture.url("/f.bin"))
        let outcome = FailureBox()
        let finished = DispatchSemaphore(value: 0)
        Thread {
            do {
                _ = try reader.read(upToCount: 100)
                outcome.add("returned")
            } catch {
                outcome.add("threw")
            }
            finished.signal()
        }
        .start()
        // Until the server has the request, the read is under way but there is nothing to cut.
        let waitUntil = Date().addingTimeInterval(Wait.ceiling)
        while !fixture.server.commands.contains(where: { $0.hasPrefix("RETR") }), Date() < waitUntil {
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.3)
        let started = Date()
        reader.close()
        // Long before the ten minutes the read would wait for the server by itself.
        #expect(finished.wait(timeout: .now() + Wait.ceiling) == .success)
        #expect(Date().timeIntervalSince(started) < 120)
        #expect(outcome.all == ["threw"], "\(outcome.all)")
    }

    @Test
    internal func aDataConnectionThatBreaksIsAnErrorNotAnEnd() throws {
        let fixture = try FTPFixture()
        try Data(repeating: 7, count: 300_000).write(to: fixture.box.url("srv/f.bin"))
        fixture.server.options.resetRETRAfter = 100_000
        #expect(throws: (any Error).self) { _ = try fixture.download("/f.bin") }
    }

    @Test
    internal func theDataConnectionGoesToTheControlConnectionsAddress() throws {
        let fixture = try FTPFixture()
        let stream = NetStream(host: "localhost", port: fixture.server.port)
        stream.start()
        defer { stream.close() }
        try stream.waitUntilReady(timeout: Wait.ceiling)
        #expect(stream.remoteAddress == "127.0.0.1")
    }

    @Test
    internal func linkTargetsAreAskedOnceAndNotAgain() throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = false
        let fixture = try FTPFixture(options)
        try fixture.box.folder("srv/realdir")
        try fixture.box.file("srv/real.txt", "r")
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: fixture.box.url("srv/ldir").path, withDestinationPath: "realdir")
        try fm.createSymbolicLink(atPath: fixture.box.url("srv/lfile").path, withDestinationPath: "real.txt")
        try fm.createSymbolicLink(atPath: fixture.box.url("srv/ldead").path, withDestinationPath: "nowhere")
        try fm.createSymbolicLink(atPath: fixture.box.url("srv/lslash").path, withDestinationPath: "realdir/")

        let probes = { fixture.server.commands.filter { $0.hasPrefix("CWD /l") }.count }
        var items = try fixture.fileSystem.list(fixture.url("/"), showHidden: true)
            .filter(\.isSymlink)
            .sorted { $0.name < $1.name }
        #expect(items.map(\.name) == ["ldead", "ldir", "lfile", "lslash"])
        #expect(items.map(\.isDirectory) == [false, true, false, true])
        // The one whose target is spelled as a folder is not asked about; the others once each.
        #expect(probes() == 3)
        items = try fixture.fileSystem.list(fixture.url("/"), showHidden: true)
            .filter(\.isSymlink)
            .sorted { $0.name < $1.name }
        #expect(items.map(\.isDirectory) == [false, true, false, true])
        #expect(probes() == 3)
    }
}

/// Collects strings from several threads.
internal final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    internal func add(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
    internal var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// TLS: the data connections must be protected, and a certificate must be good for an address.
@Suite(.enabled(if: TLSServer.isAvailable))
internal struct NetworkFixTLS {
    @Test
    internal func aServerThatRefusesToProtectItsDataIsNotUsed() throws {
        let box = try Sandbox()
        try box.file("srv/hello.txt", "hello")
        let server = try TLSServer(mode: .explicit, box: box, refusesProtection: true)
        defer { server.stop() }
        let environment = SessionEnvironment()
        environment.declineMemory = 0
        var values = NetworkOptions.Values()
        (values.timeout, values.keepAliveInterval) = (10, 0)
        environment.options.values = values
        environment.askToTrust = { [trust = environment.trust] profile, certificate in
            trust.accept(certificate.fingerprint, for: profile.key.host)
            return true
        }
        let center = ConnectionCenter(environment: environment)
        center.makeSession = { profile, environment in FTPSession(profile: profile, environment: environment) }
        let fileSystem = RemoteFileSystem(scheme: "ftps", center: center)
        let key = ServerKey(scheme: "ftps", host: "127.0.0.1", port: server.port)
        center.announce(ConnectionProfile(key: key, tls: .explicit, anonymous: true))
        defer { center.disconnectAll() }
        do {
            _ = try fileSystem.list(key.url(), showHidden: true)
            Issue.record("the listing went through without protection")
        } catch let error as NetworkError {
            if case .unexpected(let text) = error {
                #expect(text.contains("PROT P") && text.contains("unprotected"))
            } else {
                Issue.record("\(error)")
            }
        }
        #expect(!center.isConnected(key))
    }

    /// A self-signed certificate for an address, made with the system's openssl.
    private func certificate(altNames: String, in box: Sandbox) throws -> SecCertificate {
        let (pem, der) = (box.url("san.pem"), box.url("san.der"))
        let make = Process()
        make.executableURL = URL(fileURLWithPath: TLSServer.openssl)
        make.arguments = [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", box.url("san.key").path, "-out", pem.path,
            "-days", "2",
            "-subj", "/CN=nobody", "-addext", "subjectAltName=\(altNames)", "-addext", "extendedKeyUsage=serverAuth",
            "-addext", "basicConstraints=critical,CA:FALSE"
        ]
        (make.standardOutput, make.standardError) = (FileHandle.nullDevice, FileHandle.nullDevice)
        try make.run()
        make.waitUntilExit()
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: TLSServer.openssl)
        convert.arguments = ["x509", "-in", pem.path, "-outform", "der", "-out", der.path]
        try convert.run()
        convert.waitUntilExit()
        return try #require(SecCertificateCreateWithData(nil, try Data(contentsOf: der) as CFData))
    }

    private func chain(of certificate: SecCertificate) throws -> SecTrust {
        var trust: SecTrust?
        SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, nil), &trust)
        let created = try #require(trust)
        // The certificate vouches for itself, so that only the name is in question.
        SecTrustSetAnchorCertificates(created, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(created, true)
        return created
    }

    @Test
    internal func anAddressMustBeAmongTheCertificatesAddresses() throws {
        let box = try Sandbox()
        let certificate = try certificate(altNames: "IP:127.0.0.1,DNS:named.example", in: box)

        let right = TLSSettings(host: "127.0.0.1", trust: CertificateTrust())
        #expect(right.evaluate(try chain(of: certificate)))
        #expect(right.rejected == nil)

        // Another address is not covered by the certificate, however valid the chain is.
        let trust = CertificateTrust()
        let wrong = TLSSettings(host: "127.0.0.2", trust: trust)
        #expect(!wrong.evaluate(try chain(of: certificate)))
        let shown = try #require(wrong.rejected)
        // The user is asked, and a certificate accepted for that address is good from then on.
        trust.accept(shown.fingerprint, for: "127.0.0.2")
        #expect(wrong.evaluate(try chain(of: certificate)))
        #expect(!TLSSettings(host: "127.0.0.3", trust: trust).evaluate(try chain(of: certificate)))

        // Names are checked as before.
        #expect(TLSSettings(host: "named.example", trust: CertificateTrust()).evaluate(try chain(of: certificate)))
        #expect(!TLSSettings(host: "other.example", trust: CertificateTrust()).evaluate(try chain(of: certificate)))
    }
}
