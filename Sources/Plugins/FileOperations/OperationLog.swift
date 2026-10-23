public import AFMKernel
public import Foundation

/// The log of file operations (spec 13 › Operation › Log file): one line per item,.
///
///     2026-10-12 14:03:22: Copy: /a/one.txt -> /b/one.txt
///     2026-10-12 14:03:22: Error: Delete: /a/two.txt: Permission denied
///     2026-10-12 14:03:23: Skipped: Copy: /a/three.txt -> /b/three.txt
///
/// **Threading.** `write` may be called from any thread, several at once; it only hands the
/// record to the log's own serial queue, which formats it and collects the lines for a moment.
/// The lines of a burst go to the file together, through a handle that stays open, after the
/// file has been checked for rotation once. `flush` (a job's end, the program's end) writes at
/// once. Nothing here runs on the main thread except the cheap hand-over.
///
/// Unchecked `Sendable`: the mutable state is used on the log's queue only; the rest does not
/// change after `init`.
public final class OperationLog: @unchecked Sendable {
    /// How long a burst of lines may wait before it is written.
    private static let delay: TimeInterval = 0.25

    /// What is logged, where, and how the file is rotated; fixed for the log's life.
    public let configuration: Configuration
    private let queue = DispatchQueue(label: "afm.fileoperations.log", qos: .utility)
    private let now: @Sendable () -> Date
    private let fileManager = FileManager.default
    private let stamp: DateFormatter
    private let day: DateFormatter

    // On the log's queue only.
    private var pending: [(line: String, time: Date)] = []
    private var drainIsScheduled = false
    private var handle: FileHandle?
    /// The file the handle writes to, to notice when somebody moved or deleted it.
    private var handleFile: UInt64?

    /// `now` is the clock; tests bring their own.
    @preconcurrency
    public init(_ configuration: Configuration, now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.now = now
        stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
    }

    /// One record is one line, whatever the names hold: a line break or another control
    /// character in a file name or an error text is written out (`<U+000A>`), so that no name
    /// can add lines of its own to the log.
    public static func line(for record: OperationRecord, at time: String) -> String {
        let what =
            record.verb.rawValue + ": " + DisplayName.escaped(record.source)
            + (record.target.map { " -> " + DisplayName.escaped($0) } ?? "")
        switch record.status {
        case .done:
            return "\(time): \(what)\n"

        case .failed(let message):
            return "\(time): Error: \(what): \(DisplayName.escaped(message))\n"

        case .skipped:
            return "\(time): Skipped: \(what)\n"
        }
    }

