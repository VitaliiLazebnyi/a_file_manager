import AFMKernel
import Foundation

/// A line typed on the command line, taken apart as far as the program needs to know it
/// (spec 02 › Executing a line).
///
/// The shell does the real parsing; this only finds out how the line is to be started. A value
/// without state: usable from any thread.
internal struct TypedCommand: Equatable {
    /// The line without surrounding blanks and without a trailing `&`.
    internal let command: String
    /// A trailing `&`: the command is started and left alone, its output is not collected.
    internal let isDetached: Bool
    /// The first word with quotes and backslash escapes resolved: the program to start.
    internal let firstWord: String
    /// What follows the first word, as typed.
    internal let arguments: String

    internal init?(_ line: String) {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // `&&` at the end is an unfinished line, not a request to run in the background.
        let detached = text.hasSuffix("&") && !text.hasSuffix("&&")
        if detached { text = String(text.dropLast()).trimmingCharacters(in: .whitespaces) }
        guard !text.isEmpty else {
            return nil
        }
        command = text
        isDetached = detached
        (firstWord, arguments) = Self.split(text)
    }

    /// The first word as a shell would read it (quotes group, a backslash keeps the next
    /// character), and what follows it.
    internal static func split(_ text: String) -> (word: String, rest: String) {
        var word = ""
        var quote: Character?
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                word.append(character)
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
            } else if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == " " || character == "\t" {
                break
            } else {
                word.append(character)
            }
            index = text.index(after: index)
        }
        return (word, text[index...].trimmingCharacters(in: .whitespaces))
    }

    /// A path as typed (`~/x`, `/x`, `x/y`) as a location; relative paths start at `directory`.
    internal static func location(of path: String, relativeTo directory: URL) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        return (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : directory.appendingPathComponent(expanded))
            .standardizedFileURL
    }

    /// Where an application of that name would be, when the first word names one: a path ending
    /// in `.app`, or a bare name found in the usual application folders.
    ///
    /// Asks the disk, so it is for a background thread.
    ///
    /// A bare name (`Preview.app`) means the application of the system first: one of the same
    /// name that lies in the panel's folder (a downloaded folder, a memory stick) is opened
    /// only when no installed one has the name, or when it is asked for by path (`./Preview.app`).
    /// `path` is the PATH that decides whether a bare name is a program instead.
    internal func application(
        relativeTo directory: URL,
        searching folders: [URL] = Self.applicationFolders,
        path: String = Self.processPath
    ) -> URL? {
        let fm = FileManager.default
        func bundle(at url: URL) -> URL? {
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? url : nil
        }
        if firstWord.lowercased().hasSuffix(".app") {
            let here = Self.location(of: firstWord, relativeTo: directory)
            if firstWord.contains("/") || firstWord.hasPrefix("~") {
                return bundle(at: here)
            }
            return folders.lazy.compactMap { bundle(at: $0.appendingPathComponent(firstWord)) }.first
                ?? bundle(at: here)
        }
        // A bare name is an application only when nothing else is asked of it; `open -a` and
        // the like stay with the shell.
        guard arguments.isEmpty, !firstWord.contains("/"), !firstWord.isEmpty else {
            return nil
        }
        // A program of that name on the PATH wins: on a case-insensitive disk `mail` would
        // otherwise open Mail.app instead of /usr/bin/mail.
        if Self.isOnPath(firstWord, path: path) {
            return nil
        }
        return folders.lazy.compactMap { bundle(at: $0.appendingPathComponent(firstWord + ".app")) }.first
    }

    /// Whether an executable file of that name is in a folder of the PATH.
    internal static func isOnPath(_ name: String, path: String = Self.processPath) -> Bool {
        path.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + name) }
    }

    /// The PATH this process was started with.
    ///
    /// A program started from the Dock has a short one; the PATH of a terminal is
    /// `LoginShell.searchPath`.
    internal static var processPath: String { path(in: ProcessInfo.processInfo.environment) }

    /// The PATH of `environment`; the system's usual one without.
    internal static func path(in environment: [String: String]) -> String {
        environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    }

    internal static let applicationFolders: [URL] = [
        URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"), URL(fileURLWithPath: "/Applications/Utilities"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    ]
}

/// What became of a child process.
internal struct ProcessOutcome {
    /// Standard output and standard error in the order they were written.
    internal var output = ""
    internal var status: Int32 = 0
    /// More was written than is kept.
    internal var isTruncated = false
    internal var wasCancelled = false
    /// Set when the process could not be started at all.
    internal var failure: String?
}

