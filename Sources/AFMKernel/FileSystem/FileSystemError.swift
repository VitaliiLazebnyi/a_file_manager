public import Foundation

public enum FileSystemError: LocalizedError, Sendable {
    case noProvider(URL)
    case notSupported(String)
    case alreadyExists(String)
    /// A move or copy cannot be done inside the file system; the caller streams the contents.
    case crossesVolumes

    public var errorDescription: String? {
        switch self {
        case .noProvider(let url): return "No file system is available for \(url.absoluteString)."
        case .notSupported(let what): return "\(what) is not supported here."
        case .alreadyExists(let path): return "\(path) already exists."
        case .crossesVolumes: return "The file cannot be moved or copied inside its file system."
        }
    }
}
