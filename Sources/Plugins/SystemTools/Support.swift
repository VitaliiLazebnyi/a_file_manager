import Foundation

// The same as in the Configuration plugin: plugins share no code but the kernel's.

/// The shell that runs command lines. Always a POSIX shell, whatever the user's login shell
/// is: the lines of user commands are written for one, a reference to a value is written the
/// way such a shell reads it, and `csh` and `tcsh` do not even take the options.
internal enum LoginShell {
    /// `/bin/zsh` as a login shell, so that a command finds the PATH of a terminal. Every macOS
    /// the program runs on has it.
    internal static let posix: (executable: String, options: [String]) = ("/bin/zsh", ["-l", "-c"])

    /// The PATH of the user's login shell when that is another shell than zsh, asked for once
    /// (`foreignPath(of:)`). Starts a process the first time: never for the main thread.
    internal static let foreignPath: String? = foreignPath(
        of: usersShell(environment: ProcessInfo.processInfo.environment, account: accountShell())
    )

    /// The PATH a terminal would have: that of the user's login shell, asked for once; the
    /// PATH of this process when the shell does not answer. Starts a process and waits up to a
    /// few seconds for it the first time: never for the main thread.
    internal static let searchPath: String = searchPath(
        foreign: foreignPath,
        shell: posix,
        own: TypedCommand.processPath
    )

    /// How long a shell may take to tell its PATH, in seconds.
    internal static let answerTime: TimeInterval = 3

    /// The shell the user logs in with: `SHELL` of `environment`, else that of the account, else zsh.
    internal static func usersShell(environment: [String: String], account: String?) -> String {
        let path = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? account ?? ""
        return path.isEmpty ? "/bin/zsh" : path
    }

    /// The login shell of this user's account in the user database.
    internal static func accountShell() -> String? {
        getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) }
    }

    /// The PATH of `shell` when that is another shell than zsh (bash, fish, tcsh …): its start
    /// files are not read by zsh, so the PATH they set up is asked for and handed on. Nil for
    /// zsh and when the shell does not answer. Starts a process and waits up to a few seconds
    /// for it: never for the main thread.
    internal static func foreignPath(of shell: String) -> String? {
        guard URL(fileURLWithPath: shell).lastPathComponent != "zsh",
            FileManager.default.isExecutableFile(atPath: shell)
        else {
            return nil
        }
        // `csh` and `tcsh` take `-c` but not `-l` with it.
        return path(from: shell, ["-l", "-c", "printenv PATH"], waiting: answerTime)
            ?? path(from: shell, ["-c", "printenv PATH"], waiting: answerTime)
    }

    /// `foreign` when there is one, else what `shell` says the PATH is, else `own`.
    internal static func searchPath(
        foreign: String?,
        shell: (executable: String, options: [String]),
        own: String
    ) -> String {
        foreign ?? path(from: shell.executable, shell.options + ["printenv PATH"], waiting: answerTime) ?? own
    }

    /// The PATH `shell` prints when started with `arguments`; nil when it cannot start, takes
    /// longer than `waiting` seconds, fails or prints no path.
    internal static func path(from shell: String, _ arguments: [String], waiting: TimeInterval) -> String? {
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
        let line = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last ?? ""
        return line.hasPrefix("/") && line.utf8.count < 16_384 ? String(line) : nil
    }

    /// `base` with `path` as its PATH, when there is one.
    internal static func environment(_ base: [String: String], path: String?) -> [String: String] {
        var environment = base
        if let path {
            environment["PATH"] = path
        }
        return environment
    }
}

/// Text of the system: a C string in a buffer.
internal enum SystemText {
    /// The characters before the first zero, read as UTF-8; all of them when there is no zero.
    internal static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Text that came from outside (a file name, a path, a stored value) made fit for a message, a
/// log line or a dialog: line breaks and control characters cannot draw a second line or hide
/// what follows, and a very long text is cut.
internal enum DisplayText {
    /// `text` on one line, cut after `limit` characters.
    internal static func oneLine(_ text: String, limit: Int = 200) -> String {
        var result = String.UnicodeScalarView()
        var count = 0
        for scalar in text.unicodeScalars {
            if count >= limit {
                result.append("…")
                break
            }
            count += 1
            switch scalar {
            case "\n":
                result.append(contentsOf: "\\n".unicodeScalars)

            case "\r":
                result.append(contentsOf: "\\r".unicodeScalars)

            case "\t":
                result.append(contentsOf: "\\t".unicodeScalars)

            default:
                switch scalar.properties.generalCategory {
                // The joiners of emoji and of some scripts are format characters too, and harmless.
                case .format where scalar.value == 0x200C || scalar.value == 0x200D:
                    result.append(scalar)

                case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate:
                    result.append(contentsOf: "\\u{\(String(scalar.value, radix: 16, uppercase: true))}".unicodeScalars)

                default:
                    result.append(scalar)
                }
            }
        }
        return String(result)
    }
}

/// Stands for what questions are asked of in `BlockingCalls`, which counts them by their owner:
/// only its identity is used.
internal final class CallOwner: Sendable {
    deinit {
        // Nothing to release.
    }
}
