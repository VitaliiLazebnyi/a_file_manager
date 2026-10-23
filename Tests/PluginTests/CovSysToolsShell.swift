import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import SystemToolsPlugin

/// The shell the command lines run in, the PATH it is asked for, the child processes and the texts of the system.
@Suite
internal struct CovSysToolsShell {
    private let box: Sandbox

    /// A sandbox for the shell scripts; throws when the disk refuses.
    internal init() throws {
        box = try Sandbox()
    }

    /// `SHELL` names the user's shell; without it the account's is taken, and without that zsh.
    @Test
    internal func theUsersShellComesFromTheEnvironmentThenTheAccount() {
        #expect(LoginShell.usersShell(environment: ["SHELL": "/bin/bash"], account: "/bin/tcsh") == "/bin/bash")
        #expect(LoginShell.usersShell(environment: ["SHELL": ""], account: "/bin/tcsh") == "/bin/tcsh")
        #expect(LoginShell.usersShell(environment: [:], account: nil) == "/bin/zsh")
        #expect(LoginShell.usersShell(environment: [:], account: "") == "/bin/zsh")
        #expect(LoginShell.accountShell()?.hasPrefix("/") == true)
    }

    /// Only a shell other than zsh is asked for its PATH, first as a login shell, then without.
    @Test
    internal func anotherShellIsAskedForItsPath() throws {
        #expect(LoginShell.foreignPath(of: "/bin/zsh") == nil)
        #expect(LoginShell.foreignPath(of: box.url("none").path) == nil)
        let login = try script("login", "echo first line; echo /from/login")
        #expect(LoginShell.foreignPath(of: login) == "/from/login")
        // `csh` does not take `-l` with `-c`.
        let plain = try script("plain", "if [ \"$1\" = \"-l\" ]; then exit 1; fi\necho /from/plain")
        #expect(LoginShell.foreignPath(of: plain) == "/from/plain")
        // The program's own PATH is that of the user's login shell, asked for once.
        let shell = LoginShell.usersShell(
            environment: ProcessInfo.processInfo.environment,
            account: LoginShell.accountShell()
        )
        #expect(LoginShell.foreignPath == LoginShell.foreignPath(of: shell))
        #expect(LoginShell.searchPath.hasPrefix("/"))
    }

    /// The PATH of a terminal: the other shell's, else the one the POSIX shell tells, else this process's.
    @Test
    internal func theSearchPathFallsBackInTurn() throws {
        let answering = try script("answering", "echo /from/posix")
        #expect(LoginShell.searchPath(foreign: "/foreign", shell: (answering, []), own: "/own") == "/foreign")
        #expect(LoginShell.searchPath(foreign: nil, shell: (answering, []), own: "/own") == "/from/posix")
        #expect(LoginShell.searchPath(foreign: nil, shell: (box.url("none").path, []), own: "/own") == "/own")
    }

    /// A shell that cannot start, does not answer in time, fails or prints no path gives no PATH.
    @Test
    internal func aShellThatDoesNotAnswerGivesNoPath() throws {
        #expect(LoginShell.path(from: box.url("none").path, [], waiting: 5) == nil)
        #expect(LoginShell.path(from: try script("slow", "exec sleep 30"), [], waiting: 0.05) == nil)
        #expect(LoginShell.path(from: try script("failing", "echo /bin; exit 1"), [], waiting: 5) == nil)
        #expect(LoginShell.path(from: try script("silent", ":"), [], waiting: 5) == nil)
        #expect(LoginShell.path(from: try script("relative", "echo bin"), [], waiting: 5) == nil)
        #expect(LoginShell.path(from: try script("long", "printf '/%020000d\\n' 0"), [], waiting: 5) == nil)
    }

    /// The environment of a line has the PATH of the login shell when there is one.
    @Test
    internal func theEnvironmentTakesThePathWhenThereIsOne() {
        let base = ["PATH": "/usr/bin", "HOME": "/Users/x"]
        #expect(LoginShell.environment(base, path: nil) == base)
        #expect(LoginShell.environment(base, path: "/opt/bin") == ["PATH": "/opt/bin", "HOME": "/Users/x"])
        #expect(TypedCommand.path(in: [:]) == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(TypedCommand.path(in: ["PATH": "/x"]) == "/x")
    }

    /// The system's desktop answers the questions that change nothing: what may run, the PATH, the environment, the
    /// applications.
    ///
    /// (What it does on the desktop is left to the UI tests.).
    @Test
    internal func theSystemsDesktopAnswersQuestions() throws {
        let system = ToolsDesktop.system
        #expect(system.mayRun(try #require(TypedCommand("make"))))
        #expect(system.searchPath() == LoginShell.searchPath && system.environment()["PATH"] != nil)
        #expect(system.applicationWithIdentifier("com.apple.Terminal")?.lastPathComponent == "Terminal.app")
        let text = try box.file("note.txt", "x")
        #expect(!system.applicationsToOpen(text).all.isEmpty)
        #expect(system.shell.executable.path == "/bin/zsh" && system.printer.path == "/usr/bin/lpr")
    }

    /// A child gets the environment it is given, and output that is not UTF-8 is still read.
    @Test
    internal func aChildRunsInItsEnvironmentAndAnyOutputIsRead() {
        var runner = ProcessRunner(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf %s \"$AFM_COVERAGE\""],
            directory: nil
        )
        runner.environment = ["AFM_COVERAGE": "given"]
        #expect(runner.run(cancellation: CancellationFlag(), progress: nil).output == "given")
        let bytes = ProcessRunner(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'a\\377b'"],
            directory: nil
        )
        #expect(bytes.run(cancellation: CancellationFlag(), progress: nil).output == "a\u{FFFD}b")
    }

    /// Line breaks, tabs and format characters are written out; the joiners of emoji stay; a long text is cut.
    @Test
    internal func textFromOutsideStaysOnOneLine() {
        #expect(DisplayText.oneLine("a\rb\tc", limit: 200) == "a\\rb\\tc")
        #expect(DisplayText.oneLine("x\u{200D}y\u{200C}z", limit: 200) == "x\u{200D}y\u{200C}z")
        #expect(DisplayText.oneLine("x\u{200B}y", limit: 200) == "x\\u{200B}y")
        #expect(DisplayText.oneLine("abcdef", limit: 3) == "abc…")
    }

    /// A C string of the system ends at its first zero, or with its buffer; owners of questions are told apart.
    @Test
    internal func aSystemStringEndsAtItsZero() {
        #expect(SystemText.string([65, 66, 0, 67]) == "AB")
        #expect(SystemText.string([65, 66, 67]) == "ABC")
        let (one, other) = (CallOwner(), CallOwner())
        #expect(one !== other)
    }

    /// A shell script of the sandbox that does `body`.
    private func script(_ name: String, _ body: String) throws -> String {
        let file = try box.file(name, "#!/bin/sh\n" + body + "\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }
}