/// Runs a child process to its end and collects what it writes.
///
/// **Threading.** `run` blocks until the child has ended and is meant for a job's thread. The
/// child's output arrives on a queue of the system and is kept behind a lock; the pipe is
/// emptied while the child runs, so a child that writes a lot never waits for a full pipe.
/// Cancelling asks the child to end (SIGTERM) and, if it does not listen, ends it (SIGKILL).
internal struct ProcessRunner {
    /// The most output that is kept; a command that prints without end must not fill memory.
    internal static let outputLimit = 8 * 1_024 * 1_024

    internal let executable: URL
    internal let arguments: [String]
    internal let directory: URL?
    /// Without, nothing is read: the child writes into the void and is not waited for longer
    /// than it takes the shell to start it.
    internal var collectsOutput = true
    /// The child's environment; this program's unless told otherwise.
    internal var environment = ProcessInfo.processInfo.environment

    /// All state is guarded by `lock`.
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var truncated = false

        func append(_ block: Data) {
            lock.lock()
            defer { lock.unlock() }
            let room = ProcessRunner.outputLimit - data.count
            if block.count > room { truncated = true }
            if room > 0 { data.append(block.prefix(room)) }
        }

        var contents: (data: Data, truncated: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (data, truncated)
        }
    }

    /// Ends the shell and what it started: the whole group when the shell leads one of its own,
    /// else the shell alone (the group is then ours too).
    private static func kill(_ pid: pid_t) {
        if getpgid(pid) == pid { _ = Darwin.kill(-pid, SIGKILL) }
        _ = Darwin.kill(pid, SIGKILL)
    }

    /// `progress` is told now and then how many bytes have arrived.
    internal func run(cancellation: CancellationFlag, progress: (Int) -> Void = { _ in }) -> ProcessOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let buffer = Buffer()
        let (exited, drained) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        var pipe: Pipe?
        if collectsOutput {
            let both = Pipe()
            process.standardOutput = both
            process.standardError = both
            both.fileHandleForReading.readabilityHandler = { handle in
                let block = handle.availableData
                if block.isEmpty {
                    // End of file: every writer has closed its end.
                    handle.readabilityHandler = nil
                    drained.signal()
                } else {
                    buffer.append(block)
                }
            }
            pipe = both
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            pipe?.fileHandleForReading.readabilityHandler = nil
            // Foundation does not let go of the handler of a process that did not start.
            process.terminationHandler = nil
            return ProcessOutcome(failure: error.localizedDescription)
        }
        // The parent's copy of the writing end must go, or the end of the output never comes.
        try? pipe?.fileHandleForWriting.close()

        var outcome = ProcessOutcome()
        var askedToEnd: Date?
        while exited.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            progress(buffer.contents.data.count)
            guard cancellation.isCancelled else { continue }
            outcome.wasCancelled = true
            if let asked = askedToEnd {
                if Date().timeIntervalSince(asked) > 2 { Self.kill(process.processIdentifier) }
            } else {
                process.terminate()
                askedToEnd = Date()
            }
        }
        if let pipe {
            // What is still in the pipe is read; a grandchild that keeps the pipe open is not waited for.
            _ = drained.wait(timeout: .now() + .milliseconds(outcome.wasCancelled ? 100 : 500))
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        let (data, truncated) = buffer.contents
        outcome.output = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        outcome.isTruncated = truncated
        outcome.status = process.terminationStatus
        return outcome
    }
}

/// The lines the user ran, newest first (spec 02 › Limits and persistence: 20 entries).
internal struct CommandHistory {
    internal static let limit = 20
    internal static let key = "history"

    internal static func load(from settings: any SettingsStore) -> [String] {
        settings.value([String].self, forKey: key) ?? []
    }

    /// A line typed with a blank in front is not remembered, as in a shell: the way to run
    /// something with a password in it without leaving it in the settings.
    internal static func isPrivate(_ line: String) -> Bool {
        line.unicodeScalars.first == " " || line.unicodeScalars.first == "\t"
    }

    /// Puts `line` first; an earlier occurrence of the same line goes.
    internal static func adding(_ line: String, to history: [String]) -> [String] {
        Array(([line] + history.filter { $0 != line }).prefix(limit))
    }
}
