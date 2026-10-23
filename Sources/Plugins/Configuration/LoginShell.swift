import Foundation

/// The shell that runs command lines.
///
/// Always a POSIX shell, whatever the user's login shell is: the lines of user commands are written
/// for one, a reference to a value is written the way such a shell reads it, and `csh` and `tcsh`
/// do not even take the options.
internal enum LoginShell {
    /// `/bin/zsh` as a login shell, so that a command finds the PATH of a terminal.
    ///
    /// Every macOS the program runs on has it.
    internal static let posix = (executable: "/bin/zsh", options: ["-l", "-c"])

    /// The shell of this user's account in the user database.
    internal static var accountShell: String? {
        getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) }
    }

    /// The PATH of the user's login shell when that is another shell than zsh (bash, fish,
    /// tcsh …), asked for once.
    ///
    /// Starts a process and waits up to a few seconds for it: never for the main thread.
    internal static let foreignPath = foreignPath(
        of: usersShell(environment: ProcessInfo.processInfo.environment, account: accountShell),
        waiting: .seconds(3)
    )

    /// The shell the user logs in with: `SHELL`, else the shell of the user's `account`, else zsh.
    internal static func usersShell(environment: [String: String], account: String?) -> String {
        if let path = environment["SHELL"], !path.isEmpty {
            return path
        }
        if let path = account, !path.isEmpty {
            return path
        }
        return "/bin/zsh"
    }

    /// The PATH that `shell` sets up: its start files are not read by zsh, so the PATH they set
    /// up is asked for and handed on.
    ///
    /// Nil for zsh and when the shell does not answer within `waiting`. Starts a process and waits
    /// for it: never for the main thread.
    internal static func foreignPath(of shell: String, waiting: DispatchTimeInterval) -> String? {
        guard URL(fileURLWithPath: shell).lastPathComponent != "zsh",
            FileManager.default.isExecutableFile(atPath: shell)
        else { return nil }
        // `csh` and `tcsh` take `-c` but not `-l` with it.
        return path(from: shell, ["-l", "-c", "printenv PATH"], waiting)
            ?? path(from: shell, ["-c", "printenv PATH"], waiting)
    }

    private static func path(from shell: String, _ arguments: [String], _ waiting: DispatchTimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        guard (try? process.run()) != nil else {
            // Foundation does not let go of the handler of a process that did not start.
            process.terminationHandler = nil
            return nil
        }
        guard ended.wait(timeout: .now() + waiting) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = pipe.fileHandleForReading.availableData
        // Start files may print lines of their own: the PATH is the last one.
        let lines = String(bytes: data, encoding: .utf8)?.split(whereSeparator: \.isNewline)
        let line = lines?.last.map(String.init) ?? ""
        return line.hasPrefix("/") && line.utf8.count < 16_384 ? line : nil
    }

    /// The environment a command line runs in: this program's, with the PATH of a login shell
    /// that is not zsh.
    internal static func environment(foreignPath: String?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let path = foreignPath { environment["PATH"] = path }
        return environment
    }
}
