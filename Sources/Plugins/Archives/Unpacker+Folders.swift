import AFMKernel
import Foundation

/// Making folders by path, for a target that is not a disk of this machine: a server, another
/// archive, a network volume.
extension Unpacker {
    /// Refuses to go through a symbolic link on the way from `root` down to `url` (both on
    /// the local disk): a link in the target folder, left by an earlier unpacking or put
    /// there on purpose, would lead what is unpacked now to wherever it points.
    ///
    /// The paths are taken as they are written, as the file system takes them when it writes: a
    /// `..` in the target leads wherever the disk says, not where the text would.
    private static func refuseLinks(from root: URL, to url: URL) throws {
        guard url.isFileURL, root.isFileURL else {
            return
        }
        let (names, base) = (url.pathComponents, root.pathComponents)
        guard names.count > base.count, Array(names[..<base.count]) == base else {
            return
        }
        var current = root
        for name in names[base.count...] {
            current = current.appending(name: name)
            var status = stat()
            // What does not exist yet is made here, as a folder.
            guard lstat(current.path, &status) == 0 else {
                return
            }
            if status.st_mode & S_IFMT == S_IFLNK {
                throw ArchiveError.unsupported("Unpacking through the symbolic link \(current.path)")
            }
        }
    }

    /// A folder that is there is used if it is a real one, not a link to one.
    private static func isFolder(_ item: FileItem) -> Bool {
        item.isDirectory && !item.isSymlink
    }

    /// Makes the folder `url` below `root` and those between, through the target's file system;
    /// `made` holds the folders made (or found) so far and gets the new ones.
    internal func makeFolder(_ url: URL, below root: URL, made: inout Set<String>) throws {
        guard !made.contains(url.locationKey) else {
            return
        }
        try Self.refuseLinks(from: root, to: url)
        let provider = try fileSystems.provider(for: url)
        let stop = monitor.cancellation
        // The folders between the target and this one that are not known yet, top first.
        var missing: [URL] = []
        var current = url
        while !made.contains(current.locationKey), !current.isSameLocation(as: root), missing.count < 4_096,
            Self.lies(current, below: root), let above = provider.parent(of: current)
        {
            missing.append(current)
            current = above
        }
        if !made.contains(current.locationKey) {
            // The folder that is unpacked into exists, or is made, as it is: only what lies
            // below it comes from the archive.
            try provider.createDirectory(at: current, cancellation: stop)
            made.insert(current.locationKey)
        }
        for folder in missing.reversed() {
            try makeOwnFolder(folder, with: provider)
            made.insert(folder.locationKey)
        }
    }

    /// Makes `folder` as this unpacking's own, or takes the folder that is there.
    ///
    /// A folder that is there is used if it is a folder. One that is not is made here and must be
    /// this unpacking's own: whatever has appeared under its name since it was looked for (a link
    /// left by an earlier archive or put there on purpose, which would lead everything below it
    /// elsewhere) is "already exists", not a way through (L043).
    private func makeOwnFolder(_ folder: URL, with provider: any FileSystemProvider) throws {
        let stop = monitor.cancellation
        let notAFolder = ArchiveError.unsupported(
            "Unpacking through \(fileSystems.displayPath(folder)), which is not a folder"
        )
        if let existing = provider.item(at: folder, cancellation: stop) {
            guard Self.isFolder(existing) else { throw notAFolder }
            return
        }
        do {
            try provider.createDirectory(at: folder, exclusive: true, cancellation: stop)
        } catch FileSystemError.alreadyExists {
            // Made by somebody else in the same moment: only a real folder will do.
            guard let existing = provider.item(at: folder, cancellation: stop), Self.isFolder(existing) else {
                throw notAFolder
            }
        }
    }
}
