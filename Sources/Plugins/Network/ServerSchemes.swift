public import Foundation

/// The schemes Connect to Server hands to the system; the others are this program's own.
public enum ServerSchemes {
    /// The schemes the system mounts as a volume: SMB, AFP, NFS and WebDAV (plain and secure).
    public static let mountable = ["smb", "afp", "nfs", "cifs", "http", "https", "webdav", "webdavs"]

    /// The volume a local path lies on, when it is one under /Volumes; nil for the startup disk.
    public static func mountedVolume(of url: URL) -> URL? {
        guard url.isFileURL else {
            return nil
        }
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 3, parts[1] == "Volumes" else {
            return nil
        }
        return URL(fileURLWithPath: "/Volumes/" + parts[2], isDirectory: true)
    }
}
