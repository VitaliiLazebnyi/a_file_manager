import AFMKernel
import TestSupport

@testable import AFMShell

/// The names of the listing the cache of a running program (of the `Application` suite)
/// remembers for `path` of its memory file system; nil when nothing is remembered.
@MainActor
internal func remembered(_ app: Application.Running, _ path: String) -> [String]? {
    guard let memory = app.kernel.fileSystems.all.first(where: { $0.scheme == "mem" }) as? MemoryFileSystem else {
        return nil
    }
    return app.kernel.listingCache.entry(for: memory.url(path), showHidden: false)?.listing.items.map(\.name)
}
