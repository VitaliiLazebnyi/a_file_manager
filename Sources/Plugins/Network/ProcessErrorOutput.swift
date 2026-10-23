import Foundation

/// What a child process writes to its error output (why ssh could not log in): the last few
/// kilobytes, collected as they come and read once more when the process has ended.
///
/// The text is guarded by `lock`; a read from the pipe and the keeping of what it brought are one
/// step under `reading`.
internal final class ProcessErrorOutput: @unchecked Sendable {
    /// The pipe the child process writes its errors into.
    internal let pipe = Pipe()
    private let lock = NSLock()
    /// Held while a piece of the output is read and kept.
    private let reading = NSLock()
    private var text = Data()

    /// The last three lines that were written.
    internal var message: String {
        lock.lock()
        defer { lock.unlock() }
        let lines = String(repairingUTF8: text).split(whereSeparator: \.isNewline)
        return lines.suffix(3).joined(separator: "\n")
    }

    /// Keeps what arrives from now on, on the pipe's own thread, until the output ends or
    /// `stopCollecting` is called.
    internal func collect() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self, reading] handle in
            // Reading and keeping are one step under `reading`: whoever reads the rest at the end
            // (`drain`) must not find the pipe empty while a piece that was taken out of it here
            // is not kept yet.
            reading.lock()
            defer { reading.unlock() }
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            keep(data)
        }
    }

    /// Stops keeping what arrives.
    internal func stopCollecting() {
        pipe.fileHandleForReading.readabilityHandler = nil
    }

    /// Reads what the child process still has to say, for `seconds` at most (a process ssh
    /// started may hold the pipe open for longer).
    ///
    /// Runs once, when the dialogue has ended.
    internal func drain(for seconds: TimeInterval) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = nil
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let deadline = Date().addingTimeInterval(seconds)
        var buffer = [UInt8](repeating: 0, count: 4_096)
        reading.lock()
        defer { reading.unlock() }
        while Date() < deadline {
            var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&ready, 1, 50) > 0 else { continue }
            // Nobody else reads the pipe now (the handler above is gone, and `reading` is held),
            // so a descriptor that is ready has bytes or its end: a read that does not block is
            // not interrupted, and finds what `poll` saw.
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else {
                return
            }
            keep(Data(buffer[0..<count]))
        }
    }

    /// Adds `data` to the text; past 8 KB only the last 4 KB are kept.
    private func keep(_ data: Data) {
        lock.lock()
        text.append(data)
        if text.count > 8_192 { text = Data(text.suffix(4_096)) }
        lock.unlock()
    }

    deinit {
        // Nothing to release.
    }
}
