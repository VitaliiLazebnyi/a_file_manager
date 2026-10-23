import Foundation

/// A program of the system run as a child process, without a shell: every argument reaches the
/// program exactly as given.
internal enum Tool {
    /// The system's tar, which writes what libarchive reads of a foreign archive out again as plain TAR.
    internal static let bsdtar = "/usr/bin/bsdtar"
    /// The system's bzip2, which compresses and decompresses `.bz2` files.
    internal static let bzip2 = "/usr/bin/bzip2"
    /// The system's gzip, which unpacks the old `compress` format.
    internal static let gzip = "/usr/bin/gzip"

    /// What a child process sees of its surroundings: nothing of the user's.
    ///
    /// The tools read options from variables (`BZIP2`, `TAR_READER_OPTIONS`, …) and look for helper
    /// programs on the search path; neither is the caller's to steer. The UTF-8 locale is what lets
    /// bsdtar pass on names that are not ASCII.
    internal static let environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8"]
    /// Of what a tool complains about, this much is kept; a tool that warns about every one
    /// of a million entries must not fill the memory.
    internal static let errorLimit = 64 << 10

    /// A process set up to run a tool: the surroundings above, and a working folder in which
    /// there is nothing to find by a relative path.
    internal static func process(_ executable: String, _ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: "/var/empty", isDirectory: true)
        return process
    }

    /// Reads a pipe to its end on a thread of its own (not one of the shared pool's, which a
    /// child that never ends would take away for good) and keeps the first `errorLimit` bytes.
    internal static func collect(
        _ handle: FileHandle,
        group: DispatchGroup,
        into store: @escaping @Sendable (Data) -> Void
    ) {
        group.enter()
        Thread.detachNewThread {
            var kept = Data()
            let descriptor = handle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 1 << 14)
            while true {
                let got = retryingInterrupted {
                    buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                }
                guard got > 0 else { break }
                if kept.count < errorLimit { kept.append(contentsOf: buffer[..<min(got, errorLimit - kept.count)]) }
            }
            store(kept)
            group.leave()
        }
    }

    /// Runs the program with `input` on its standard input and returns its standard output.
    internal static func filter(_ executable: String, _ arguments: [String], input: Data) throws -> Data {
        let process = Self.process(executable, arguments)
        let (stdin, stdout, stderr) = (Pipe(), Pipe(), Pipe())
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Input is written on another thread while the output is read here, so neither pipe
        // fills up and blocks the child. A child that dies early must not kill the program
        // with SIGPIPE.
        let writeEnd = stdin.fileHandleForWriting
        _ = fcntl(writeEnd.fileDescriptor, F_SETNOSIGPIPE, 1)
        // Both on threads of their own: one per piece on every core would otherwise use up
        // the threads the shared pool has for work that blocks.
        let group = DispatchGroup()
        group.enter()
        Thread.detachNewThread {
            try? writeEnd.write(contentsOf: input)
            try? writeEnd.close()
            group.leave()
        }
        // Written by the reading thread before it leaves the group, read here only after the wait.
        nonisolated(unsafe) var errors = Data()
        collect(stderr.fileHandleForReading, group: group) { errors = $0 }
        let output = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        group.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure(executable, errors) }
        return output
    }

    /// The error of a tool that failed: what it wrote to its standard error, or only that it failed when it
    /// wrote nothing (or nothing that is UTF-8).
    internal static func failure(_ executable: String, _ errors: Data) -> ArchiveError {
        let text = (String(bytes: errors, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = URL(fileURLWithPath: executable).lastPathComponent
        return .toolFailed(text.isEmpty ? "\(name) failed." : text)
    }
}
