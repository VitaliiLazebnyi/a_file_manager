import AFMKernel
import Foundation
import TestSupport

/// The memory file system of the bench as "a server": files put onto it and fetched back.
extension ArchiveFixSuite {
    /// Puts a file of the disk onto the memory file system ("a server") at `path`.
    internal func upload(_ local: URL, to path: String) throws -> URL {
        let url = bench.memory.url(path)
        bench.memory.createDirectory(at: url.deletingLastPathComponent())
        let writer = try bench.memory.write(url)
        try writer.write(try Data(contentsOf: local))
        try writer.close(attributes: FileAttributes())
        return url
    }

    /// What the server holds at `url`, as a file `name` on the disk that the system's tools can look at.
    internal func download(_ url: URL, as name: String) throws -> URL {
        let local = box.url(name)
        try? FileManager.default.removeItem(at: local)
        try bench.read(url).write(to: local)
        return local
    }
}
