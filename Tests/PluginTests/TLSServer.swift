import Foundation
import TestSupport

@testable import NetworkPlugin

/// The script below, running as a child process on a port it picks itself.
///
/// What goes wrong on a connection (a handshake the client gave up, among others) is written to
/// `tls-errors.log` in the sandbox, a line each.
internal final class TLSServer {
    /// The Python that runs the server script, the one the developer tools put there.
    internal static let python = "/usr/bin/python3"
    /// The tool that makes the self-signed certificate.
    internal static let openssl = "/usr/bin/openssl"
    /// True when both the Python and openssl are there; the TLS suites are skipped otherwise.
    internal static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: python) && FileManager.default.isExecutableFile(atPath: openssl)
    }

    /// The server, an FTP server in Python that speaks TLS (explicit with AUTH TLS, or implicit from the first
    /// byte) and knows just the commands the tests send.
    ///
    /// Arguments: the mode, the certificate, its key, the folder it serves, then any of `refuse-prot`,
    /// `require-reuse` and `no-tickets`.
    internal static let script = """
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
                        sizes = [os.path.getsize(os.path.join(root, n)) for n in names]
                        rows = ["-rw-r--r-- 1 o g %d Jan 01 2020 %s\\r\\n" % entry for entry in zip(sizes, names)]
                        text = "".join(rows)
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

    /// The port the server listens on, on 127.0.0.1.
    internal let port: Int
    /// The Python running the script.
    private let process = Process()

    /// Starts a server that behaves well: it encrypts data connections when asked and resumes TLS sessions.
    internal convenience init(mode: TLSMode, box: Sandbox) throws {
        try self.init(mode: mode, box: box, refusesProtection: false, requiresReuse: false, resumesSessions: true)
    }

    /// Makes a certificate in the sandbox and starts the server with it, serving the sandbox's `srv` folder.
    ///
    /// `refusesProtection`: the server answers PROT with an error, as one that cannot encrypt its data connections.
    /// `requiresReuse`: every data connection is refused for not resuming the control connection's TLS session.
    /// `resumesSessions`: false gives no session tickets, so every connection makes a whole handshake and has its
    /// certificate checked.
    internal init(
        mode: TLSMode,
        box: Sandbox,
        refusesProtection: Bool,
        requiresReuse: Bool,
        resumesSessions: Bool
    ) throws {
        let (certificate, key, scriptFile) = (box.url("cert.pem"), box.url("key.pem"), box.url("ftps.py"))
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
        try Self.script.write(to: scriptFile, atomically: true, encoding: .utf8)

        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: Self.python)
        process.arguments =
            [
                scriptFile.path, mode == .implicit ? "implicit" : "explicit", certificate.path, key.path,
                box.url("srv").path
            ]
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
        guard let text = String(bytes: line, encoding: .utf8),
            let number = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            process.terminate()
            throw POSIXError(.ECONNREFUSED)
        }
        port = number
    }

    /// Ends the server process.
    internal func stop() {
        process.terminate()
    }

    deinit {
        // Nothing to release: the tests stop the server themselves.
    }
}
