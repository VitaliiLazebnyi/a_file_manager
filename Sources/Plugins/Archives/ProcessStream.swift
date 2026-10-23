import Foundation

/// The standard output of a child process as a stream.
///
/// Closing it before the end stops the child, which is how a cancelled operation ends it; so does
/// the `control`, from any thread, and the read that waits for the child then throws.
///
/// Unchecked: `errors` and `isClosed` are guarded by `lock`; the rest is fixed in `init` or
/// belongs to the thread that reads the stream. Other threads only `stop` the child.
internal final class ProcessStream: ByteStream, @unchecked Sendable {
    private let process: Process
    private let executable: String
    private let output = Pipe()
    private let errorPipe = Pipe()
    private let errorsRead = DispatchGroup()
    private let lock = NSLock()
    private var errors = Data()
    private var isClosed = false
    private var ended = false
    private let control: StreamInterrupt?

    /// Starts `executable` with `arguments` (see `Tool`), with nothing on its standard input.
    ///
    /// Throws when the program cannot be started.
    internal init(_ executable: String, _ arguments: [String], control: StreamInterrupt?) throws {
        self.executable = executable
        self.control = control
        process = Tool.process(executable, arguments)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errorPipe
        try process.run()
        Tool.collect(errorPipe.fileHandleForReading, group: errorsRead) { [weak self] text in
            guard let self else {
                return
            }
            lock.lock()
            errors = text
            lock.unlock()
        }
        control?.onSet { [weak self] in self?.stop() }
    }

    /// Ends the child; the read that waits for it then reaches the end of its output.
    ///
    /// Any thread.
    private func stop() {
        lock.lock()
        defer { lock.unlock() }
        if !isClosed, process.isRunning { process.terminate() }
    }

    /// The next block of the output, up to `count` bytes; nil once the child ended well.
    ///
    /// Waits for the child at the end, and throws what it complained about when it failed.
    internal func read(upToCount count: Int) throws -> Data? {
        guard !ended else {
            return nil
        }
        try control?.check()
        // A stream that was closed (its reader stopped) has given up its pipe: nothing can be read
        // from it, and what it gave is not the whole output.
        lock.lock()
        let closed = isClosed
        lock.unlock()
        guard !closed else { throw ArchiveError.cancelled }
        // A pipe hands over 64 KB at a time; a larger block would only be allocated in vain.
        let capacity = min(max(count, 1), 1 << 16)
        let descriptor = output.fileHandleForReading.fileDescriptor
        if let buffer = malloc(capacity) {
            let got = retryingInterrupted { Darwin.read(descriptor, buffer, capacity) }
            if got > 0 {
                return Data(bytesNoCopy: buffer, count: got, deallocator: .free)
            }
            free(buffer)
        }
        ended = true
        // A child that was stopped by the request has no failure to report.
        try control?.check()
        process.waitUntilExit()
        errorsRead.wait()
        lock.lock()
        let text = errors
        lock.unlock()
        if process.terminationStatus != 0 { throw Tool.failure(executable, text) }
        return nil
    }

    /// Stops the child if it still runs and gives up its output; once only, later calls do nothing.
    internal func close() {
        lock.lock()
        let wasClosed = isClosed
        isClosed = true
        lock.unlock()
        guard !wasClosed else {
            return
        }
        if process.isRunning { process.terminate() }
        try? output.fileHandleForReading.close()
    }

    deinit { close() }
}
