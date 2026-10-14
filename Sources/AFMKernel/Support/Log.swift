public import os

/// Where the program says what it does, for Console, Instruments and Help › Export
/// Diagnostics…. Every entry is filed under one subsystem, the program's bundle identifier,
/// and a category per module: `Kernel`, `Kernel.Panels`, `Kernel.Jobs`, `Shell`, and each
/// plugin's name (`Archives`, `Network`, ...). Loggers are made here and nowhere else.
///
/// **Levels.** `debug`: traces for development, not kept. `info`: a change of state (a folder
/// read, a job started or ended, an archive opened). `notice`: what the user would recognise
/// (connected to a server, settings imported). `error`: an operation failed, with the error.
/// `fault`: a broken rule of the program, which is a bug.
///
/// **Privacy.** Names, paths, URLs, hosts, user names and every text from outside are written
/// `privacy: .private`; counts, sizes, durations, error codes and the program's own names
/// (of commands, plugins, schemes) `.public`. Passwords, keychain items, certificates and the
/// contents of files are never logged.
///
/// **Threads.** Loggers and signposters are `Sendable`: any thread logs, nothing waits for the
/// main thread, and logging never blocks.
public enum Log: Sendable {
    /// The subsystem of every entry of the program: its bundle identifier.
    public static let subsystem = "local.a-file-manager"

    /// The logger of one category. Each file that logs keeps one, made once
    /// (`private static let log = Log.logger("Archives")`).
    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    /// The signposter of one category, for the intervals of the hot paths. Their names match
    /// those of the benchmarks (`sort`, `filter`, `mark`, `list`, `copy`, `archive-open`), so
    /// Instruments shows where the time of the real program goes.
    public static func signposter(_ category: String) -> OSSignposter {
        OSSignposter(subsystem: subsystem, category: category)
    }
}
