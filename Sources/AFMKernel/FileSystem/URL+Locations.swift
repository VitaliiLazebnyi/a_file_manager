public import Foundation

/// Locations worked out on the text alone, as file systems of every kind need them.
extension URL {
    /// Identifies a location across file systems: scheme, host, port and path, without a trailing slash.
    ///
    /// Two URLs show the same place exactly when their keys are equal.
    public var locationKey: String {
        let host = (self.host ?? "") + (port.map { ":\($0)" } ?? "")
        // `path` has no trailing slash: Foundation takes it off (`/` stays `/`).
        return (scheme ?? "file") + "://" + host + path
    }

    /// The location of an entry inside this directory.
    ///
    /// Unlike `appendingPathComponent(_:)`, which asks the disk whether the result is a folder (one trip to the server
    /// per call on a network share), this works on the text alone.
    ///
    /// The name is taken as it is: one that holds a `/`, or is `..`, leads somewhere else.
    /// That is wanted for a path the user typed and for nothing that comes from outside (an
    /// archive, a server, a list file): such names go through `appending(safeName:)` or
    /// `PathSafety`.
    public func appending(name: String) -> URL {
        appendingPathComponent(name, isDirectory: false)
    }

    /// The location of an entry inside this directory, for a name that comes from outside:
    /// nil unless the name is one name (`PathSafety.isSafeName`), so the result is always
    /// directly inside this directory.
    public func appending(safeName name: String) -> URL? {
        PathSafety.isSafeName(name) ? appendingPathComponent(name, isDirectory: false) : nil
    }

    /// Whether two URLs show the same place (`locationKey`).
    public func isSameLocation(as other: URL) -> Bool {
        locationKey == other.locationKey
    }

    /// Whether two locations are the same file: for local files the same entry of the same volume (device and inode,
    /// links not followed unless `followingLinks`), however the two paths are written; false when either is not there.
    ///
    /// For other locations, and when the disk cannot say, the same location as text. Asks the disk: not for the main
    /// thread.
    public func isSameFile(as other: URL, followingLinks: Bool = false) -> Bool {
        guard isFileURL, other.isFileURL else {
            return isSameLocation(as: other)
        }
        var (own, others) = (stat(), stat())
        let look = followingLinks ? stat : lstat
        guard look(path, &own) == 0, look(other.path, &others) == 0 else {
            return false
        }
        return own.st_dev == others.st_dev && own.st_ino == others.st_ino
    }

    /// True when `self` lies somewhere below `ancestor`.
    ///
    /// The keys are compared byte for byte: a folder whose name merely reads like the ancestor's, or goes on with an
    /// accent after the last character, is another folder.
    public func isInside(_ ancestor: URL) -> Bool {
        let (own, parent) = (locationKey, ancestor.locationKey)
        return own.utf8.starts(with: (parent.utf8.last == 0x2F ? parent : parent + "/").utf8)
    }
}
