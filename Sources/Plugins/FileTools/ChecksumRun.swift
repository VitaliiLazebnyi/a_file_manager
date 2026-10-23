import AFMKernel
import Foundation

/// Hashing many files, and the two checksum tools built on it.
///
/// **Threading.** Everything here blocks and runs on a job's thread. The files are hashed on
/// all cores at once, each file as a stream of blocks on one of them; the results come back
/// in the order of the input.
internal enum ChecksumRun {
    /// How many files are being hashed at this moment.
    ///
    /// Unchecked `Sendable`: `active` is guarded by `lock`.
    private final class BusyFiles: @unchecked Sendable {
        /// Guards `active`.
        private let lock = NSLock()
        /// The files being hashed (under `lock`).
        private var active = 0

        /// The files being hashed now.
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return active
        }

        /// A file starts being hashed.
        func enter() {
            lock.lock()
            active += 1
            lock.unlock()
        }

        /// A file is done.
        func leave() {
            lock.lock()
            active -= 1
            lock.unlock()
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The choices of the Create checksums dialog.
    internal struct CreateOptions: Equatable {
        /// The method of the checksums.
        internal var method = ChecksumMethod.crc32
        /// A checksum file of its own for each file.
        internal var separatePerFile = false
        /// A checksum file of its own for each folder, in that folder.
        internal var separatePerFolder = false
        /// The byte-order mark is written always, not only where the Windows format needs it.
        internal var alwaysUTF8 = false
        /// LF and `/` (else CRLF and `\`, as the Windows original writes).
        internal var unixFormat = true
    }

    /// One file to hash: with which methods, and the digest it should have, if known.
    internal struct HashRequest: Sendable {
        /// The file.
        internal var url: URL
        /// The methods, the likeliest first.
        internal var methods: [ChecksumMethod]
        /// The digest the file should have (lower-case hex): with several methods the others are computed only
        /// when the first does not give it.
        internal var expected: String?
    }

    /// The pieces BLAKE3 is fed when it must not spread the work: smaller than the 16 chunks (16 KB)
    /// from which it uses more than one thread.
    internal static let serialPiece = 8 << 10

    /// A CRC32 in square brackets, as file names carry it.
    internal static let bracketedChecksum = try? NSRegularExpression(pattern: #"\[([0-9A-Fa-f]{8})\]"#)

    /// The digests of each file for each of its methods, or the error that stopped it.
    ///
    /// With an `expected` digest and several methods of that length only the first (the likeliest)
    /// is computed in a first pass over the file; the others, all in one further pass, only when it
    /// does not match. The digests of methods not computed are empty.
    internal static func digests(of files: [HashRequest], run: ToolRun) -> [Result<[[UInt8]], any Error>] {
        let busy = BusyFiles()
        return Parallel.map(files) { file -> Result<[[UInt8]], any Error> in
            busy.enter()
            defer { busy.leave() }
            return Result { try digests(of: file, run: run, busy: busy) }
        }
    }

    /// The digests of each file for each of its methods, or the error that stopped it, all computed.
    internal static func digests(of files: [(url: URL, methods: [ChecksumMethod])], run: ToolRun) -> [Result<
        [[UInt8]], any Error
    >] {
        digests(of: files.map { file in HashRequest(url: file.url, methods: file.methods, expected: nil) }, run: run)
    }

    /// Whether BLAKE3 may spread a block over the cores now: when fewer files than cores are
    /// being hashed, so that cores are left over.
    internal static func spreadsBLAKE3(filesInProgress: Int, cores: Int) -> Bool {
        filesInProgress < cores
    }

    /// Gives `block` to `hasher`; to a BLAKE3 hasher that must not spread it, piece by piece.
    internal static func feed(_ hasher: any StreamHasher, _ block: Data, spread: Bool) {
        guard hasher is BLAKE3Hasher, !spread, block.count > serialPiece else {
            hasher.update(block)
            return
        }
        var start = block.startIndex
        while start < block.endIndex {
            let end = min(block.endIndex, start + serialPiece)
            hasher.update(block[start..<end])
            start = end
        }
    }

    /// The files below the operands, in listing order; folders are walked recursively and
    /// links to folders are not followed.
    internal static func files(below operands: [FileItem], run: ToolRun) throws -> [FileItem] {
        var files: [FileItem] = []
        for operand in operands {
            try run.checkCancelled()
            if operand.isRealDirectory {
                let items = try run.provider(for: operand.url)
                    .list(
                        operand.url,
                        showHidden: true,
                        cancellation: run.cancellation
                    )
                files += try self.files(below: Sorter.sorted(items, numeric: true, byName: \.name), run: run)
            } else if !operand.isDirectory {
                files.append(operand)
            }
        }
        return files
    }

    /// The checksum file a file is listed in.
    internal static func outputURL(for file: FileItem, target: URL, options: CreateOptions) -> URL {
        if options.separatePerFolder {
            // One file per folder, written into that folder; the target path is not used.
            let folder = file.url.deletingLastPathComponent()
            let folderName =
                folder.lastPathComponent.isEmpty || folder.lastPathComponent == "/"
                ? "checksums" : folder.lastPathComponent
            return folder.appending(name: folderName + "." + options.method.fileExtension)
        }
        if options.separatePerFile {
            return target.deletingLastPathComponent()
                .appending(
                    name: separateName(for: file.name, pattern: target.lastPathComponent, method: options.method)
                )
        }
        return target
    }

    /// How a file is named inside a checksum file in `folder`: by its path from there when it
    /// lies below, else by its full path (a bare name would be ambiguous and lead nowhere).
    internal static func name(of file: URL, in folder: URL) -> String {
        guard file.isInside(folder) else {
            return file.path
        }
        return String(file.path.dropFirst(folder.path.count).drop { character in character == "/" })
    }

    /// The name of the checksum file of one file, from a pattern with `*`: `*.*.sfv` adds
    /// the extension to the whole name, `*.sfv` puts it in place of the file's own.
    internal static func separateName(for fileName: String, pattern: String, method: ChecksumMethod) -> String {
        let stars = pattern.filter { character in character == "*" }.count
        let patternExtension = FileItem.split(pattern).ext
        let ext = patternExtension.isEmpty || patternExtension.contains("*") ? method.fileExtension : patternExtension
        return (stars >= 2 ? fileName : FileItem.split(fileName).base) + "." + ext
    }

    /// The digests of one file: with an expected digest and several methods, first only the first.
    private static func digests(of file: HashRequest, run: ToolRun, busy: BusyFiles) throws -> [[UInt8]] {
        let found: [[UInt8]]
        if let expected = file.expected, file.methods.count > 1 {
            let first = try hash(file.url, [file.methods[0]], counted: true, run: run, busy: busy)
            if first[0].hex == expected {
                found = first + Array(repeating: [], count: file.methods.count - 1)
            } else {
                // The second pass is not counted: the bar has been to the end of this file already.
                found =
                    first + (try hash(file.url, Array(file.methods.dropFirst()), counted: false, run: run, busy: busy))
            }
        } else {
            found = try hash(file.url, file.methods, counted: true, run: run, busy: busy)
        }
        run.advance(0, items: 1, force: false)
        return found
    }

    /// Hashes the file with every one of `methods` in one pass over it; `counted` moves the progress bar.
    private static func hash(
        _ url: URL,
        _ methods: [ChecksumMethod],
        counted: Bool,
        run: ToolRun,
        busy: BusyFiles
    ) throws -> [[UInt8]] {
        let hashers = methods.map { method in method.makeHasher() }
        // Several methods in one pass over the file: each block goes to every
        // hasher at the same time, each on its own thread.
        // BLAKE3 spreads a block over the cores itself, which pays only for large ones.
        let blockSize = methods.contains(.blake3) ? 4 << 20 : ToolRun.blockSize
        try run.read(url, counted: counted, blockSize: blockSize) { block in
            // BLAKE3 spreads a large block over the cores on its own; while the files themselves
            // keep every core busy that only makes more threads than cores, so it is fed pieces too
            // small to be spread then (the digest is the same).
            let spread = spreadsBLAKE3(
                filesInProgress: busy.count,
                cores: ProcessInfo.processInfo.activeProcessorCount
            )
            if hashers.count > 1 {
                _ = Parallel.map(hashers) { hasher in feed(hasher, block, spread: spread) }
            } else {
                for hasher in hashers {
                    feed(hasher, block, spread: spread)
                }
            }
        }
        return hashers.map { hasher in hasher.finish() }
    }
}
