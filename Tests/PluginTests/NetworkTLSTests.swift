import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// FTP over TLS against a server with a self-signed certificate.
///
/// The in-process test server speaks no TLS, so this one is a short script for the Python that
/// comes with the developer tools, with a certificate made by `/usr/bin/openssl` in the sandbox;
/// where one of the two is missing the tests are skipped.
@Suite(.enabled(if: TLSServer.isAvailable))
struct NetworkTLS {
    @Test(arguments: [TLSMode.explicit, .implicit])
    func connectsListsAndTransfers(mode: TLSMode) throws {
        let box = try Sandbox()
        try box.file("srv/hello.txt", "hello over TLS")
        let server = try TLSServer(mode: mode, box: box)
        defer { server.stop() }

        let environment = SessionEnvironment()
        environment.declineMemory = 0
        var values = NetworkOptions.Values()
        (values.timeout, values.keepAliveInterval) = (10, 0)
        environment.options.values = values
        let center = ConnectionCenter(environment: environment)
        center.makeSession = { profile, environment in FTPSession(profile: profile, environment: environment) }
        let fileSystem = RemoteFileSystem(scheme: "ftps", center: center)
        let key = ServerKey(scheme: "ftps", host: "127.0.0.1", port: server.port)
        center.announce(ConnectionProfile(key: key, tls: mode, anonymous: true))
        defer { center.disconnectAll() }

        // The certificate is signed by nobody the system knows: the user is asked, and No ends it.
        nonisolated(unsafe) var shown: [CertificateInfo] = []
        let accepts = Shared(false)
        environment.askToTrust = { [trust = environment.trust] profile, certificate in
            shown.append(certificate)
            if accepts.value { trust.accept(certificate.fingerprint, for: profile.key.host) }
            return accepts.value
        }
        #expect(throws: NetworkError.self) { try fileSystem.list(key.url(), showHidden: true) }
        #expect(shown.count == 1 && shown[0].subject.contains("localhost") && shown[0].fingerprint.count == 95)
        #expect(!center.isConnected(key))

        accepts.value = true
        #expect(try fileSystem.list(key.url(), showHidden: true).map(\.name) == ["hello.txt"])
        #expect(shown.count == 2)
        // Data connections are encrypted as well (PROT P), in both directions.
        let reader = try fileSystem.read(key.url(path: "/hello.txt"))
        #expect(try reader.read(upToCount: 100) == Data("hello over TLS".utf8))
        #expect(try reader.read(upToCount: 100) == nil)
        reader.close()
        let content = Data((0..<2_000_000).map { UInt8(truncatingIfNeeded: $0) })
        let session = try center.session(for: key)
        let writer = try session.openWrite("/up.bin")
        try writer.write(content)
        try writer.close(attributes: FileAttributes())
        let stored = try Data(contentsOf: box.url("srv/up.bin"))
        #expect(stored == content)
        // Once accepted, the certificate is not asked about again, on any connection.
        #expect(shown.count == 2)
    }

    @Test
    func aServerWithoutTLSRefusesExplicitTLS() throws {
        let fixture = try FTPFixture()
        let key = ServerKey(scheme: "ftps", host: "127.0.0.1", port: fixture.server.port)
        fixture.center.announce(ConnectionProfile(key: key, tls: .explicit, anonymous: true))
        let fileSystem = RemoteFileSystem(scheme: "ftps", center: fixture.center)
        #expect(throws: NetworkError.self) { try fileSystem.list(key.url(), showHidden: true) }
        #expect(fixture.server.commands == ["AUTH TLS"])
    }
}

