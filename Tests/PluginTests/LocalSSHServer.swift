import Foundation
import TestSupport

/// `/usr/sbin/sshd` as a child process of the test, on a free port of 127.0.0.1, with a host
/// key, a user key and an `authorized_keys` file that exist only in the sandbox.
internal final class LocalSSHServer {
    /// The SFTP server that comes with macOS, which `sshd` runs for the sftp subsystem.
    internal static let systemSFTPServer = "/usr/libexec/sftp-server"

    /// True when the server, the client, the key tool and the SFTP server are all there.
    internal static var isAvailable: Bool {
        ["/usr/sbin/sshd", "/usr/bin/ssh", "/usr/bin/ssh-keygen", systemSFTPServer]
            .allSatisfy(
                FileManager.default.isExecutableFile
            )
    }

    /// The port the server listens on.
    internal let port: Int
    /// The arguments for `/usr/bin/ssh` that log in to this server with the sandbox's key and known hosts, and
    /// start the sftp subsystem.
    internal let clientArguments: [String]
    /// The running `sshd`.
    private let process = Process()

    /// Makes the keys and the configuration in the sandbox, starts the server and waits until it listens.
    ///
    /// `passphrase` protects the user key; `banner`, when not nil, is a text the server shows before the login, as
    /// any server may.
    internal init(box: Sandbox, passphrase: String, banner: String?) throws {
        let folder = try box.folder("ssh")
        let (hostKey, userKey) = (
            folder.appendingPathComponent("host").path, folder.appendingPathComponent("user").path
        )
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", hostKey])
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", passphrase, "-f", userKey])
        let authorized = folder.appendingPathComponent("authorized_keys")
        try FileManager.default.copyItem(atPath: userKey + ".pub", toPath: authorized.path)

        // A port that is free right now.
        let probe = try TestFTPServer(root: folder, options: TestFTPServer.Options())
        port = probe.port
        probe.stop()
        let config = try Self.writeConfiguration(
            in: folder,
            port: port,
            hostKey: hostKey,
            authorized: authorized,
            banner: banner
        )
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        process.arguments = ["-D", "-e", "-f", config.path]
        (process.standardOutput, process.standardError) = (FileHandle.nullDevice, FileHandle.nullDevice)
        try process.run()
        clientArguments = [
            "-F", "/dev/null", "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none", "-o",
            "NumberOfPasswordPrompts=1",
            "-o", "UserKnownHostsFile=\(folder.appendingPathComponent("known_hosts").path)", "-o",
            "GlobalKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=ask", "-o", "ConnectionAttempts=20", "-i", userKey, "-p", String(port),
            "-s", "--", "127.0.0.1", "sftp"
        ]
        Self.waitUntilListening(on: port)
    }

    /// Runs a tool to its end, its output thrown away.
    private static func run(_ tool: String, _ arguments: [String]) throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: tool)
        child.arguments = arguments
        (child.standardOutput, child.standardError) = (FileHandle.nullDevice, FileHandle.nullDevice)
        try child.run()
        child.waitUntilExit()
    }

    /// Writes `sshd_config` (and the banner, if any) into the folder and returns the configuration's location.
    ///
    /// The server takes keys only, no PAM, the sandbox's `authorized_keys`, and runs the system's SFTP server.
    private static func writeConfiguration(
        in folder: URL,
        port: Int,
        hostKey: String,
        authorized: URL,
        banner: String?
    ) throws -> URL {
        let config = folder.appendingPathComponent("sshd_config")
        let bannerFile = folder.appendingPathComponent("banner")
        if let banner {
            try banner.write(to: bannerFile, atomically: true, encoding: .utf8)
        }
        try """
        \(banner == nil ? "" : "Banner \(bannerFile.path)")
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKey)
        PidFile \(folder.appendingPathComponent("sshd.pid").path)
        AuthorizedKeysFile \(authorized.path)
        StrictModes no
        UsePAM no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        Subsystem sftp \(systemSFTPServer)

        """
        .write(to: config, atomically: true, encoding: .utf8)
        return config
    }

    /// Tries to connect to the port on 127.0.0.1 until it works, for five seconds at most.
    private static func waitUntilListening(on port: Int) {
        for _ in 0..<100 {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            close(descriptor)
            if result == 0 {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// Ends the server process.
    internal func stop() {
        process.terminate()
    }

    deinit {
        // Nothing to release: the tests stop the server themselves.
    }
}
