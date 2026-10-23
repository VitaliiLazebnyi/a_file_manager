public import AFMKernel
public import Foundation

/// Saving: a file replaced as a whole, never half written, and never over a change made by someone else.
extension CompareLoader {
    /// Why a file is not saved.
    internal enum SaveError: LocalizedError {
        /// The file (by its name) was changed by someone else after it was loaded.
        case changedOnDisk(String)
        /// The text of the file (by its name) has bytes that are not valid in the encoding it was read in.
        case invalidSequences(String, TextEncoding)
        /// The text of the file (by its name) has characters the encoding cannot hold.
        case notRepresentable(String, TextEncoding)
        /// Both sides are the one file (its path) and both were edited.
        case sameFile(String)

        /// The message for the user, naming the file and why it is not saved.
        internal var errorDescription: String? {
            switch self {
            case .changedOnDisk(let name):
                return "\(name) was changed by someone else after it was loaded. It is not overwritten; "
                    + "compare the files again."

            case .invalidSequences(let name, let encoding):
                return "\(name) has bytes that are not valid \(encoding.name). Saving would change them, "
                    + "so it is not saved."

            case .notRepresentable(let name, let encoding):
                return "\(name) has characters that \(encoding.name) cannot hold, so it is not saved "
                    + "(that would turn them into question marks)."

            case .sameFile(let name):
                return "Both sides are the same file (\(name)) and both were edited, so it is not saved."
            }
        }
    }

    /// Whether two locations are one file: the same place, or on this Mac the same device and inode.
    internal static func isSameFile(_ first: URL, _ second: URL) -> Bool {
        first.isSameLocation(as: second) || first.isSameFile(as: second, followingLinks: true)
    }

    /// Replaces the file at `url` with `data`: the new content is written next to it under a
    /// temporary name and moved over it, so the file is never half written.
    ///
    /// `expected` is how the file looked when it was loaded: a file that is different now (changed
    /// by someone else) is not overwritten. Returns the file as it is now.
    ///
    /// A local file with several hard links is written in place instead: a rename would give
    /// this name a file of its own and leave the other names with the old content.
    @discardableResult
    public static func replace(_ url: URL, with data: Data, fileSystems: FileSystemRegistry, expected: FileItem? = nil)
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
        if let expected, let existing, hasChanged(existing, since: expected) {
            throw SaveError.changedOnDisk(url.lastPathComponent)
        }
        if existing != nil, url.isFileURL, try writeInPlaceIfLinked(url, data, fileSystem) {
            return fileSystem.item(at: url)
        }
        let name = url.lastPathComponent
        let temporary = url.deletingLastPathComponent().appending(name: ".\(name).afm-save")
        try? fileSystem.remove(temporary)
        // Set once the old file is out of the way and could not be put back: the temporary is then the only copy of
        // the new text.
        var mustKeepTemporary = false
        do {
            let writer = try fileSystem.write(temporary)
            try write(data, to: writer)
            try writer.close(attributes: FileAttributes(modified: Date(), permissions: existing?.permissions))
            if existing != nil, url.isFileURL {
                carryOverMetadata(from: url, to: temporary)
            }
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
            if !mustKeepTemporary {
                try? fileSystem.remove(temporary)
            }
            throw error
        }
        return fileSystem.item(at: url)
    }

    /// Whether the file is not as it was when loaded: its size or modification date differ.
    ///
    /// A link loaded is never changed: it is saved where it leads, whatever that looks like now.
    private static func hasChanged(_ current: FileItem, since loaded: FileItem) -> Bool {
        !loaded.isSymlink
            && (current.size != loaded.size || abs(current.modified.timeIntervalSince(loaded.modified)) > 0.001)
    }

    /// Writes into the file itself when it has more than one hard link; false when it has not.
    ///
    /// The file system continues the file from its start: it opens it without waiting, refuses
    /// anything but a regular file there (a pipe that took the name since the look), and cuts it
    /// through the descriptor it writes with.
    private static func writeInPlaceIfLinked(_ url: URL, _ data: Data, _ fileSystem: any FileSystemProvider) throws
        -> Bool
    {
        var status = stat()
        guard stat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG, status.st_nlink > 1 else {
            return false
        }
        let writer = try fileSystem.append(to: url, at: 0, cancellation: CancellationFlag())
        try write(data, to: writer)
        try writer.close(attributes: FileAttributes(modified: Date()))
        return true
    }

    /// Writes `data` through `writer` a megabyte at a time; the caller closes it.
    private static func write(_ data: Data, to writer: any FileWriter) throws {
        for start in stride(from: 0, to: data.count, by: 1 << 20) {
            try writer.write(data.subdata(in: start..<min(start + (1 << 20), data.count)))
        }
    }

    /// What a rename over the file would lose: extended attributes (tags, quarantine, Finder
    /// info), ACLs, owner and creation date.
    ///
    /// Best effort; the data is what counts.
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
