import Foundation

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
        if path.isEmpty, let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            path = String(cString: shell)
        }
        return path.isEmpty ? "/bin/zsh" : path
    }

    /// The PATH of the user's login shell when that is another shell than zsh (bash, fish,
    /// tcsh …): its start files are not read by zsh, so the PATH they set up is asked for once
    /// and handed on. Nil for zsh and when the shell does not answer. Starts a process and
    /// waits up to a few seconds for it: never for the main thread.
    static let foreignPath: String? = {
        let shell = usersShell
        guard URL(fileURLWithPath: shell).lastPathComponent != "zsh",
            FileManager.default.isExecutableFile(atPath: shell)
        else { return nil }
        // `csh` and `tcsh` take `-c` but not `-l` with it.
        return path(from: shell, ["-l", "-c", "printenv PATH"]) ?? path(from: shell, ["-c", "printenv PATH"])
    }()

    private static func path(from shell: String, _ arguments: [String]) -> String? {
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

/// A program started on its own, with its arguments handed over byte for byte. (Foundation's
/// `Process` rewrites every argument in decomposed form, so a name with an accent would arrive
/// as another name on a volume that tells the two forms apart.) Its end is reported through a
/// dispatch source: no thread waits for it.
enum ChildProcess {
    struct Failure: Error {
        let code: Int32
        var message: String {
            code == E2BIG
                ? "The command line is too long. Pass many names through a list file (%L) instead."
                : String(cString: strerror(code))
        }
    }

    /// Starts `executable` in `directory`, with nothing to read and its output discarded.
    /// Returns the process number. Blocks for the time the start takes: not for the main thread.
    static func spawn(executable: String, arguments: [String], environment: [String: String], directory: String)
        -> Result<pid_t, Failure>
    {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return .failure(Failure(code: errno)) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return .failure(Failure(code: errno)) }
        defer { posix_spawnattr_destroy(&attributes) }

        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        // The child gets none of this program's open files, and signals as a new program has them.
        var all = sigset_t()
        var none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp)
        return result == 0 ? .success(pid) : .failure(Failure(code: result))
    }

    /// How a child ended.
    struct Ending {
        /// The exit status; nil when a signal ended it.
        let status: Int32?
    }

    /// Reports the end of a child once, on a queue of the system. Lives in a `ChildTable`.
    /// `reported` is guarded by `lock`; nothing else changes after `init`.
    final class Watch: @unchecked Sendable {
        private let pid: pid_t
        private let handler: @Sendable (Ending) -> Void
        private let source: any DispatchSourceProcess
        private let lock = NSLock()
        private var reported = false

        init(pid: pid_t, handler: @escaping @Sendable (Ending) -> Void) {
            self.pid = pid
            self.handler = handler
            source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        }

        func start() {
            source.setEventHandler { [self] in reap(waiting: true) }
            source.resume()
            // A child that ended before the source was there is collected here.
            reap(waiting: false)
        }

        private func reap(waiting: Bool) {
            lock.lock()
            if reported {
                lock.unlock()
                return
            }
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, waiting ? 0 : WNOHANG) } while result == -1 && errno == EINTR
            guard result == pid || (result == -1 && waiting) else {
                lock.unlock()
                return
            }
            reported = true
            lock.unlock()
            source.cancel()
            // The macros of <sys/wait.h>: the low seven bits are the signal, the next byte the status.
            let signalled = result == pid && status & 0x7F != 0
            handler(Ending(status: result == pid && !signalled ? (status >> 8) & 0xFF : nil))
        }
    }
}

/// The children that are running, so that a watch lives as long as its child and a waiting
/// chain can be stopped. Used from the thread that starts a child, from the system's queue
/// that reports its end, and from the main thread. All state is guarded by `lock`.
final class ChildTable: @unchecked Sendable {
    private let lock = NSLock()
    private var children: [pid_t: (watch: ChildProcess.Watch, waitedFor: Bool)] = [:]

    /// Calls `handler` once, on a queue of the system, when the child has ended; also when
    /// it has ended already.
    func watch(_ pid: pid_t, waitedFor: Bool, handler: @escaping @Sendable (ChildProcess.Ending) -> Void) {
        let watch = ChildProcess.Watch(pid: pid) { [weak self] ending in
            self?.remove(pid)
            handler(ending)
        }
        lock.lock()
        children[pid] = (watch, waitedFor)
        lock.unlock()
        watch.start()
    }

    private func remove(_ pid: pid_t) {
        lock.lock()
        children[pid] = nil
        lock.unlock()
    }

    /// Asks the children a chain waits for to end.
    func terminateWaitedFor() {
        lock.lock()
        let waited = children.filter(\.value.waitedFor).map(\.key)
        lock.unlock()
        waited.forEach { _ = kill($0, SIGTERM) }
    }
}