    /// When a file was last changed, as its `stat` says.
    private static func modified(_ info: stat) -> Date {
        Date(
            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec)
                / 1e9
        )
    }

    /// `operations.2026-10-12.log`, `operations.2026-10-12-2.log` and `operations.3.log` are
    /// copies of `operations.log`.
    internal static func isRotatedCopy(_ name: String, of log: String) -> Bool {
        let url = URL(fileURLWithPath: log)
        let (base, ext) = (url.deletingPathExtension().lastPathComponent, url.pathExtension)
        let suffix = ext.isEmpty ? "" : "." + ext
        guard name != log, name.hasPrefix(base + "."), name.hasSuffix(suffix),
            name.count > base.count + 1 + suffix.count
        else { return false }
        let tag = name.dropFirst(base.count + 1).dropLast(suffix.count)
        return tag.range(of: #"^(\d{4}-\d{2}-\d{2}(-\d+)?|\d+)$"#, options: .regularExpression) != nil
    }

    /// Any thread.
    public func write(_ record: OperationRecord) {
        guard configuration.isEnabled, configuration.wants(record) else {
            return
        }
        let time = now()
        queue.async {
            self.pending.append((Self.line(for: record, at: self.stamp.string(from: time)), time))
            guard !self.drainIsScheduled else {
                return
            }
            self.drainIsScheduled = true
            self.queue.asyncAfter(deadline: .now() + Self.delay) { self.drain() }
        }
    }

    /// Waits until everything handed in so far is in the file, and lets go of the file.
    ///
    /// Blocks for as long as the disk takes: for a background thread, and for tests.
    public func flush() {
        queue.sync {
            drain()
            closeHandle()
        }
    }

    /// The same for the end of the program, where the caller is the main thread: waits at most
    /// `timeout` seconds, so that a log on a volume that no longer answers cannot keep the
    /// program from quitting.
    ///
    /// The writing itself goes on on the log's queue. False when the time ran out.
    @discardableResult
    public func flush(timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async {
            self.drain()
            self.closeHandle()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// The same without anybody waiting on a thread: `completion` is called exactly once, on
    /// some thread, when everything handed in so far is in the file, or as soon as
    /// `cancellation` is set (the user does not want to wait for a disk that is not
    /// answering).
    ///
    /// The writing itself goes on on the log's queue either way. Any thread.
    @preconcurrency
    public func flush(cancellation: CancellationFlag, completion: @escaping @Sendable () -> Void) {
        // Calls `completion` the first time it fires, never again.
        //
        // Unchecked `Sendable`: all state is guarded by `lock`. What it lets go of (the
        // registration, whose release takes the flag's lock) is released outside the lock.
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var completion: (@Sendable () -> Void)?
            private var token: AnyObject?

            init(_ completion: @escaping @Sendable () -> Void) { self.completion = completion }

            // Holds the registration until `fire`; one that comes after it (the flag was set
            // already, or the log was quicker) is let go of at once.
            func keep(_ token: AnyObject) {
                lock.lock()
                if completion != nil { self.token = token }
                lock.unlock()
            }
            func fire() {
                lock.lock()
                let (call, registration) = (completion, token)
                (completion, token) = (nil, nil)
                lock.unlock()
                withExtendedLifetime(registration) {
                    // The registration is let go of here, outside the lock.
                }
                call?()
            }

            deinit {
                // Nothing to release: the registration went when it fired.
            }
        }
        let once = Once(completion)
        once.keep(cancellation.onCancel { once.fire() })
        queue.async {
            self.drain()
            self.closeHandle()
            once.fire()
        }
        if cancellation.isCancelled { once.fire() }
    }

    /// Runs `work` on the log's queue, in its turn.
    ///
    /// For tests, which hold the queue up with it the way a disk that has stopped answering does.
    internal func onQueue(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    /// Writes what is collected without waiting for it; for the end of a job, which has no use
    /// for the answer.
    public func flushSoon() {
        queue.async { self.drain() }
    }

    // MARK: On the log's queue

    private func closeHandle() {
        try? handle?.close()
        handle = nil
        handleFile = nil
    }

    private func drain() {
        drainIsScheduled = false
        guard !pending.isEmpty else {
            return
        }
        let lines = pending
        pending.removeAll(keepingCapacity: true)
        let file = configuration.file
        try? fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // What the disk says about the file, once for the burst; after that it is known from what is written.
        var state = fileState()
        var chunk = Data()
        for (line, time) in lines {
            let bytes = line.utf8.count
            // What this burst has collected for the file counts as in it: after a rotation
            // within the burst the new file grows by `chunk`, and is rotated again when due.
            if let written = rotationDue(
                adding: bytes,
                size: state.size + chunk.count,
                modified: state.modified,
                at: time
            ) {
                writeChunk(&chunk)
                closeHandle()
                rotate(at: written)
                state = (0, nil)
            }
            chunk.append(contentsOf: line.utf8)
            state.modified = time
        }
        writeChunk(&chunk)
    }

    /// The size of the file and the time it was last written; 0 and nil when there is none.
    ///
    /// A handle that no longer points to the file at that place is dropped.
    private func fileState() -> (size: Int, modified: Date?) {
        var info = stat()
        guard stat(configuration.file.path, &info) == 0 else {
            closeHandle()
            return (0, nil)
        }
        if handle != nil, UInt64(info.st_ino) != handleFile {
            closeHandle()
        }
        return (Int(info.st_size), Self.modified(info))
    }

    private func writeChunk(_ chunk: inout Data) {
        defer { chunk.removeAll(keepingCapacity: true) }
        guard !chunk.isEmpty else {
            return
        }
        let file = configuration.file
        if handle == nil {
            // Opened for appending: every write goes to the end of the file as it is then,
            // also after somebody else emptied it or wrote to it.
            // Without waiting: a pipe that somebody put where the log is to go would hold the
            // opening, and with it the log's queue, until a reader came. Only a plain file is
            // written to.
            let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NONBLOCK | O_NOCTTY, 0o644)
            guard descriptor >= 0 else {
                return
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                close(descriptor)
                return
            }
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
            handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            handleFile = UInt64(info.st_ino)
        }
        try? handle?.write(contentsOf: chunk)
    }

    /// When the file to be rotated was last written, if adding `bytes` at `time` makes a rotation due.
    ///
    /// A file with something in it (`size`) has been written (`modified`).
    private func rotationDue(adding bytes: Int, size: Int, modified: Date?, at time: Date) -> Date? {
        switch configuration.rotation {
        case .never:
            return nil

        case .daily:
            guard let modified, day.string(from: modified) != day.string(from: time) else {
                return nil
            }
            return modified

        case .size(let limit):
            guard let modified, size > 0, size + bytes > limit else {
                return nil
            }
            return modified
        }
    }

    /// Moves the log to its rotated name and removes the oldest copies beyond the limit.
    private func rotate(at written: Date) {
        let file = configuration.file
        guard fileManager.fileExists(atPath: file.path) else {
            return
        }
        let (base, ext) = (file.deletingPathExtension().lastPathComponent, file.pathExtension)
        func copy(_ tag: String) -> URL {
            file.deletingLastPathComponent()
                .appendingPathComponent(
                    ext.isEmpty ? "\(base).\(tag)" : "\(base).\(tag).\(ext)"
                )
        }
        // Only a rotation that is due comes here: daily, or by size.
        if case .daily = configuration.rotation {
            var target = copy(day.string(from: written))
            var counter = 2
            while fileManager.fileExists(atPath: target.path) {
                target = copy("\(day.string(from: written))-\(counter)")
                counter += 1
            }
            try? fileManager.moveItem(at: file, to: target)
        } else {
            var counter = 1
            while fileManager.fileExists(atPath: copy(String(counter)).path) { counter += 1 }
            try? fileManager.moveItem(at: file, to: copy(String(counter)))
        }
        guard configuration.keepCount > 0 else {
            return
        }
        // The oldest copies beyond the limit go. Only files named the way this log names its
        // copies: a neighbour such as `operations.backup.log` is somebody else's.
        let folder = file.deletingLastPathComponent()
        let copies = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [])
            .compactMap { name -> (url: URL, modified: Date)? in
                let url = folder.appendingPathComponent(name)
                var info = stat()
                guard Self.isRotatedCopy(name, of: file.lastPathComponent), lstat(url.path, &info) == 0 else {
                    return nil
                }
                return (url, Self.modified(info))
            }
            .sorted { $0.modified > $1.modified }
        for (url, _) in copies.dropFirst(configuration.keepCount) { try? fileManager.removeItem(at: url) }
    }

    deinit {
        try? handle?.close()
    }
}
