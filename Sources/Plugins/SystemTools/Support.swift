import Foundation

// The same as in the Configuration plugin: plugins share no code but the kernel's.

/// The shell that runs command lines. Always a POSIX shell, whatever the user's login shell
/// is: the lines of user commands are written for one, a reference to a value is written the
/// way such a shell reads it, and `csh` and `tcsh` do not even take the options.
enum LoginShell {
    /// `/bin/zsh` as a login shell, so that a command finds the PATH of a terminal; `/bin/sh`
    /// where there is no zsh.
    static let posix: (executable: String, options: [String]) =
        FileManager.default.isExecutableFile(atPath: "/bin/zsh") ? ("/bin/zsh", ["-l", "-c"]) : ("/bin/sh", ["-c"])

    /// The shell the user logs in with.
    static var usersShell: String {
        var path = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        if path.isEmpty, let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell { path = String(cString: shell) }
        return path.isEmpty ? "/bin/zsh" : path
    }

    /// The PATH of the user's login shell when that is another shell than zsh (bash, fish,
    /// tcsh …): its start files are not read by zsh, so the PATH they set up is asked for once
    /// and handed on. Nil for zsh and when the shell does not answer. Starts a process and
    /// waits up to a few seconds for it: never for the main thread.
    static let foreignPath: String? = {
        let shell = usersShell
        guard URL(fileURLWithPath: shell).lastPathComponent != "zsh", FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        // `csh` and `tcsh` take `-c` but not `-l` with it.
        return path(from: shell, ["-l", "-c", "printenv PATH"]) ?? path(from: shell, ["-c", "printenv PATH"])
    }()

    fileprivate static func path(from shell: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        guard (try? process.run()) != nil else { return nil }
        guard ended.wait(timeout: .now() + 3) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.availableData
        // Start files may print lines of their own: the PATH is the last one.
        let line = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return line.hasPrefix("/") && line.utf8.count < 16_384 ? line : nil
    }

    /// The environment a command line runs in.
    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let path = foreignPath { environment["PATH"] = path }
        return environment
    }
}

extension LoginShell {
    /// The PATH a terminal would have: that of the user's login shell, asked for once; the
    /// PATH of this process when the shell does not answer. Starts a process and waits up to a
    /// few seconds for it the first time: never for the main thread.
    static let searchPath: String = {
        let own = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if let foreign = foreignPath { return foreign }
        return path(from: posix.executable, posix.options + ["printenv PATH"]) ?? own
    }()
}

/// Text that came from outside (a file name, a path, a stored value) made fit for a message, a
/// log line or a dialog: line breaks and control characters cannot draw a second line or hide
/// what follows, and a very long text is cut.
enum DisplayText {
    static func oneLine(_ text: String, limit: Int = 200) -> String {
        var result = String.UnicodeScalarView()
        var count = 0
        for scalar in text.unicodeScalars {
            if count >= limit {
                result.append("…")
                break
            }
            count += 1
            switch scalar {
            case "\n": result.append(contentsOf: "\\n".unicodeScalars)
            case "\r": result.append(contentsOf: "\\r".unicodeScalars)
            case "\t": result.append(contentsOf: "\\t".unicodeScalars)
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
