/// The program that carries the SFTP dialogue instead of `/usr/bin/ssh`: tests run the
/// system's own `sftp-server` on a sandbox folder this way, without a network or a login.
public struct SFTPTransport: Sendable {
    /// The path of the program.
    public var executable: String
    /// The arguments the program is started with.
    public var arguments: [String]
    /// True when the program is an `ssh` that may have questions, which are then answered
    /// through `SSH_ASKPASS` like those of the real connection.
    public var asksQuestions: Bool

    /// A transport that runs `executable` with `arguments`; it asks no questions unless said so.
    public init(executable: String, arguments: [String] = [], asksQuestions: Bool = false) {
        self.executable = executable
        self.arguments = arguments
        self.asksQuestions = asksQuestions
    }
}
