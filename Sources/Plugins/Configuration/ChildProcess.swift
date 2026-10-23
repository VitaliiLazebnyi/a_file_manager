import Foundation

/// A program started on its own, with its arguments handed over byte for byte.
///
/// (Foundation's `Process` rewrites every argument in decomposed form, so a name with an accent
/// would arrive as another name on a volume that tells the two forms apart.) Its end is reported
/// through a dispatch source: no thread waits for it.
internal enum ChildProcess {
    /// A child that could not be started.
    internal struct Failure: Error {
        /// The number of the error the system gave.
        internal let code: Int32

        /// What to tell the user: a hint at list files when the command line is too long, else the
        /// system's text for the error.
        internal var message: String {
            code == E2BIG
                ? "The command line is too long. Pass many names through a list file (%L) instead."
                : String(cString: strerror(code))
        }
    }

    /// The calls of the system a child's start and end go through.
    ///
    /// Tests give failing ones: the system fails them only when it runs out of memory, or when a
    /// signal comes at that moment.
    internal struct SystemCalls: Sendable {
        /// The system's own.
        internal static let system = Self(
            initActions: { posix_spawn_file_actions_init(&$0) },
            initAttributes: { posix_spawnattr_init(&$0) },
            wait: { pid, status, options in
                let result = waitpid(pid, &status, options)
                return (result, errno)
            }
        )

        /// `posix_spawn_file_actions_init`: 0, or the number of the error.
        internal var initActions: @Sendable (inout posix_spawn_file_actions_t?) -> Int32
        /// `posix_spawnattr_init`: 0, or the number of the error.
        internal var initAttributes: @Sendable (inout posix_spawnattr_t?) -> Int32
        /// `waitpid` with its status and options: what it returns, and `errno` after it (which
        /// says something only when that is -1).
        internal var wait: @Sendable (pid_t, inout Int32, Int32) -> (result: pid_t, error: Int32)
    }

    /// How a child ended.
    internal struct Ending {
        /// The exit status; nil when a signal ended it.
        internal let status: Int32?
    }

    /// Reports the end of a child once, on a queue of the system.
    ///
    /// Lives in a `ChildTable`. `reported` is guarded by `lock`; nothing else changes after `init`.
    internal final class Watch: @unchecked Sendable {
        private let pid: pid_t
        private let handler: @Sendable (Ending) -> Void
        private let calls: SystemCalls
        private let source: any DispatchSourceProcess
        private let lock = NSLock()
        private var reported = false

        /// A watch on the child `pid` that collects it through `calls` and reports to `handler`.
        ///
        /// It does nothing until `start()`.
        internal init(pid: pid_t, calls: SystemCalls, handler: @escaping @Sendable (Ending) -> Void) {
            self.pid = pid
            self.handler = handler
            self.calls = calls
            source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        }

        /// Starts watching: from then on the end of the child is reported, also when it has ended
        /// already.
        internal func start() {
            source.setEventHandler { [self] in reap(waiting: true) }
            source.resume()
            // A child that ended before the source was there is collected here.
            reap(waiting: false)
        }

        /// Collects the child and reports it, once: `waiting` when the system said it ended (it
        /// may have been collected elsewhere then), else only when it has ended already.
        internal func reap(waiting: Bool) {
            lock.lock()
            if reported {
                lock.unlock()
                return
            }
            var status: Int32 = 0
            var answer: (result: pid_t, error: Int32)
            repeat { answer = calls.wait(pid, &status, waiting ? 0 : WNOHANG) } while answer == (-1, EINTR)
            let result = answer.result
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

        deinit {
            // Nothing to release.
        }
    }

    /// Starts `executable` in `directory`, with nothing to read and its output discarded.
    ///
    /// Returns the process number. Blocks for the time the start takes: not for the main thread.
    internal static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        directory: String,
        calls: SystemCalls
    ) -> Result<pid_t, Failure> {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        // The two return the number of the error; they do not set `errno`.
        let actionsMade = calls.initActions(&actions)
        guard actionsMade == 0 else {
            return .failure(Failure(code: actionsMade))
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let attributesMade = calls.initAttributes(&attributes)
        guard attributesMade == 0 else {
            return .failure(Failure(code: attributesMade))
        }
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
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer {
            for argument in argv {
                free(argument)
            }
            for variable in envp {
                free(variable)
            }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp)
        return result == 0 ? .success(pid) : .failure(Failure(code: result))
    }
}
