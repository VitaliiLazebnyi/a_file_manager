import AFMContracts
public import AFMKernel
public import Foundation

/// Two files as the compare window shows them.
public enum CompareContent: Sendable {
    case none
    /// `width` is the longest line in UTF-16 units, for the width of the panes.
    case text(left: TextDocument, right: TextDocument, diff: TextDiff, width: Int)
    case binary(left: Data, right: Data, diff: BinaryDiff)

    var isNone: Bool {
        if case .none = self { return true }
        return false
    }
}

/// The outcome of loading and comparing two files.
public struct ComparedFiles: Sendable {
    public var isIdentical = false
    public var content = CompareContent.none
    /// Why there is nothing to show: a file is missing, unreadable, or too large.
    public var message: String?
    public var wasCancelled = false
    /// The two files as they were when loaded (nil for a link, which is saved where it leads): what
    /// saving checks the files against, so that a file changed by someone else meanwhile is not overwritten.
    public var leftItem: FileItem?
    public var rightItem: FileItem?
}

/// Reads two files through their file systems and compares them (spec 09 › Loading, mode and
/// encodings). UI-free.
///
/// **Threading.** Everything here blocks and belongs on a background thread. The two files
/// are read at the same time. Large files of the same size are first checked for being
/// identical without loading them: on local volumes several threads each compare their own
/// stretch of the two files with their own readers, so the answer comes at the speed of all
/// cores and of the disk; elsewhere (a server, an archive), where jumping around in a file may
/// be costly, the two are read once side by side.
public enum CompareLoader {
    /// Files of the same size from here on are checked for identity before being loaded.
    public static let quickCheckFrom: Int64 = 16 * 1_024 * 1_024
    /// Larger files are not loaded for display; only whether they are identical is told.
    public static let loadLimit: Int64 = 128 * 1_024 * 1_024
    public static let stretch = 4 * 1_024 * 1_024

    public static func load(
        left: URL, right: URL, forceBinary: Bool = false, options: DiffOptions = DiffOptions(), bytesPerLine: Int = 16,
        fileSystems: FileSystemRegistry, cancellation: CancellationFlag = CancellationFlag()
    ) -> ComparedFiles {
        var result = ComparedFiles()
        let items = Parallel.map([left, right]) { url in
            (try? fileSystems.provider(for: url))?.item(at: url, cancellation: cancellation)
        }
        if cancellation.isCancelled {
            result.wasCancelled = true
            return result
        }
        var files: [FileItem] = []
        for (url, item) in zip([left, right], items) {
            guard let item, !item.isDirectory else {
                result.message = "\(fileSystems.displayPath(url)) is not a file."
                return result
            }
            files.append(item)
        }
        let (leftItem, rightItem) = (files[0], files[1])
        result.leftItem = leftItem.isSymlink ? nil : leftItem
        result.rightItem = rightItem.isSymlink ? nil : rightItem
        do {
            if leftItem.size == rightItem.size, leftItem.size >= quickCheckFrom {
                guard
                    let same = try identical(
                        left, right, size: leftItem.size, fileSystems: fileSystems, cancellation: cancellation)
                else {
                    result.wasCancelled = true
                    return result
                }
                if same {
                    result.isIdentical = true
                    return result
                }
            }
            guard max(leftItem.size, rightItem.size) <= loadLimit else {
                result.message =
                    "The two files are different. They are too large to be shown side by side "
                    + "(more than \(Format.shortSize(loadLimit)))."
                return result
            }
            let loaded = Parallel.map([left, right]) { url in
                Result { try read(url, fileSystems: fileSystems, cancellation: cancellation) }
            }
            let (first, second) = (try loaded[0].get(), try loaded[1].get())
            guard !cancellation.isCancelled else {
                result.wasCancelled = true
                return result
            }
            result.isIdentical = first == second
            if forceBinary || TextDocument.looksBinary(first) || TextDocument.looksBinary(second) {
                result.content = .binary(
                    left: first, right: second,
                    diff: BinaryDiff.compute(
                        left: first, right: second, bytesPerLine: bytesPerLine, cancellation: cancellation))
            } else {
                let documents = Parallel.map([first, second]) { TextDocument(data: $0) }
                result.content = text(
                    left: documents[0], right: documents[1], options: options, cancellation: cancellation)
            }
            result.wasCancelled = cancellation.isCancelled
        } catch {
            // A read that was ended by the cancel is no error to show.
            if cancellation.isCancelled {
                result.wasCancelled = true
            } else {
                result.message = error.localizedDescription
            }
        }
        return result
    }

