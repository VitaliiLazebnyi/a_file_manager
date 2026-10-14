import AFMKernel
import Foundation

/// The log of file operations (spec 13 › Operation › Log file): one line per item,
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
public final class OperationLog {
    public enum Rotation: Equatable {
        case never
        /// A new file with the first line written after midnight.
        case daily
        /// A new file when the log would grow beyond this many bytes.
        case size(Int)
    }

    /// What the Log file page of the configuration holds.
    public struct Configuration: Equatable {
        public var isEnabled = false
        public var file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
            "Library/Logs/A File Manager/operations.log")
        public var logsTransfers = true
        public var logsDeletes = true
        public var logsFolders = true
        public var logsSuccess = true
        public var logsErrors = true
        public var logsSkipped = true
        public var rotation = Rotation.never
        /// How many rotated copies are kept; 0 keeps all.
        public var keepCount = 30

        public init() {}

        /// Whether a record is of a kind the user wants in the log.
        public func wants(_ record: OperationRecord) -> Bool {
            wants(record.verb, record.status)
        }

        /// The same, asked before the record is made.
        public func wants(_ verb: OperationRecord.Verb, _ status: OperationRecord.Status) -> Bool {
            let kind: Bool
            switch verb {
            case .copy, .move, .append, .rename, .newFile: kind = logsTransfers
            case .delete, .trash: kind = logsDeletes
            case .makeFolder, .removeFolder: kind = logsFolders
            }
            switch status {
            case .done: return kind && logsSuccess
            case .failed: return kind && logsErrors
            case .skipped: return kind && logsSkipped
            }
        }
    }

    public let configuration: Configuration
    private let queue = DispatchQueue(label: "afm.fileoperations.log", qos: .utility)
    private let now: () -> Date
    private let fm = FileManager.default
    private let stamp: DateFormatter
    private let day: DateFormatter

    // On the log's queue only.
    private var pending: [(line: String, time: Date)] = []
    private var drainIsScheduled = false
    private var handle: FileHandle?
    /// The file the handle writes to, to notice when somebody moved or deleted it.
    private var handleFile: UInt64?
    /// How long a burst of lines may wait before it is written.
    private static let delay: TimeInterval = 0.25

    /// `now` is the clock; tests bring their own.
    public init(_ configuration: Configuration, now: @escaping () -> Date = Date.init) {
        self.configuration = configuration
        self.now = now
        stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
    }

    deinit {
        try? handle?.close()
    }

    /// Any thread.
    public func write(_ record: OperationRecord) {
        guard configuration.isEnabled, configuration.wants(record) else { return }
        let time = now()
        queue.async {
            self.pending.append((Self.line(for: record, at: self.stamp.string(from: time)), time))
            guard !self.drainIsScheduled else { return }
            self.drainIsScheduled = true
            self.queue.asyncAfter(deadline: .now() + Self.delay) { self.drain() }
        }
    }

    /// Waits until everything handed in so far is in the file, and lets go of the file.
    /// Blocks for as long as the disk takes: for a background thread, and for tests.
    public func flush() {
        queue.sync {
            drain()
            closeHandle()
        }
    }

    /// The same for the end of the program, where the caller is the main thread: waits at most
    /// `timeout` seconds, so that a log on a volume that no longer answers cannot keep the
    /// program from quitting. The writing itself goes on on the log's queue. False when the
    /// time ran out.
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
    /// answering). The writing itself goes on on the log's queue either way. Any thread.
    public func flush(cancellation: CancellationFlag, completion: @escaping () -> Void) {
        final class Once {
            private let lock = NSLock()
            private var completion: (() -> Void)?
            var token: AnyObject?
            init(_ completion: @escaping () -> Void) { self.completion = completion }
            func fire() {
                lock.lock()
                let call = completion
                (completion, token) = (nil, nil)
                lock.unlock()
                call?()
            }
        }
        let once = Once(completion)
        once.token = cancellation.onCancel { once.fire() }
        queue.async {
            self.drain()
            self.closeHandle()
            once.fire()
        }
        if cancellation.isCancelled { once.fire() }
    }

    /// Runs `work` on the log's queue, in its turn. For tests, which hold the queue up with
    /// it the way a disk that has stopped answering does.
    func onQueue(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    /// Writes what is collected without waiting for it; for the end of a job, which has no use
    /// for the answer.
    public func flushSoon() {
        queue.async { self.drain() }
    }

    /// One record is one line, whatever the names hold: a line break or another control
    /// character in a file name or an error text is written out (`<U+000A>`), so that no name
    /// can add lines of its own to the log.
    public static func line(for record: OperationRecord, at time: String) -> String {
        let what =
            record.verb.rawValue + ": " + DisplayName.escaped(record.source)
            + (record.target.map { " -> " + DisplayName.escaped($0) } ?? "")
        switch record.status {
        case .done: return "\(time): \(what)\n"
        case .failed(let message): return "\(time): Error: \(what): \(DisplayName.escaped(message))\n"
        case .skipped: return "\(time): Skipped: \(what)\n"
        }
    }

    // MARK: On the log's queue

    private func closeHandle() {
        try? handle?.close()
        handle = nil
        handleFile = nil
    }

    private func drain() {
        drainIsScheduled = false
        guard !pending.isEmpty else { return }
        let lines = pending
        pending.removeAll(keepingCapacity: true)
        let file = configuration.file
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // What the disk says about the file, once for the burst; after that it is known from what is written.
        var state = fileState()
        var chunk = Data()
        for (line, time) in lines {
            let bytes = line.utf8.count
            // What this burst has collected for the file counts as in it: after a rotation
            // within the burst the new file grows by `chunk`, and is rotated again when due.
            if rotationIsDue(adding: bytes, size: state.size + chunk.count, modified: state.modified, at: time) {
                writeChunk(&chunk)
                closeHandle()
                rotate(at: state.modified ?? time)
                state = (0, nil)
            }
            chunk.append(contentsOf: line.utf8)
            state.modified = time
        }
        writeChunk(&chunk)
    }

    /// The size of the file and the time it was last written; 0 and nil when there is none.
    /// A handle that no longer points to the file at that place is dropped.
    private func fileState() -> (size: Int, modified: Date?) {
        guard let attributes = try? fm.attributesOfItem(atPath: configuration.file.path) else {
            closeHandle()
            return (0, nil)
        }
        if handle != nil, (attributes[.systemFileNumber] as? UInt64) != handleFile { closeHandle() }
        return ((attributes[.size] as? Int) ?? 0, attributes[.modificationDate] as? Date)
    }

    private func writeChunk(_ chunk: inout Data) {
        defer { chunk.removeAll(keepingCapacity: true) }
        guard !chunk.isEmpty else { return }
        let file = configuration.file
        if handle == nil {
            // Opened for appending: every write goes to the end of the file as it is then,
            // also after somebody else emptied it or wrote to it.
            // Without waiting: a pipe that somebody put where the log is to go would hold the
            // opening, and with it the log's queue, until a reader came. Only a plain file is
            // written to.
            let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NONBLOCK | O_NOCTTY, 0o644)
            guard descriptor >= 0 else { return }
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

    private func rotationIsDue(adding bytes: Int, size: Int, modified: Date?, at time: Date) -> Bool {
        switch configuration.rotation {
        case .never:
            return false

        case .daily:
            guard let modified else { return false }
            return day.string(from: modified) != day.string(from: time)

        case .size(let limit):
            return size > 0 && size + bytes > limit
        }
    }

    /// Moves the log to its rotated name and removes the oldest copies beyond the limit.
    private func rotate(at written: Date) {
        let file = configuration.file
        guard fm.fileExists(atPath: file.path) else { return }
        let (base, ext) = (file.deletingPathExtension().lastPathComponent, file.pathExtension)
        func copy(_ tag: String) -> URL {
            file.deletingLastPathComponent().appendingPathComponent(
                ext.isEmpty ? "\(base).\(tag)" : "\(base).\(tag).\(ext)")
        }
        switch configuration.rotation {
        case .never:
            return

        case .daily:
            var target = copy(day.string(from: written))
            var counter = 2
            while fm.fileExists(atPath: target.path) {
                target = copy("\(day.string(from: written))-\(counter)")
                counter += 1
            }
            try? fm.moveItem(at: file, to: target)

        case .size:
            var counter = 1
            while fm.fileExists(atPath: copy(String(counter)).path) { counter += 1 }
            try? fm.moveItem(at: file, to: copy(String(counter)))
        }
        guard configuration.keepCount > 0 else { return }
        // The oldest copies beyond the limit go. Only files named the way this log names its
        // copies: a neighbour such as `operations.backup.log` is somebody else's.
        let siblings =
            (try? fm.contentsOfDirectory(
                at: file.deletingLastPathComponent(), includingPropertiesForKeys: [.contentModificationDateKey]))
            ?? []
        let copies = siblings.filter { Self.isRotatedCopy($0.lastPathComponent, of: file.lastPathComponent) }
            .map {
                (
                    $0,
                    (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                        ?? .distantPast
                )
            }
            .sorted { $0.1 > $1.1 }
        for (url, _) in copies.dropFirst(configuration.keepCount) { try? fm.removeItem(at: url) }
    }

    /// `operations.2026-10-12.log`, `operations.2026-10-12-2.log` and `operations.3.log` are
    /// copies of `operations.log`.
    static func isRotatedCopy(_ name: String, of log: String) -> Bool {
        let url = URL(fileURLWithPath: log)
        let (base, ext) = (url.deletingPathExtension().lastPathComponent, url.pathExtension)
        let suffix = ext.isEmpty ? "" : "." + ext
        guard name != log, name.hasPrefix(base + "."), name.hasSuffix(suffix),
            name.count > base.count + 1 + suffix.count
        else { return false }
        let tag = name.dropFirst(base.count + 1).dropLast(suffix.count)
        return tag.range(of: #"^(\d{4}-\d{2}-\d{2}(-\d+)?|\d+)$"#, options: .regularExpression) != nil
    }
}
