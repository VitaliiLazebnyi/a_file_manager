import Foundation
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// Which shell runs command lines, and the PATH a login shell other than zsh sets up.
@Suite internal struct CovConfigLoginShell {
    private let box: Sandbox

    internal init() throws {
        box = try Sandbox()
    }

    /// Writes an executable script that stands for a login shell.
    private func shell(_ name: String, _ body: String) throws -> String {
        let url = try box.file("shells/\(name)", "#!/bin/sh\n" + body + "\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// Command lines always run in zsh as a login shell.
    @Test
    internal func commandLinesRunInZshAsALoginShell() {
        #expect(LoginShell.posix.executable == "/bin/zsh" && LoginShell.posix.options == ["-l", "-c"])
    }

    /// `SHELL` names the user's shell; without it the account's shell counts, and without that zsh.
    @Test
    internal func theUsersShellComesFromTheEnvironmentTheAccountOrZsh() {
        #expect(LoginShell.usersShell(environment: ["SHELL": "/bin/bash"], account: "/bin/tcsh") == "/bin/bash")
        #expect(LoginShell.usersShell(environment: ["SHELL": ""], account: "/bin/tcsh") == "/bin/tcsh")
        #expect(LoginShell.usersShell(environment: [:], account: "") == "/bin/zsh")
        #expect(LoginShell.usersShell(environment: [:], account: nil) == "/bin/zsh")
        // The account of the user running the tests has a shell.
        #expect(LoginShell.accountShell?.hasPrefix("/") == true)
    }

    /// zsh, and a shell that is not there or cannot run, set up no PATH of their own.
    @Test
    internal func zshAndMissingShellsGiveNoPath() throws {
        #expect(LoginShell.foreignPath(of: "/bin/zsh") == nil)
        #expect(LoginShell.foreignPath(of: box.url("shells/none").path) == nil)
        let plain = try box.file("shells/plain", "not a program")
        #expect(LoginShell.foreignPath(of: plain.path) == nil)
        // An executable whose interpreter is missing does not start.
        let broken = try box.file("shells/broken", "#!/nonexistent/afm-interpreter\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken.path)
        #expect(LoginShell.foreignPath(of: broken.path) == nil)
    }

    /// The PATH is the last line the shell prints; start files may print lines before it.
    @Test
    internal func thePathIsTheLastLineTheShellPrints() throws {
        let talkative = try shell("bash", "echo 'Welcome'\necho '/opt/tools/bin:/usr/bin'")
        #expect(LoginShell.foreignPath(of: talkative, waiting: .seconds(60)) == "/opt/tools/bin:/usr/bin")
    }

    /// A shell that does not take `-l` with `-c` (csh, tcsh) is asked again without it.
    @Test
    internal func aShellWithoutLoginOptionIsAskedAgainWithoutIt() throws {
        let csh = try shell("tcsh", "[ \"$1\" = -l ] && exit 1\necho /usr/local/bin:/bin")
        #expect(LoginShell.foreignPath(of: csh, waiting: .seconds(60)) == "/usr/local/bin:/bin")
    }

    /// An answer that is not a path, too long, empty, or a shell that fails gives no PATH.
    @Test
    internal func answersThatAreNoPathAreIgnored() throws {
        #expect(LoginShell.foreignPath(of: try shell("relative", "echo bin:usr/bin"), waiting: .seconds(60)) == nil)
        #expect(LoginShell.foreignPath(of: try shell("silent", "exit 0"), waiting: .seconds(60)) == nil)
        #expect(LoginShell.foreignPath(of: try shell("failing", "exit 3"), waiting: .seconds(60)) == nil)
        let long = "/" + String(repeating: "a", count: 16_384)
        #expect(LoginShell.foreignPath(of: try shell("long", "echo \(long)"), waiting: .seconds(60)) == nil)
    }

    /// A shell that does not answer in time is ended and gives no PATH.
    @Test
    internal func aShellThatDoesNotAnswerIsEnded() throws {
        let stuck = try shell("stuck", "exec /bin/sleep 600")
        #expect(LoginShell.foreignPath(of: stuck, waiting: .milliseconds(50)) == nil)
    }

    /// Command lines get this program's environment, with the PATH of a foreign login shell when there is one.
    @Test
    internal func theEnvironmentTakesTheForeignPath() {
        let own = ProcessInfo.processInfo.environment
        #expect(LoginShell.environment(foreignPath: "/x/bin")["PATH"] == "/x/bin")
        #expect(LoginShell.environment(foreignPath: nil) == own)
        #expect(LoginShell.environment()["HOME"] == own["HOME"])
    }
}
