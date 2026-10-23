public import AFMKernel
public import Foundation

/// Adding up the size of a tree.
extension LocalFileSystem {
    /// Opens a folder to be read. `O_CLOEXEC`, and an `EINTR` nobody asked for is tried again.
    internal static func openDirectory(_ path: String) -> Int32 {
        var descriptor: Int32
        repeat {
            descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        } while descriptor < 0 && errno == EINTR
        return descriptor
    }

    /// Adds up a tree without making an item of every entry: names, kinds and sizes are all
    /// that is read, and the folders of each level are measured on all cores.
    public func totalSize(of directory: URL, cancellation: CancellationFlag) -> Int64 {
        totalSize(ofPath: directory.path, cancellation)
            ?? totalSizeByListing(of: directory, cancellation: cancellation)
    }

    /// `getattrlistbulk` of the folder at `path`, tried again after an `EINTR` nobody asked for.
    internal func readBulk(
        _ descriptor: Int32,
        _ path: String,
        _ request: UnsafeMutablePointer<attrlist>,
        _ buffer: UnsafeMutableRawPointer,
        _ capacity: Int
    ) -> Int32 {
        var count: Int32
        repeat {
            count = probes.system("getattrlistbulk", path) { getattrlistbulk(descriptor, request, buffer, capacity, 0) }
        } while count < 0 && errno == EINTR
        return count
    }

    /// The folder's entries, a buffer at a time: files are added up, folders are returned.
    /// `nil` result when the volume has no bulk reads.
    private func measureLevel(_ path: String, _ cancellation: CancellationFlag) -> (files: Int64, folders: [String])? {
        var files: Int64 = 0
        var folders: [String] = []
        probes.willAsk?(path)
        let descriptor = Self.openDirectory(path)
        // As when listing: a folder that cannot be read counts as nothing.
        guard descriptor >= 0 else {
            return (0, [])
        }
        defer { close(descriptor) }
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | Entry.wantError | Entry.wantName | Entry.wantType
        request.fileattr = Entry.wantSize
        let capacity = 64 * 1_024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { buffer.deallocate() }
        var isFirst = true
        // Looked at before every buffer: a million-entry folder is not read to the end after Cancel.
        while !cancellation.isCancelled {
            let count = readBulk(descriptor, path, &request, buffer, capacity)
            if count == 0 { break }
            if count < 0 {
                return isFirst && (errno == ENOTSUP || errno == EINVAL) ? nil : (0, [])
            }
            isFirst = false
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let (read, length) = Entry.read(at: entry)
                entry += length
                guard let measured = Self.measured(read, in: path) else { continue }
                if let folder = measured.folder {
                    folders.append(folder)
                } else {
                    files = files.addingSaturated(measured.size)
                }
            }
        }
        return (files, folders)
    }

    /// Nil when the volume has no bulk reads; the tree is then measured by listing it.
    private func totalSize(ofPath path: String, _ cancellation: CancellationFlag) -> Int64? {
        guard !cancellation.isCancelled else {
            return 0
        }
        // A folder that is only on a server (iCloud Drive) is not fetched to be measured.
        guard let level = Self.withoutMaterializing({ measureLevel(path, cancellation) }) else {
            return nil
        }
        guard !cancellation.isCancelled else {
            return 0
        }
        return
            Parallel.map(level.folders) { folder in
                self.totalSize(ofPath: folder, cancellation)
                    ?? self.totalSizeByListing(
                        of: URL(fileURLWithPath: folder, isDirectory: true),
                        cancellation: cancellation
                    )
            }
            .reduce(level.files) { $0.addingSaturated($1) }
    }
}
