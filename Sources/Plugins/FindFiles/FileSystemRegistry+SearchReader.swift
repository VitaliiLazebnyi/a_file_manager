import AFMKernel
import Foundation

/// A reader for what a search or a comparison reads.
extension FileSystemRegistry {
    /// A reader for a file a search or comparison is about to read through: local files by
    /// way of `LocalFileReader`, others through their file system.
    internal func searchReader(for url: URL, cancellation: CancellationFlag) -> any FileReader? {
        if url.isFileURL {
            return LocalFileReader.open(url)
        }
        return try? provider(for: url).read(url, cancellation: cancellation)
    }
}
