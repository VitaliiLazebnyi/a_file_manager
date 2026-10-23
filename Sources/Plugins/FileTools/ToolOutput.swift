import AFMKernel
import Foundation

/// A file being written.
///
/// What is not finished is removed again, so a failed or cancelled tool leaves no half-written
/// files.
internal final class ToolOutput {
    /// How far the output is.
    private enum State {
        /// Finished, waiting under its temporary name for `commit`.
        case closed
        /// Finished and in its place.
        case done
        /// Being written.
        case open
        /// Taken back: nothing of it is left.
        case undone
    }

    /// Where the file is to be.
    internal let url: URL
    /// What writes the data.
    private let writer: any FileWriter
    /// The file system of the file.
    private let provider: any FileSystemProvider
    /// Where the data goes while it replaces an existing file at `url`; nil when it is written to `url` itself.
    private let temporary: URL?
    /// Whether the replacement waits for `commit` (see `ToolRun.transaction`).
    private let deferred: Bool
    /// How far the output is.
    private var state = State.open
    /// The bytes written so far.
    internal private(set) var bytesWritten: Int64 = 0
    /// The run's cancel, which ends a blocked write; nil without one.
    private let cancellation: CancellationFlag?
    /// Ties the writer to the run's cancel while the output lives, so a blocked write ends.
    private let interruption: AnyObject?
    /// The mark of coming from elsewhere that the finished file gets (see `ToolRun.carriesOrigin`), asked when
    /// it is finished.
    private let origin: () -> Data?

    /// Where the data is written: the temporary, or the file itself.
    private var partial: URL { temporary ?? url }

    /// An output to `url` written through `writer`, to `temporary` first when it replaces a file.
    ///
    /// With `deferred` it takes the place of the file it replaces only at `commit`.
    internal init(
        url: URL,
        writer: any FileWriter,
        provider: any FileSystemProvider,
        temporary: URL?,
        cancellation: CancellationFlag?,
        deferred: Bool,
        origin: @escaping () -> Data?
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

    /// Writes the next part of the file; a write the cancel ended throws `ToolError.cancelled`.
    internal func write(_ data: Data) throws {
        do {
            try writer.write(data)
        } catch {
            if cancellation?.isCancelled == true {
                throw ToolError.cancelled
            }
            throw error
        }
        bytesWritten += Int64(data.count)
    }

    /// Completes the file.
    ///
    /// One that replaces another takes its place now, or, when the output is deferred, at `commit`.
    internal func finish() throws {
        guard state == .open else {
            return
        }
        do {
            try writer.close(attributes: FileAttributes())
            // Before the file appears under its name. A file system that keeps no such mark does without.
            if let mark = origin() {
                try? provider.setQuarantine(mark, of: partial)
            }
            if let temporary, !deferred {
                try provider.move(temporary, to: url, replacing: true)
            }
        } catch {
            state = .undone
            try? provider.remove(partial)
            if cancellation?.isCancelled == true {
                throw ToolError.cancelled
            }
            throw error
        }
        state = deferred && temporary != nil ? .closed : .done
    }

    /// Puts a finished, deferred output in the place of the file it replaces.
    internal func commit() throws {
        guard state == .closed, let temporary else {
            return
        }
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
    internal func abandon() {
        guard state == .open else {
            return
        }
        state = .undone
        try? writer.close(attributes: FileAttributes())
        try? provider.remove(partial)
    }

    /// Takes back what this output made: the partial or waiting temporary, or a file it created
    /// anew.
    ///
    /// A file it replaced is not touched; that happens only at `commit`.
    internal func undo() {
        switch state {
        case .open:
            abandon()

        case .closed:
            state = .undone
            if let temporary {
                try? provider.remove(temporary)
            }

        case .done:
            state = .undone
            if temporary == nil {
                try? provider.remove(url)
            }

        case .undone:
            break
        }
    }

    deinit { abandon() }
}
