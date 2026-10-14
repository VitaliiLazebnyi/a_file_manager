import AFMKernel
import Foundation

/// What a file tool reports instead of a result.
enum ToolError: LocalizedError, Equatable {
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "The operation was cancelled."
        case .failed(let message): return message
        }
    }
}

/// What to do about a file that is in the way of one a tool wants to write.
enum ExistingFileChoice {
    case overwrite, overwriteAll, skip, autoRename, cancel
}

/// The surroundings of one run of a file tool: the file systems it reads and writes
/// through, its progress and the questions it may ask.
///
/// **Threading.** A run belongs to its job, but `advance` and `isCancelled` may be called
/// from several threads at once (files are hashed side by side); everything else is used
/// from the job's own thread.
final class ToolRun {
    /// Files are read and written in blocks of this size, never as a whole.
    static let blockSize = 1 << 20

    let fileSystems: FileSystemRegistry
    let cancellation: CancellationFlag
    private let report: (JobProgress) -> Void
    private let askExisting: (URL) -> ExistingFileChoice
    private let lock = NSLock()
    /// Held while a report is made, so reports reach the window one at a time and in order.
    private let reportLock = NSLock()
    private var bytesDone: Int64 = 0
    private var bytesTotal: Int64 = 0
    private var itemsDone = 0
    private var itemsTotal = 0
    private var lines: [String] = []
    private var lastReport = Date.distantPast
    private var overwritesAll = false

    /// Without a job (in tests of the tools themselves) nothing is reported and existing
    /// files are overwritten.
    init(
        fileSystems: FileSystemRegistry, cancellation: CancellationFlag = CancellationFlag(),
        report: @escaping (JobProgress) -> Void = { _ in },
        askExisting: @escaping (URL) -> ExistingFileChoice = { _ in .overwrite }
    ) {
        self.fileSystems = fileSystems
        self.cancellation = cancellation
        self.report = report
        self.askExisting = askExisting
    }

    /// A run inside a job: progress goes to its window, questions through `ask`.
    convenience init(
        fileSystems: FileSystemRegistry, monitor: any JobMonitor, askExisting: @escaping (URL) -> ExistingFileChoice
    ) {
        self.init(
            fileSystems: fileSystems, cancellation: monitor.cancellation, report: monitor.report,
            askExisting: { url in monitor.ask { askExisting(url) } })
    }

    var isCancelled: Bool { cancellation.isCancelled }

    // MARK: Where the data came from

    /// Set by a tool whose outputs are made of what it reads (the parts of a split file, a
    /// file put together again, an encoded or decoded one): they then carry the mark of
    /// coming from elsewhere that their source carries (`quarantine(of:)`: a file on a
    /// server, a download), as a copy of it would. A program that was split, sent and put
    /// together again is still checked by the system when it is first opened. Not set by
    /// tools that write something about their sources (a list of checksums).
    var carriesOrigin = false
    private var origin: Data?

    /// The mark outputs get, once a source that has one was opened.
    fileprivate var originMark: Data? {
        lock.lock()
        defer { lock.unlock() }
        return origin
    }

    private func noteOrigin(of url: URL, in provider: any FileSystemProvider) {
        guard carriesOrigin, originMark == nil, let mark = provider.quarantine(of: url) else { return }
        lock.lock()
        if origin == nil { origin = mark }
        lock.unlock()
    }

    func checkCancelled() throws {
        if cancellation.isCancelled { throw ToolError.cancelled }
    }

    // MARK: Progress

    func expect(bytes: Int64, items: Int) {
        lock.lock()
        bytesTotal = bytes
        itemsTotal = items
        lock.unlock()
        advance(0, force: true)
    }

    /// Shows what is being worked on. Safe from any thread.
    func show(_ lines: [String]) {
        lock.lock()
        self.lines = lines
        lock.unlock()
        advance(0, force: true)
    }

    /// Counts bytes (and finished files) and passes the state on, at most twenty times a
    /// second. Safe from any thread.
    func advance(_ bytes: Int64, items: Int = 0, force: Bool = false) {
        lock.lock()
        bytesDone += bytes
        itemsDone += items
        let due = force || Date().timeIntervalSince(lastReport) > 0.05
        lock.unlock()
        guard due else { return }
        // One report at a time; the state is read after the turn has come, so that a later
        // report never shows less than an earlier one. Every thread waits for its turn (a
        // paused job blocks inside the report of the thread whose turn it is, and the others
        // queue up behind it, so Pause stops all of them); a thread whose turn comes after
        // another has reported just now has nothing to add, unless it is forced.
        reportLock.lock()
        defer { reportLock.unlock() }
        lock.lock()
        if !force, Date().timeIntervalSince(lastReport) <= 0.05 {
            lock.unlock()
            return
        }
        lastReport = Date()
        let progress = JobProgress(
            lines: lines, itemsDone: itemsDone, itemsTotal: itemsTotal, bytesDone: bytesDone, bytesTotal: bytesTotal)
        lock.unlock()
        report(progress)
    }

    // MARK: Reading and writing

