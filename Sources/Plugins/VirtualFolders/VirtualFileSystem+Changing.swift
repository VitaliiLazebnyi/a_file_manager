public import AFMKernel
public import Foundation

/// Reading and changing files in a virtual folder.
///
/// A location below a branch view has the path of a real location. Whatever is created in a
/// branch view (a new folder, a pasted file) therefore lands in the real directory; the real file
/// system does all the work. A list of files cannot be changed as a folder.
extension VirtualFileSystem {
    /// Reads the real file a location in a branch view stands for.
    public func read(_ url: URL) throws -> any FileReader {
        let target = try real(url)
        return try target.provider.read(target.url)
    }

    /// The same; the flag ends the wait for a real file system that is slow to answer.
    public func read(_ url: URL, cancellation: CancellationFlag) throws -> any FileReader {
        let target = try real(url)
        return try target.provider.read(target.url, cancellation: cancellation)
    }

    /// Makes the folder in the real directory.
    public func createDirectory(at url: URL) throws {
        let target = try real(url)
        try target.provider.createDirectory(at: target.url)
    }

    /// Writes the real file, which is made when it is not there.
    public func write(_ url: URL) throws -> any FileWriter {
        let target = try real(url)
        return try target.provider.write(target.url)
    }

    /// The same; the flag ends the wait for a real file system that is slow to answer.
    public func write(_ url: URL, cancellation: CancellationFlag) throws -> any FileWriter {
        let target = try real(url)
        return try target.provider.write(target.url, cancellation: cancellation)
    }

    /// Writes on at `offset` of the real file (its end when nil), as a resumed copy does.
    public func append(to url: URL, at offset: Int64?, cancellation: CancellationFlag) throws -> any FileWriter {
        let target = try real(url)
        return try target.provider.append(to: target.url, at: offset, cancellation: cancellation)
    }

    /// Deletes the real file or folder.
    public func remove(_ url: URL) throws {
        let target = try real(url)
        try target.provider.remove(target.url)
    }

    /// Moves the real file or folder to the trash of its file system.
    public func trash(_ url: URL) throws {
        let target = try real(url)
        try target.provider.trash(target.url)
    }

    /// Moves a real file within its file system; both ends must be on the same one.
    ///
    /// Throws `FileSystemError.crossesVolumes` otherwise, so that the caller copies instead.
    public func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        let (origin, target) = (try real(source), try real(destination))
        guard origin.provider === target.provider else { throw FileSystemError.crossesVolumes }
        try origin.provider.move(origin.url, to: target.url, replacing: replacing)
    }

    /// Copies a real file within its file system; both ends must be on the same one.
    ///
    /// Throws `FileSystemError.crossesVolumes` otherwise, so that the caller copies by reading
    /// and writing.
    public func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        let (origin, target) = (try real(source), try real(destination))
        guard origin.provider === target.provider else { throw FileSystemError.crossesVolumes }
        try origin.provider.copy(origin.url, to: target.url, progress: progress)
    }

    /// Sets the attributes of the real file.
    public func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        let target = try real(url)
        try target.provider.setAttributes(attributes, of: target.url)
    }

    /// The folder is a virtual one at both ends: the real file systems do the work.
    ///
    /// The source may also be a real location already; a list is nothing to copy metadata from.
    public func copyMetadata(from source: URL, to destination: URL) throws {
        let target = try real(destination)
        let origin: URL
        switch VirtualLocation(source) {
        case .branch(let real), .picked(_, let real):
            origin = real

        case .list:
            throw FileSystemError.notSupported("Copying metadata")

        case nil:
            origin = source
        }
        try target.provider.copyMetadata(from: origin, to: target.url)
    }

    /// A list has nothing written to it, so there is nothing to make durable.
    public func commit(_ url: URL, cancellation: CancellationFlag) throws {
        guard VirtualLocation(url)?.isList == false else {
            return
        }
        let target = try real(url)
        try target.provider.commit(target.url, cancellation: cancellation)
    }

    /// The quarantine of the real file; nil when it has none or the location is no real file.
    public func quarantine(of url: URL) -> Data? {
        guard let target = try? real(url) else {
            return nil
        }
        return target.provider.quarantine(of: target.url)
    }

    /// Sets the quarantine of the real file.
    public func setQuarantine(_ value: Data, of url: URL) throws {
        let target = try real(url)
        try target.provider.setQuarantine(value, of: target.url)
    }

    /// The size of everything below the real directory; for a list, of its files.
    public func totalSize(of directory: URL, cancellation: CancellationFlag) -> Int64 {
        guard let target = try? real(directory) else {
            return totalSizeByListing(of: directory, cancellation: cancellation)
        }
        return target.provider.totalSize(of: target.url, cancellation: cancellation)
    }

    /// The real location and its file system for a location in a branch view or selected branch.
    ///
    /// Throws for a list, which cannot be changed as a folder, and for every other URL.
    private func real(_ url: URL) throws -> (provider: any FileSystemProvider, url: URL) {
        switch VirtualLocation(url) {
        case .branch(let real), .picked(_, let real):
            return (try fileSystems.provider(for: real), real)

        case .list:
            throw FileSystemError.notSupported("Changing a list of files")

        case nil:
            throw FileSystemError.noProvider(url)
        }
    }
}
