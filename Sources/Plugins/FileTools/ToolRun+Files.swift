import AFMKernel
import Foundation

/// Reading and writing: sources read block by block, outputs written whole or not at all.
extension ToolRun {
    /// The file system of a location.
    internal func provider(for url: URL) throws -> any FileSystemProvider { try fileSystems.provider(for: url) }

    /// Hands a file to `body` block by block, of `blockSize` bytes; with `counted` the bytes are progress.
    internal func read(_ url: URL, counted: Bool, blockSize: Int, _ body: (Data) throws -> Void) throws {
        try read(try openReader(url), counted: counted, blockSize: blockSize, body)
    }

    /// Opens a file for reading; hand it to `read(_:counted:blockSize:_:)`, which closes it.
    ///
    /// Tools open their source before they create anything, so that a source that cannot be read
    /// costs no output file.
    internal func openReader(_ url: URL) throws -> any FileReader {
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

    /// Hands what `reader` reads to `body` block by block, of `blockSize` bytes, and closes it; with `counted`
    /// the bytes are progress.
    internal func read(_ reader: any FileReader, counted: Bool, blockSize: Int, _ body: (Data) throws -> Void) throws {
        defer { reader.close() }
        // A read blocked on a server ends as soon as the run is cancelled.
        let token = cancellation.interrupting(reader)
        defer {
            withExtendedLifetime(token) {
                // The reader can be interrupted up to here.
            }
        }
        do {
            // Every block is read and handled in a pool of its own: a long file would otherwise
            // keep all its blocks (and what the provider allocated around them) until it ends.
            var hasMore = true
            while hasMore {
                hasMore = try autoreleasepool { () throws -> Bool in
                    guard let block = try reader.read(upToCount: blockSize), !block.isEmpty else {
                        return false
                    }
                    try checkCancelled()
                    try body(block)
                    if counted {
                        advance(Int64(block.count), items: 0, force: false)
                    }
                    return true
                }
            }
        } catch {
            // What the interruption made of the read is the cancel itself.
            try checkCancelled()
            throw error
        }
        try checkCancelled()
    }

    /// The whole of a small file (a checksum file, a `.crc` file).
    ///
    /// A file longer than `limit` is an error, never a silently shortened text.
    internal func contents(of url: URL, limit: Int) throws -> Data {
        var data = Data()
        let reader = try openReader(url)
        defer { reader.close() }
        let token = cancellation.interrupting(reader)
        defer {
            withExtendedLifetime(token) {
                // The reader can be interrupted up to here.
            }
        }
        do {
            var hasMore = true
            while hasMore {
                hasMore = try autoreleasepool { () throws -> Bool in
                    guard let block = try reader.read(upToCount: Self.blockSize), !block.isEmpty else {
                        return false
                    }
                    data.append(block)
                    return true
                }
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

    /// Opens a file for writing.
    ///
    /// When one is there already the user decides (or, with `autoRename`, the new file gets the
    /// name `name(2).ext`); nil means "skip this file".
    ///
    /// A file that replaces another is written under a temporary name. With `deferred` the
    /// replacement happens only when `transaction` ends well, and everything the run created
    /// is taken back when it does not, so a cancelled or failed run never leaves a mixture of
    /// old and new files and never touches what was there before.
    internal func create(_ url: URL, autoRename: Bool, deferred: Bool) throws -> ToolOutput? {
        var target = url
        let provider = try provider(for: target)
        var temporary: URL?
        if provider.item(at: target, cancellation: cancellation) != nil {
            var choice = autoRename ? ExistingFileChoice.autoRename : overwritesAll ? .overwrite : askExisting(target)
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
                target = Self.freeName(for: target, provider: provider)

            case .overwrite, .overwriteAll:
                // The old file stays until the new one is complete: it is written under a
                // temporary name that replaces the old file when it is finished.
                temporary = target.deletingLastPathComponent()
                    .appending(name: ".\(target.lastPathComponent).afm-\(UUID().uuidString.prefix(8))")
            }
        }
        let created = ToolOutput(
            url: target,
            writer: try openWriter(temporary ?? target, in: provider),
            provider: provider,
            temporary: temporary,
            cancellation: cancellation,
            deferred: deferred
        ) { [weak self] in
            self?.originMark
        }
        if deferred {
            journal.append(created)
        }
        return created
    }

    /// Runs `body`.
    ///
    /// The outputs it made with `deferred: true` take the place of the files they replace when it
    /// has finished without an error; if it throws (or is cancelled), they are all removed again
    /// and the files that were there before are untouched.
    internal func transaction<Value>(_ body: () throws -> Value) throws -> Value {
        do {
            let value = try body()
            try checkCancelled()
            let outputs = journal
            journal = []
            do {
                for output in outputs {
                    try output.commit()
                }
            } catch {
                for output in outputs {
                    output.undo()
                }
                throw error
            }
            return value
        } catch {
            let outputs = journal
            journal = []
            for output in outputs {
                output.undo()
            }
            throw error
        }
    }

    /// Opens the writer of a new file; a failure the cancel caused throws `ToolError.cancelled`.
    private func openWriter(_ url: URL, in provider: any FileSystemProvider) throws -> any FileWriter {
        do {
            return try provider.write(url, cancellation: cancellation)
        } catch {
            try checkCancelled()
            throw error
        }
    }

    /// Writes a small file in one go; nil when the user chose to skip it.
    @discardableResult
    internal func write(_ data: Data, to url: URL, deferred: Bool) throws -> URL? {
        guard let output = try create(url, autoRename: false, deferred: deferred) else {
            return nil
        }
        do {
            try output.write(data)
            try output.finish()
        } catch {
            output.abandon()
            throw error
        }
        return output.url
    }
}
