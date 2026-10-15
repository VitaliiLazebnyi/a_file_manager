import Foundation
import TestSupport

@testable import NetworkPlugin

/// A child process for `SFTPChannel` that greets like an SFTP server and then plays one scene, written in the Python
/// that comes with the developer tools.
internal enum CovNetRawSFTP {
    /// What the process does.
    internal enum Scene: String {
        /// Says a lot on its error output before it greets, then reads until its input ends.
        case chatty = "chatty"
        /// Greets, says its `HOME` on its error output and reads until its input ends.
        case home = "home"
        /// Greets, closes its output, and a second later says a lot on its error output and ends.
        case lastWords = "lastwords"
        /// Is not ended by `SIGTERM`; greets, and when its input ends it sends one more packet and writes the file
        /// `lingered` next to the script.
        case lingering = "lingering"
        /// Greets, reads the first five bytes of the next packet, says `stuck` on its error output and reads no more.
        case stuck = "stuck"
        /// Greets, then takes in 4 KB every 20 ms; says `taking` on its error output after the first.
        case trickle = "trickle"
    }

    /// The script.
    private static let script = """
        import os, signal, struct, sys, time
        scene = sys.argv[1]
        if scene == "lingering":
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        def read_exactly(count):
            data = b""
            while len(data) < count:
                chunk = os.read(0, count - len(data))
                if not chunk:
                    sys.exit(0)
                data += chunk
            return data
        def say_a_lot():
            for index in range(400):
                os.write(2, ("line %d of what the server says to nobody in particular\\n" % index).encode())
            os.write(2, b"the last word\\n")
        if scene == "chatty":
            say_a_lot()
        read_exactly(9)
        os.write(1, struct.pack(">IBI", 5, 2, 3))
        if scene == "stuck":
            read_exactly(5)
            os.write(2, b"stuck\\n")
            time.sleep(600)
        elif scene == "trickle":
            os.read(0, 4096)
            os.write(2, b"taking\\n")
            while os.read(0, 4096):
                time.sleep(0.02)
        elif scene == "lastwords":
            os.close(1)
            time.sleep(1)
            say_a_lot()
            sys.exit(0)
        elif scene == "home":
            os.write(2, (os.environ.get("HOME", "") + "\\n").encode())
        while os.read(0, 65536):
            pass
        if scene == "lingering":
            os.write(1, struct.pack(">IBII", 9, 101, 1, 0))
            open(os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "lingered"), "w").close()
        """

    /// A channel that runs `scene`, with `environment` and `writeTimeout`; the script is written into `box`.
    internal static func channel(
        _ scene: Scene,
        in box: Sandbox,
        environment: [String: String],
        writeTimeout: TimeInterval
    ) throws -> SFTPChannel {
        let url = box.url("raw-sftp.py")
        try script.write(to: url, atomically: true, encoding: .utf8)
        return SFTPChannel(
            executable: FakeSFTPServer.python,
            arguments: [url.path, scene.rawValue],
            environment: environment,
            writeTimeout: writeTimeout
        )
    }

    /// A channel that runs `scene` with nothing added to its environment and a minute for a write.
    internal static func channel(_ scene: Scene, in box: Sandbox) throws -> SFTPChannel {
        try channel(scene, in: box, environment: [:], writeTimeout: 60)
    }
}
