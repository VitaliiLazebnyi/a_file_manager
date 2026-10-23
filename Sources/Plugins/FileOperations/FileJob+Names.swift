import AFMKernel
import Foundation

/// The names a job reads and makes, and how it reads the errors the system answers with.
extension FileJob {
    /// `.afm-<UUID>.tmp`, the name every unfinished copy carries.
    internal static func isTemporaryName(_ name: String) -> Bool {
        name.utf8.count == 45 && name.hasPrefix(".afm-") && name.hasSuffix(".tmp")
            && UUID(uuidString: String(name.dropFirst(5).dropLast(4))) != nil
    }

    /// Removes the unfinished copies that a crash or a failed clean-up left in the target
    /// folder long ago: plain files under the job's own temporary name that nobody has
    /// touched for a day.
    ///
    /// Local folders only.
    internal static func sweepStaleTemporaries(in directory: URL, now: Date) {
        guard directory.isFileURL, let stream = opendir(directory.path) else {
            return
        }
        defer { closedir(stream) }
        let limit = Int(now.timeIntervalSince1970 - staleTemporaryAge)
        while let entry = readdir(stream) {
            guard entry.pointee.d_namlen == 45 else { continue }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { field in
                field.withMemoryRebound(to: CChar.self, capacity: 46) { String(cString: $0) }
            }
            guard isTemporaryName(name) else { continue }
            let path = directory.path + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_mtimespec.tv_sec < limit,
                info.st_ctimespec.tv_sec < limit
            else { continue }
            unlink(path)
        }
    }

    /// Looks through `folder` for old temporary files, once per folder and run of the program:
    /// reading a very large folder takes a moment.
    internal static func sweepOnFirstVisit(_ folder: URL) {
        let isFirstVisit = swept.withLock { swept in
            if swept.count >= 1_024 { swept.removeAll() }
            return swept.insert(folder.locationKey).inserted
        }
        if isFirstVisit { sweepStaleTemporaries(in: folder, now: Date()) }
    }

    /// Exactly `count` bytes, or nil when the file ends first.
    internal static func read(_ count: Int, from reader: any FileReader) throws -> Data? {
        var data = Data()
        while data.count < count {
            guard let block = try reader.read(upToCount: count - data.count), !block.isEmpty else {
                return nil
            }
            data.append(block)
        }
        return data
    }

    /// What the system answers when a place has no Trash at all, as opposed to a failure of
    /// this one item (no permission, the item vanished), which is the user's to deal with.
    internal static func isNoTrash(_ error: any Error) -> Bool {
        if case .notSupported? = error as? FileSystemError {
            return true
        }
        let bridged = error as NSError
        if bridged.domain == NSCocoaErrorDomain, bridged.code == CocoaError.featureUnsupported.rawValue {
            return true
        }
        if bridged.domain == NSPOSIXErrorDomain, bridged.code == Int(ENOTSUP) || bridged.code == Int(EOPNOTSUPP) {
            return true
        }
        return (bridged.userInfo[NSUnderlyingErrorKey] as? (any Error)).map(isNoTrash) ?? false
    }

    /// "Operation not permitted": what the system answers for a locked item, as opposed to a
    /// folder one has no right to change.
    internal static func isRefusedAsLocked(_ error: any Error) -> Bool {
        let bridged = error as NSError
        if bridged.domain == NSPOSIXErrorDomain {
            return bridged.code == Int(EPERM)
        }
        return (bridged.userInfo[NSUnderlyingErrorKey] as? (any Error)).map(isRefusedAsLocked) ?? false
    }

    /// A name that stands for one entry of its folder: not empty, not `.` or `..`, no `/`, no NUL.
    ///
    /// The kernel's rule (`PathSafety`), byte for byte.
    internal static func isSafeName(_ name: String) -> Bool {
        PathSafety.isSafeName(name)
    }

    /// How a target name is compared for "is it taken": a volume may fold letter case and the
    /// forms of an accented letter, and then two names that look different are one place.
    internal static func claimKey(_ url: URL) -> String {
        url.locationKey.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// `claimKey` as a number, for remembering many targets in little memory.
    ///
    /// Two targets that fold to one place have one number; two that do not may share one, once in a
    /// blue moon, and are then taken for one place, which errs on the careful side.
    internal static func claimHash(_ url: URL) -> Int {
        claimKey(url).hashValue
    }

    /// The sources in the order a job works through them: by name, without regard to case (07 › Processing order).
    internal static func inProcessingOrder(_ urls: [URL]) -> [URL] {
        Sorter.sorted(urls, byName: \.lastPathComponent)
    }
}