    /// Lays two texts side by side.
    public static func text(
        left: TextDocument, right: TextDocument, options: DiffOptions, anchors: [(left: Int, right: Int)] = [],
        cancellation: CancellationFlag? = nil
    ) -> CompareContent {
        let diff = TextDiff.compute(
            left: left.lines, right: right.lines, options: options, anchors: anchors, cancellation: cancellation)
        let widths = Parallel.map([left.lines, right.lines]) { lines in
            lines.reduce(0) { max($0, $1.text.utf16.count) }
        }
        return .text(left: left, right: right, diff: diff, width: max(widths[0], widths[1]))
    }

    static func read(_ url: URL, fileSystems: FileSystemRegistry, cancellation: CancellationFlag) throws -> Data {
        // What a plugin still holds back for this file (an archive written after a delay) is written first.
        try fileSystems.flushPendingWrites(to: url, cancellation: cancellation)
        let reader = try fileSystems.provider(for: url).read(url, cancellation: cancellation)
        defer { reader.close() }
        let token = cancellation.interrupting(reader)
        defer { withExtendedLifetime(token) {} }
        var data = Data()
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard !cancellation.isCancelled, let block = try reader.read(upToCount: 1 << 20), !block.isEmpty else {
                return false
            }
            data.append(block)
            return true
        }) {}
        return data
    }

    // MARK: Identical?

    /// Whether two files of `size` bytes have the same content; nil when cancelled.
    public static func identical(
        _ first: URL, _ second: URL, size: Int64, fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag = CancellationFlag(), stretch: Int = Self.stretch
    ) throws -> Bool? {
        if cancellation.isCancelled { return nil }
        try fileSystems.flushPendingWrites(to: first, cancellation: cancellation)
        try fileSystems.flushPendingWrites(to: second, cancellation: cancellation)
        let systems = [try fileSystems.provider(for: first), try fileSystems.provider(for: second)]
        let isLocal = zip(systems, [first, second]).allSatisfy {
            $0.volume(of: $1, cancellation: cancellation)?.isLocal ?? false
        }
        // (A size is what a file system says; a server may say anything.)
        let stretches = Int(max(0, size).addingSaturated(Int64(stretch) - 1) / Int64(stretch))
        guard isLocal, stretches > 1 else {
            do {
                return try sameStream(first, second, systems: systems, cancellation: cancellation)
            } catch {
                // A read that the cancel ended is the cancel, not a failure.
                if cancellation.isCancelled { return nil }
                throw error
            }
        }

        // Shared by the workers, behind the lock: the next stretch to take and what was found.
        let lock = NSLock()
        /// Guarded by `lock`.
        nonisolated(unsafe) var next = 0
        /// Guarded by `lock`.
        nonisolated(unsafe) var differs = false
        /// Guarded by `lock`.
        nonisolated(unsafe) var failure: (any Error)?
        @Sendable func take() -> Int? {
            lock.lock()
            defer { lock.unlock() }
            guard !differs, failure == nil, next < stretches, !cancellation.isCancelled else { return nil }
            next += 1
            return next - 1
        }
        // On the shared pool of `Parallel`, which starts more threads for workers that wait on a disk that does not answer;
        // `concurrentPerform` would have its few threads stuck there.
        _ = Parallel.map(Array(0..<min(stretches, ProcessInfo.processInfo.activeProcessorCount))) { _ in
            // Every worker has its own two readers and moves them to the stretches it takes.
            var readers: [any FileReader] = []
            var tokens: [AnyObject] = []
            defer {
                readers.forEach { $0.close() }
                withExtendedLifetime(tokens) {}
            }
            do {
                for (system, url) in zip(systems, [first, second]) {
                    let reader = try system.read(url, cancellation: cancellation)
                    readers.append(reader)
                    tokens.append(cancellation.interrupting(reader))
                }
                while let index = take() {
                    let offset = UInt64(index) * UInt64(stretch)
                    let count = Int(min(Int64(stretch), size - Int64(offset)))
                    try autoreleasepool {
                        try readers.forEach { try $0.seek(to: offset) }
                        if try exactly(count, from: readers[0]) != exactly(count, from: readers[1]) {
                            lock.lock()
                            differs = true
                            lock.unlock()
                        }
                    }
                }
            } catch {
                lock.lock()
                failure = failure ?? error
                lock.unlock()
            }
        }
        if let failure, !cancellation.isCancelled { throw failure }
        if differs { return false }
        return cancellation.isCancelled ? nil : true
    }

    /// Reads until `count` bytes are there or the file ends; readers may hand out less at a time.
    private static func exactly(_ count: Int, from reader: any FileReader) throws -> Data {
        var data = Data()
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard data.count < count, let block = try reader.read(upToCount: count - data.count), !block.isEmpty else {
                return false
            }
            data.append(block)
            return true
        }) {}
        return data
    }

    /// Reads the two files once, side by side, and stops at the first difference.
    private static func sameStream(
        _ first: URL, _ second: URL, systems: [any FileSystemProvider], cancellation: CancellationFlag
    ) throws -> Bool? {
        var readers: [any FileReader] = []
        var tokens: [AnyObject] = []
        defer {
            readers.forEach { $0.close() }
            withExtendedLifetime(tokens) {}
        }
        for (system, url) in zip(systems, [first, second]) {
            let reader = try system.read(url, cancellation: cancellation)
            readers.append(reader)
            tokens.append(cancellation.interrupting(reader))
        }
        var verdict: Bool?
        while verdict == nil, !cancellation.isCancelled {
            verdict = try autoreleasepool {
                let blocks = [try exactly(1 << 20, from: readers[0]), try exactly(1 << 20, from: readers[1])]
                if blocks[0] != blocks[1] { return false }
                return blocks[0].isEmpty ? true : nil
            }
        }
        // Nil when cancelled before the end.
        return verdict
    }

    // MARK: Saving

    /// Why a file is not saved.
    enum SaveError: LocalizedError {
        case changedOnDisk(String)
        case notRepresentable(String, TextEncoding)
        case invalidSequences(String, TextEncoding)
        case sameFile(String)

        var errorDescription: String? {
            switch self {
            case .changedOnDisk(let name):
                return
                    "\(name) was changed by someone else after it was loaded. It is not overwritten; compare the files again."

            case .notRepresentable(let name, let encoding):
                return
                    "\(name) has characters that \(encoding.name) cannot hold, so it is not saved (that would turn them into question marks)."

            case .invalidSequences(let name, let encoding):
                return
                    "\(name) has bytes that are not valid \(encoding.name). Saving would change them, so it is not saved."

            case .sameFile(let name):
                return "Both sides are the same file (\(name)) and both were edited, so it is not saved."
            }
        }
    }

    /// Whether two locations are one file: the same place, or on this Mac the same device and inode.
    static func isSameFile(_ first: URL, _ second: URL) -> Bool {
        first.isSameLocation(as: second) || first.isSameFile(as: second, followingLinks: true)
    }

    /// Replaces the file at `url` with `data`: the new content is written next to it under a
    /// temporary name and moved over it, so the file is never half written. `expected` is how the
    /// file looked when it was loaded: a file that is different now (changed by someone else) is
    /// not overwritten. Returns the file as it is now.
    ///
    /// A local file with several hard links is written in place instead: a rename would give
    /// this name a file of its own and leave the other names with the old content.
    @discardableResult
    public static func replace(_ url: URL, with data: Data, expected: FileItem? = nil, fileSystems: FileSystemRegistry)
        throws -> FileItem?
    {
        var url = url
        let fileSystem = try fileSystems.provider(for: url)
        var existing = fileSystem.item(at: url)
        // A file opened through a link is saved where the link leads; the link itself stays.
        if existing?.isSymlink == true, url.isFileURL {
            url = url.resolvingSymlinksInPath()
            existing = fileSystem.item(at: url)
        }
        if let expected, let current = existing, !expected.isSymlink,
            current.size != expected.size || abs(current.modified.timeIntervalSince(expected.modified)) > 0.001
        {
            throw SaveError.changedOnDisk(url.lastPathComponent)
        }
        if existing != nil, url.isFileURL, try writeInPlaceIfLinked(url, data, fileSystem) {
            return fileSystem.item(at: url)
        }
        let name = url.lastPathComponent
        let temporary = url.deletingLastPathComponent().appending(name: ".\(name).afm-save")
        try? fileSystem.remove(temporary)
        let writer = try fileSystem.write(temporary)
        /// Set once the old file is out of the way and could not be put back: the temporary is then the only copy of the new text.
        var mustKeepTemporary = false
        do {
            for start in stride(from: 0, to: data.count, by: 1 << 20) {
                try writer.write(data.subdata(in: start..<min(start + (1 << 20), data.count)))
            }
            try writer.close(attributes: FileAttributes(modified: Date(), permissions: existing?.permissions))
            if existing != nil, url.isFileURL { carryOverMetadata(from: url, to: temporary) }
            do {
                try fileSystem.move(temporary, to: url, replacing: true)
            } catch  where existing != nil {
                // A file system that cannot replace in one step: the old file is moved aside, not
                // deleted, until the new one is in its place; if that fails the old one comes back.
                let aside = url.deletingLastPathComponent().appending(name: ".\(name).afm-old")
                try? fileSystem.remove(aside)
                try fileSystem.move(url, to: aside, replacing: false)
                do {
                    try fileSystem.move(temporary, to: url, replacing: false)
                } catch {
                    do {
                        try fileSystem.move(aside, to: url, replacing: false)
                    } catch {
                        // Neither is under the name: both are kept where they are.
                        mustKeepTemporary = true
                    }
                    throw error
                }
                try? fileSystem.remove(aside)
            }
        } catch {
            if !mustKeepTemporary { try? fileSystem.remove(temporary) }
            throw error
        }
        return fileSystem.item(at: url)
    }

    /// Writes into the file itself when it has more than one hard link; false when it has not.
    ///
    /// The file system continues the file from its start: it opens it without waiting, refuses
    /// anything but a regular file there (a pipe that took the name since the look), and cuts it
    /// through the descriptor it writes with.
    private static func writeInPlaceIfLinked(_ url: URL, _ data: Data, _ fileSystem: any FileSystemProvider) throws
        -> Bool
    {
        var st = stat()
        guard stat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink > 1 else { return false }
        let writer = try fileSystem.append(to: url, at: 0, cancellation: CancellationFlag())
        for start in stride(from: 0, to: data.count, by: 1 << 20) {
            try writer.write(data.subdata(in: start..<min(start + (1 << 20), data.count)))
        }
        try writer.close(attributes: FileAttributes(modified: Date()))
        return true
    }

    /// What a rename over the file would lose: extended attributes (tags, quarantine, Finder
    /// info), ACLs, owner and creation date. Best effort; the data is what counts.
    private static func carryOverMetadata(from original: URL, to copy: URL) {
        _ = copyfile(original.path, copy.path, nil, copyfile_flags_t(COPYFILE_METADATA))
        // The copying of the metadata also copied the old modification date; the file is saved now.
        var values = URLResourceValues()
        values.creationDate = (try? original.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        values.contentModificationDate = Date()
        var target = copy
        try? target.setResourceValues(values)
    }
}