    func provider(for url: URL) throws -> any FileSystemProvider { try fileSystems.provider(for: url) }

    /// Hands a file to `body` block by block, counting the bytes as progress.
    func read(_ url: URL, counted: Bool = true, blockSize: Int = ToolRun.blockSize, _ body: (Data) throws -> Void)
        throws
    {
        try read(try openReader(url), counted: counted, blockSize: blockSize, body)
    }

    /// Opens a file for reading; hand it to `read(_:counted:_:)`, which closes it. Tools open
    /// their source before they create anything, so that a source that cannot be read costs
    /// no output file.
    func openReader(_ url: URL) throws -> any FileReader {
        do {
            // What a plugin still holds back for this file (an archive written after a delay) is written first.
            try fileSystems.flushPendingWrites(to: url, cancellation: cancellation)
            let provider = try provider(for: url)
            let reader = try provider.read(url, cancellation: cancellation)
            noteOrigin(of: url, in: provider)
            return reader
        } catch {
            try checkCancelled()
            throw error
        }
    }

    func read(
        _ reader: any FileReader, counted: Bool = true, blockSize: Int = ToolRun.blockSize,
        _ body: (Data) throws -> Void
    ) throws {
        defer { reader.close() }
        // A read blocked on a server ends as soon as the run is cancelled.
        let token = cancellation.interrupting(reader)
        defer { withExtendedLifetime(token) {} }
        do {
            // Every block is read and handled in a pool of its own: a long file would otherwise
            // keep all its blocks (and what the provider allocated around them) until it ends.
            while try autoreleasepool(invoking: { () throws -> Bool in
                guard let block = try reader.read(upToCount: blockSize), !block.isEmpty else { return false }
                try checkCancelled()
                try body(block)
                if counted { advance(Int64(block.count)) }
                return true
            }) {}
        } catch {
            // What the interruption made of the read is the cancel itself.
            try checkCancelled()
            throw error
        }
        try checkCancelled()
    }

    /// The whole of a small file (a checksum file, a `.crc` file). A file longer than `limit`
    /// is an error, never a silently shortened text.
    func contents(of url: URL, limit: Int = 256 << 20) throws -> Data {
        var data = Data()
        let reader = try openReader(url)
        defer { reader.close() }
        let token = cancellation.interrupting(reader)
        defer { withExtendedLifetime(token) {} }
        do {
            while try autoreleasepool(invoking: { () throws -> Bool in
                guard let block = try reader.read(upToCount: Self.blockSize), !block.isEmpty else { return false }
                data.append(block)
                return true
            }) {
                if data.count > limit {
                    throw ToolError.failed("\(url.lastPathComponent) is too large (more than \(limit >> 20) MiB).")
                }
            }
        } catch {
            try checkCancelled()
            throw error
        }
        return data
    }

    /// Opens a file for writing. When one is there already the user decides (or, with
    /// `autoRename`, the new file gets the name `name(2).ext`); nil means "skip this file".
    ///
    /// A file that replaces another is written under a temporary name. With `deferred` the
    /// replacement happens only when `transaction` ends well, and everything the run created
    /// is taken back when it does not, so a cancelled or failed run never leaves a mixture of
    /// old and new files and never touches what was there before.
    func create(_ url: URL, autoRename: Bool = false, deferred: Bool = false) throws -> ToolOutput? {
        var url = url
        let provider = try provider(for: url)
        var output: ToolOutput?
        if provider.item(at: url, cancellation: cancellation) != nil {
            var choice = autoRename ? ExistingFileChoice.autoRename : overwritesAll ? .overwrite : askExisting(url)
            if choice == .overwriteAll {
                overwritesAll = true
                choice = .overwrite
            }
            switch choice {
            case .cancel:
                cancellation.cancel()
                throw ToolError.cancelled

            case .skip:
                return nil

            case .autoRename:
                url = Self.freeName(for: url, provider: provider)

            case .overwrite, .overwriteAll:
                // The old file stays until the new one is complete: it is written under a
                // temporary name that replaces the old file when it is finished.
                let temporary = url.deletingLastPathComponent().appending(
                    name: ".\(url.lastPathComponent).afm-\(UUID().uuidString.prefix(8))")
                output = ToolOutput(
                    url: url, writer: try openWriter(temporary, in: provider), provider: provider, temporary: temporary,
                    cancellation: cancellation, deferred: deferred, origin: { [weak self] in self?.originMark })
            }
        }
        let created =
            try output
            ?? ToolOutput(
                url: url, writer: openWriter(url, in: provider), provider: provider, cancellation: cancellation,
                deferred: deferred, origin: { [weak self] in self?.originMark })
        if deferred { journal.append(created) }
        return created
    }

    /// Outputs made with `deferred`, in the order they were created. Job thread only.
    private var journal: [ToolOutput] = []

