public import AFMKernel
public import Foundation

/// Whether two files are identical, found without loading them.
extension CompareLoader {
    /// Whether two files of `size` bytes have the same content; throws `CancellationError` when cancelled.
    ///
    /// Blocks; call it on a background thread. Local files are compared `stretch` bytes at a time on several
    /// threads, others read once side by side.
    public static func identical(
        _ first: URL,
        _ second: URL,
        size: Int64,
        fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag = CancellationFlag(),
        stretch: Int = Self.stretch
    ) throws -> Bool {
        if cancellation.isCancelled {
            throw CancellationError()
        }
        try fileSystems.flushPendingWrites(to: first, cancellation: cancellation)
        try fileSystems.flushPendingWrites(to: second, cancellation: cancellation)
        let files = [
            (system: try fileSystems.provider(for: first), url: first),
            (system: try fileSystems.provider(for: second), url: second)
        ]
        let isLocal = files.allSatisfy { file in
            file.system.volume(of: file.url, cancellation: cancellation)?.isLocal ?? false
        }
        let check = StretchCheck(files: files, size: size, stretch: stretch, cancellation: cancellation)
        guard isLocal, check.count > 1 else {
            do {
                return try sameStream(files, cancellation: cancellation)
            } catch  where cancellation.isCancelled {
                // A read that the cancel ended is the cancel, not a failure.
                throw CancellationError()
            }
        }
        return try check.run()
    }

    /// Reads until `count` bytes are there or the file ends; readers may hand out less at a time.
    internal static func exactly(_ count: Int, from reader: any FileReader) throws -> Data {
        var data = Data()
        var hasMore = true
        while hasMore {
            hasMore = try autoreleasepool { () throws -> Bool in
                guard data.count < count, let block = try reader.read(upToCount: count - data.count), !block.isEmpty
                else {
                    return false
                }
                data.append(block)
                return true
            }
        }
        return data
    }

    /// Reads the two files once, side by side, and stops at the first difference; throws `CancellationError` when
    /// cancelled before the end.
    private static func sameStream(
        _ files: [(system: any FileSystemProvider, url: URL)],
        cancellation: CancellationFlag
    ) throws -> Bool {
        var readers: [any FileReader] = []
        var tokens: [AnyObject] = []
        defer {
            for reader in readers {
                reader.close()
            }
            withExtendedLifetime(tokens) {
                // The readers can be interrupted up to here.
            }
        }
        for (system, url) in files {
            let reader = try system.read(url, cancellation: cancellation)
            readers.append(reader)
            tokens.append(cancellation.interrupting(reader))
        }
        while !cancellation.isCancelled {
            let blocks = try autoreleasepool {
                [try exactly(1 << 20, from: readers[0]), try exactly(1 << 20, from: readers[1])]
            }
            if blocks[0] != blocks[1] {
                return false
            }
            if blocks[0].isEmpty {
                return true
            }
        }
        throw CancellationError()
    }
}
