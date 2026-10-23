import AFMKernel
import Foundation

/// File › Save as: what is shown, written to a file of the user's choice.
internal enum ViewerSave {
    /// Whether `target` is the file `viewed` (the same inode, or the same place when the target
    /// does not exist yet): saving onto it would replace what is being read.
    internal static func isSameFile(_ viewed: URL?, _ target: URL) -> Bool {
        guard let viewed, viewed.isFileURL, target.isFileURL else {
            return false
        }
        var first = stat()
        var second = stat()
        if stat(viewed.path, &first) == 0, stat(target.path, &second) == 0 {
            return first.st_dev == second.st_dev && first.st_ino == second.st_ino
        }
        return viewed.resolvingSymlinksInPath().standardizedFileURL.path
            == target.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Writes the whole `source` to `target`: into a new file beside it that is then moved onto
    /// it, so a target that is being read, or a copy that stops half way (the file became
    /// shorter, the disk is full, the job is cancelled), never leaves a half-written file in
    /// place of a whole one.
    ///
    /// Blocks. `progress` is given the bytes written.
    internal static func save(
        _ source: any ByteSource,
        to target: URL,
        cancellation: CancellationFlag,
        progress: (Int64) -> Void
    ) throws {
        let folder = target.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(
            ".\(target.lastPathComponent).afm-saving-\(UUID().uuidString.prefix(8))"
        )
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: folder.path])
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var finished = false
        defer {
            try? handle.close()
            if !finished { unlink(temporary.path) }
        }
        var offset: Int64 = 0
        while offset < source.length {
            try cancellation.throwIfCancelled()
            let block = try autoreleasepool { try source.read(at: offset, count: 1 << 20, cancellation: cancellation) }
            // A read that comes back short before the end is a file that became shorter: the
            // copy would be cut off without anyone being told.
            guard !block.isEmpty else { throw ViewerError.fileChanged }
            try handle.write(contentsOf: block)
            offset += Int64(block.count)
            progress(offset)
        }
        try cancellation.throwIfCancelled()
        try handle.synchronize()
        guard rename(temporary.path, target.path) == 0 else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [
                    NSFilePathErrorKey: target.path, NSLocalizedFailureReasonErrorKey: String(cString: strerror(errno))
                ]
            )
        }
        finished = true
    }
}
