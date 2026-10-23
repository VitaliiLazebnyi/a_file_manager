import Foundation

/// How the session talks to `ssh`: the program and arguments it starts, and which of its questions
/// the stored password answers.
extension SFTPSession {
    /// The arguments for `ssh` that open the SFTP subsystem on the profile's server.
    internal static func sshArguments(for profile: ConnectionProfile, options: NetworkOptions.Values) -> [String] {
        // ssh notices a dead connection by its own probes, also when the user wants no
        // keep-alive of ours: without them it would never end on a line that swallows everything.
        let probe = options.keepAliveInterval > 0 ? Int(options.keepAliveInterval) : max(15, Int(options.timeout))
        var arguments = [
            "-o", "ConnectTimeout=\(Int(options.timeout))", "-o", "NumberOfPasswordPrompts=1", "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes",
            // Nothing but the file transfer: no command, no terminal, and not through (or as)
            // a shared connection of the user's, which ending this one would take down.
            "-o", "RemoteCommand=none", "-o", "PermitLocalCommand=no", "-o", "ControlMaster=no", "-o",
            "ControlPath=none",
            "-o", "RequestTTY=no",
            // Errors only: the server's banner is not among them, so it cannot pass for one.
            "-o", "LogLevel=ERROR",
            "-o", "ServerAliveInterval=\(probe)", "-o", "ServerAliveCountMax=3", "-p", String(profile.key.port)
        ]
        if let user = profile.user, !user.isEmpty { arguments += ["-l", user] }
        // After `--` nothing is taken for an option, whatever the host is called.
        return arguments + ["-T", "-s", "--", profile.key.host, "sftp"]
    }

    /// Whether a question of ssh is the request for the password of this profile's login.
    ///
    /// ssh asks `user@host's password:` (or `(user@host) Password:` for keyboard-interactive logins),
    /// and every `ssh` that runs on behalf of this connection asks through the same helper: a
    /// jump host (`ProxyJump`) would be given the password of the target server if the first
    /// request for a password were answered whoever it comes from.
    ///
    /// A question that names another login or host is passed on to the user, and so is one that
    /// names none: who asks it cannot be told.
    internal static func asksForPassword(_ question: String, of profile: ConnectionProfile) -> Bool {
        let (user, host): (String, String)
        switch SSHQuestion(question) {
        case .password(let asked, let server):
            (user, host) = (asked, server)

        case .server(let asked, let server, let text):
            let lowered = text.lowercased()
            guard lowered.contains("password"), !lowered.contains("passphrase") else {
                return false
            }
            (user, host) = (asked, server)

        case .passphrase, .hostKey, .other:
            return false
        }
        if let own = profile.user, !own.isEmpty, own != user {
            return false
        }
        return host == ServerKey.bare(profile.key.host).lowercased()
    }

    /// The channel for a login, not started yet, and the helper that asks the questions of ssh.
    ///
    /// The transport's program when there is one, else `/usr/bin/ssh` with `sshArguments`.
    internal func makeChannel(for profile: ConnectionProfile, options: NetworkOptions.Values) throws -> (
        channel: SFTPChannel, askpass: AskpassHelper?
    ) {
        if let transport {
            let askpass = transport.asksQuestions ? try AskpassHelper(in: FileManager.default.temporaryDirectory) : nil
            let created = SFTPChannel(
                executable: transport.executable,
                arguments: transport.arguments,
                environment: askpass?.environment ?? [:],
                writeTimeout: max(10, options.timeout),
                names: names
            )
            return (created, askpass)
        }
        guard profile.user?.hasPrefix("-") != true else {
            throw NetworkError.loginFailed("The user name is not valid.")
        }
        let helper = try AskpassHelper(in: FileManager.default.temporaryDirectory)
        let created = SFTPChannel(
            executable: "/usr/bin/ssh",
            arguments: Self.sshArguments(for: profile, options: options),
            environment: helper.environment,
            writeTimeout: max(10, options.timeout),
            names: names
        )
        return (created, helper)
    }
}