    /// Runs `body`. The outputs it made with `deferred: true` take the place of the files they
    /// replace when it has finished without an error; if it throws (or is cancelled), they are
    /// all removed again and the files that were there before are untouched.
    func transaction<Value>(_ body: () throws -> Value) throws -> Value {
        do {
            let value = try body()
            try checkCancelled()
            let outputs = journal
            journal = []
            do {
                for output in outputs { try output.commit() }
            } catch {
                outputs.forEach { $0.undo() }
                throw error
            }
            return value
        } catch {
            let outputs = journal
            journal = []
            outputs.forEach { $0.undo() }
            throw error
        }
    }

    private func openWriter(_ url: URL, in provider: any FileSystemProvider) throws -> any FileWriter {
        do {
            return try provider.write(url, cancellation: cancellation)
        } catch {
            try checkCancelled()
            throw error
        }
    }

    /// `name(2).ext`, `name(3).ext`, …: the first that is free (spec 08 › Decode).
    static func freeName(for url: URL, provider: any FileSystemProvider) -> URL {
        let (base, ext) = FileItem.split(url.lastPathComponent)
        var number = 2
        while true {
            let candidate = url.deletingLastPathComponent().appending(
                name: "\(base)(\(number))" + (ext.isEmpty ? "" : "." + ext))
            if provider.item(at: candidate) == nil { return candidate }
            number += 1
        }
    }

    /// Writes a small file in one go.
    @discardableResult
    func write(_ data: Data, to url: URL, deferred: Bool = false) throws -> URL? {
        guard let output = try create(url, deferred: deferred) else { return nil }
        do {
            try output.write(data)
            try output.finish()
        } catch {
            output.abandon()
            throw error
        }
        return output.url
    }

    /// Whether two locations are one file: the same place, or (on this Mac) the same device and
    /// inode, which sees through letter case, links and symbolic links in the path.
    static func isSameFile(_ first: URL, _ second: URL) -> Bool {
        first.isSameLocation(as: second) || first.isSameFile(as: second, followingLinks: true)
    }
}

/// A file being written. What is not finished is removed again, so a failed or cancelled
/// tool leaves no half-written files.
final class ToolOutput {
    let url: URL
    private let writer: any FileWriter
    private let provider: any FileSystemProvider
    /// Where the data goes while it replaces an existing file at `url`; nil when it is written to `url` itself.
    private let temporary: URL?
    /// Whether the replacement waits for `commit` (see `ToolRun.transaction`).
    private let deferred: Bool
    private enum State { case open, closed, done, undone }
    private var state = State.open
    private(set) var bytesWritten: Int64 = 0
    private let cancellation: CancellationFlag?
    /// Ties the writer to the run's cancel while the output lives, so a blocked write ends.
    private let interruption: AnyObject?
    /// The mark of coming from elsewhere that the finished file gets (see `ToolRun.carriesOrigin`), asked when it is finished.
    private let origin: () -> Data?

    init(
        url: URL, writer: any FileWriter, provider: any FileSystemProvider, temporary: URL? = nil,
        cancellation: CancellationFlag? = nil,
        deferred: Bool = false, origin: @escaping () -> Data? = { nil }
    ) {
        self.origin = origin
        self.url = url
        self.writer = writer
        self.provider = provider
        self.temporary = temporary
        self.cancellation = cancellation
        self.deferred = deferred
        interruption = cancellation?.interrupting(writer)
    }

    private var partial: URL { temporary ?? url }

    func write(_ data: Data) throws {
        do {
            try writer.write(data)
        } catch {
            if cancellation?.isCancelled == true { throw ToolError.cancelled }
            throw error
        }
        bytesWritten += Int64(data.count)
    }

    /// Completes the file. One that replaces another takes its place now, or, when the output is
    /// deferred, at `commit`.
    func finish() throws {
        guard state == .open else { return }
        do {
            try writer.close(attributes: FileAttributes())
            // Before the file appears under its name. A file system that keeps no such mark does without.
            if let mark = origin() { try? provider.setQuarantine(mark, of: partial) }
            if let temporary, !deferred { try provider.move(temporary, to: url, replacing: true) }
        } catch {
            state = .undone
            try? provider.remove(partial)
            if cancellation?.isCancelled == true { throw ToolError.cancelled }
            throw error
        }
        state = deferred && temporary != nil ? .closed : .done
    }

    /// Puts a finished, deferred output in the place of the file it replaces.
    func commit() throws {
        guard state == .closed, let temporary else { return }
        do {
            try provider.move(temporary, to: url, replacing: true)
            state = .done
        } catch {
            state = .undone
            try? provider.remove(temporary)
            throw error
        }
    }

    /// Drops an output that is not finished.
    func abandon() {
        guard state == .open else { return }
        state = .undone
        try? writer.close(attributes: FileAttributes())
        try? provider.remove(partial)
    }

    /// Takes back what this output made: the partial or waiting temporary, or a file it created
    /// anew. A file it replaced is not touched; that happens only at `commit`.
    func undo() {
        switch state {
        case .open:
            abandon()

        case .closed:
            state = .undone
            if let temporary { try? provider.remove(temporary) }

        case .done:
            state = .undone
            if temporary == nil { try? provider.remove(url) }

        case .undone:
            break
        }
    }

    deinit { abandon() }
}