/// The script below, running as a child process on a port it picks itself.
///
/// What goes wrong on a connection (a handshake the client gave up, among others) is written to
/// `tls-errors.log` in the sandbox, a line each.
final class TLSServer {
    static let python = "/usr/bin/python3"
    static let openssl = "/usr/bin/openssl"
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: python) && FileManager.default.isExecutableFile(atPath: openssl)
    }

    let port: Int
    private let process = Process()

    /// `refusesProtection`: the server answers PROT with an error, as one that cannot encrypt its data connections.
    /// `requiresReuse`: every data connection is refused for not resuming the control connection's TLS session.
    /// `resumesSessions`: false gives no session tickets, so every connection makes a whole handshake and has its
    /// certificate checked.
    init(
        mode: TLSMode,
        box: Sandbox,
        refusesProtection: Bool = false,
        requiresReuse: Bool = false,
        resumesSessions: Bool = true
    ) throws {
        let (certificate, key, script) = (box.url("cert.pem"), box.url("key.pem"), box.url("ftps.py"))
        let make = Process()
        make.executableURL = URL(fileURLWithPath: Self.openssl)
        make.arguments = [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", certificate.path, "-days",
            "2",
            "-subj", "/CN=localhost/O=afm test"
        ]
        (make.standardOutput, make.standardError) = (FileHandle.nullDevice, FileHandle.nullDevice)
        try make.run()
        make.waitUntilExit()
        try Self.script.write(to: script, atomically: true, encoding: .utf8)

        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: Self.python)
        process.arguments =
            [script.path, mode == .implicit ? "implicit" : "explicit", certificate.path, key.path, box.url("srv").path]
            + (refusesProtection ? ["refuse-prot"] : []) + (requiresReuse ? ["require-reuse"] : [])
            + (resumesSessions ? [] : ["no-tickets"])
        process.standardOutput = output
        let errors = box.url("tls-errors.log")
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: errors)
        try process.run()
        // The first line the script prints is its port.
        var line = Data()
        while !line.contains(0x0A), let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            line.append(byte)
        }
        guard let number = Int(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            process.terminate()
            throw POSIXError(.ECONNREFUSED)
        }
        port = number
    }

    func stop() {
        process.terminate()
    }

    static let script = """
        import os, socket, ssl, sys, threading
        mode, cert, key, root = sys.argv[1:5]
        refuse_prot = "refuse-prot" in sys.argv[5:]
        require_reuse = "require-reuse" in sys.argv[5:]
        def make_context():
            made = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            made.load_cert_chain(cert, key)
            return made
        context = make_context()
        def wrap(sock):
            # Without resumption every connection gets a context of its own, whose session cache is empty.
            chosen = make_context() if "no-tickets" in sys.argv[5:] else context
            return chosen.wrap_socket(sock, server_side=True)
        listener = socket.socket()
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(16)
        print(listener.getsockname()[1], flush=True)

        def serve(control):
            protect = False
            passive = None
            try:
                if mode == "implicit":
                    control = wrap(control)
                lines = control.makefile("rb")
                def say(text):
                    control.sendall((text + "\\r\\n").encode())
                def data(work):
                    say("150 Here it comes")
                    channel, _ = passive.accept()
                    if require_reuse:
                        channel.close()
                        say("522 SSL connection failed; session reuse required")
                        return
                    if protect:
                        channel = wrap(channel)
                    work(channel)
                    if protect:
                        try:
                            channel.unwrap()
                        except OSError:
                            pass
                    channel.close()
                    say("226 Done")
                say("220 TLS test server")
                while True:
                    line = lines.readline().decode().rstrip("\\r\\n")
                    if not line:
                        return
                    verb, _, argument = line.partition(" ")
                    verb = verb.upper()
                    if verb == "AUTH":
                        if mode != "explicit":
                            say("502 Not here")
                            continue
                        say("234 Go ahead")
                        control = wrap(control)
                        lines = control.makefile("rb")
                    elif verb == "PBSZ":
                        say("200 OK")
                    elif verb == "PROT":
                        if refuse_prot:
                            say("534 Data protection is not available")
                            continue
                        protect = argument.upper() == "P"
                        say("200 OK")
                    elif verb in ("USER", "OPTS", "TYPE", "NOOP"):
                        say("230 OK" if verb == "USER" else "200 OK")
                    elif verb == "PWD":
                        say('257 "/" is current')
                    elif verb == "CWD":
                        say("250 OK")
                    elif verb == "EPSV":
                        passive = socket.socket()
                        passive.bind(("127.0.0.1", 0))
                        passive.listen(1)
                        say("229 Entering Extended Passive Mode (|||%d|)" % passive.getsockname()[1])
                    elif verb == "LIST":
                        names = sorted(os.listdir(root))
                        text = "".join("-rw-r--r-- 1 o g %d Jan 01 2020 %s\\r\\n" % (os.path.getsize(os.path.join(root, n)), n) for n in names)
                        data(lambda channel: channel.sendall(text.encode()))
                    elif verb == "RETR":
                        with open(os.path.join(root, argument.lstrip("/")), "rb") as source:
                            content = source.read()
                        data(lambda channel: channel.sendall(content))
                    elif verb == "STOR":
                        def receive(channel):
                            with open(os.path.join(root, argument.lstrip("/")), "wb") as target:
                                while True:
                                    block = channel.recv(65536)
                                    if not block:
                                        break
                                    target.write(block)
                        data(receive)
                    elif verb == "QUIT":
                        say("221 Bye")
                        return
                    else:
                        say("502 Not implemented")
            except Exception as error:
                print("error", error, file=sys.stderr, flush=True)
            finally:
                control.close()

        while True:
            client, _ = listener.accept()
            threading.Thread(target=serve, args=(client,), daemon=True).start()
        """
}
