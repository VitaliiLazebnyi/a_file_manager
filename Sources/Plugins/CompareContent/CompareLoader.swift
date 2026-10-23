import AFMContracts
public import AFMKernel
public import Foundation

/// Reads two files through their file systems and compares them (spec 09 › Loading, mode and
/// encodings).
///
/// UI-free.
///
/// **Threading.** Everything here blocks and belongs on a background thread. The two files
/// are read at the same time. Large files of the same size are first checked for being
/// identical without loading them: on local volumes several threads each compare their own
/// stretch of the two files with their own readers, so the answer comes at the speed of all
/// cores and of the disk; elsewhere (a server, an archive), where jumping around in a file may
/// be costly, the two are read once side by side.
public enum CompareLoader {
    /// Which files are checked for being identical before they are loaded, and which are too large to be shown.
    public struct Limits: Sendable {
        /// The usual limits: 16 MB and 128 MB.
        public static let standard = Self(quickCheckFrom: 16 * 1_024 * 1_024, loadLimit: 128 * 1_024 * 1_024)

        /// Files of the same size from here on are checked for identity before being loaded.
        public var quickCheckFrom: Int64
        /// Larger files are not loaded for display; only whether they are identical is told.
        public var loadLimit: Int64

        /// Limits of these sizes, in bytes.
        public init(quickCheckFrom: Int64, loadLimit: Int64) {
            self.quickCheckFrom = quickCheckFrom
            self.loadLimit = loadLimit
        }
    }

    /// How much of a large local file one worker compares at a time.
    public static let stretch = 4 * 1_024 * 1_024

    /// Loads the two files and compares them: as text, or byte by byte when `forceBinary` is set or either file
    /// looks binary (then `bytesPerLine` bytes make a row).
    ///
    /// Blocks; call it on a background thread. Never throws: what went wrong is the result's message, and a
    /// cancel through `cancellation` is its `wasCancelled`.
    public static func load(
        left: URL,
        right: URL,
        fileSystems: FileSystemRegistry,
        forceBinary: Bool = false,
        options: DiffOptions = DiffOptions(),
        bytesPerLine: Int = 16,
        cancellation: CancellationFlag = CancellationFlag(),
        limits: Limits = .standard
    ) -> ComparedFiles {
        var result = ComparedFiles()
        guard let (leftItem, rightItem) = files(left, right, fileSystems: fileSystems, cancellation, into: &result)
        else {
            return result
        }
        result.leftItem = leftItem.isSymlink ? nil : leftItem
        result.rightItem = rightItem.isSymlink ? nil : rightItem
        do {
            if leftItem.size == rightItem.size, leftItem.size >= limits.quickCheckFrom {
                result.isIdentical = try identical(
                    left,
                    right,
                    size: leftItem.size,
                    fileSystems: fileSystems,
                    cancellation: cancellation
                )
                if result.isIdentical {
                    return result
                }
            }
            guard max(leftItem.size, rightItem.size) <= limits.loadLimit else {
                result.message =
                    "The two files are different. They are too large to be shown side by side "
                    + "(more than \(Format.shortSize(limits.loadLimit)))."
                return result
            }
            let loaded = Parallel.map([left, right]) { url in
                Result { try read(url, fileSystems: fileSystems, cancellation: cancellation) }
            }
            let (first, second) = (try loaded[0].get(), try loaded[1].get())
            result.isIdentical = first == second
            if forceBinary || TextDocument.looksBinary(first) || TextDocument.looksBinary(second) {
                result.content = binary(first, second, bytesPerLine: bytesPerLine, cancellation: cancellation)
            } else {
                result.content = text(first, second, options: options, cancellation: cancellation)
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
        left: TextDocument,
        right: TextDocument,
        options: DiffOptions,
        anchors: [(left: Int, right: Int)] = [],
        cancellation: CancellationFlag? = nil
    ) -> CompareContent {
        let diff = TextDiff.compute(
            left: left.lines,
            right: right.lines,
            options: options,
            anchors: anchors,
            cancellation: cancellation
        )
        let widths = Parallel.map([left.lines, right.lines]) { lines in
            lines.reduce(0) { widest, line in max(widest, line.text.utf16.count) }
        }
        return .text(left: left, right: right, diff: diff, width: max(widths[0], widths[1]))
    }

    /// The whole file; throws `CancellationError` when cancelled before the end.
    internal static func read(_ url: URL, fileSystems: FileSystemRegistry, cancellation: CancellationFlag) throws
        -> Data
    {
        // What a plugin still holds back for this file (an archive written after a delay) is written first.
        try fileSystems.flushPendingWrites(to: url, cancellation: cancellation)
        let reader = try fileSystems.provider(for: url).read(url, cancellation: cancellation)
        defer { reader.close() }
        let token = cancellation.interrupting(reader)
        defer {
            withExtendedLifetime(token) {
                // Interrupts the reader up to here.
            }
        }
        var data = Data()
        var hasMore = true
        while hasMore {
            hasMore = try autoreleasepool { () throws -> Bool in
                // A part of the file is no file to compare.
                if cancellation.isCancelled {
                    throw CancellationError()
                }
                guard let block = try reader.read(upToCount: 1 << 20), !block.isEmpty else {
                    return false
                }
                data.append(block)
                return true
            }
        }
        return data
    }

    /// The two files as their file systems list them; nil when the look was cancelled or one is not a file, which
    /// `result` then tells.
    private static func files(
        _ left: URL,
        _ right: URL,
        fileSystems: FileSystemRegistry,
        _ cancellation: CancellationFlag,
        into result: inout ComparedFiles
    ) -> (left: FileItem, right: FileItem)? {
        let items = Parallel.map([left, right]) { url in
            (try? fileSystems.provider(for: url))?.item(at: url, cancellation: cancellation)
        }
        if cancellation.isCancelled {
            result.wasCancelled = true
            return nil
        }
        var files: [FileItem] = []
        for (url, item) in zip([left, right], items) {
            guard let item, !item.isDirectory else {
                result.message = "\(fileSystems.displayPath(url)) is not a file."
                return nil
            }
            files.append(item)
        }
        return (files[0], files[1])
    }

    /// Two files compared byte by byte, `bytesPerLine` bytes to a row.
    private static func binary(_ left: Data, _ right: Data, bytesPerLine: Int, cancellation: CancellationFlag)
        -> CompareContent
    {
        .binary(
            left: left,
            right: right,
            diff: BinaryDiff.compute(left: left, right: right, bytesPerLine: bytesPerLine, cancellation: cancellation)
        )
    }

    /// Two files decoded as text (both at once) and laid side by side.
    private static func text(_ left: Data, _ right: Data, options: DiffOptions, cancellation: CancellationFlag)
        -> CompareContent
    {
        let documents = Parallel.map([left, right]) { data in TextDocument(data: data) }
        return text(left: documents[0], right: documents[1], options: options, cancellation: cancellation)
    }
}
