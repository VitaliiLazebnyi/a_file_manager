import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FindFilesPlugin

/// A folder that a search with a depth limit meets twice, first far from its start directory
/// and then near it (as a firmlink makes one folder of two places).
@Suite
internal struct SweepFileSearchTests {
    /// Met nearer the second time, the folder is searched again, deeper than the far road let.
    @Test
    internal func aFolderMetNearerTheSecondTimeIsSearchedDeeper() {
        let memory = MemoryFileSystem()
        let registry = FileSystemRegistry()
        registry.register(memory)
        // The far road comes first in name order; one thread takes the folders in that order.
        for road in ["/R/a/b/c/T", "/R/z"] {
            memory.addFile(road + "/f.txt")
            memory.addFile(road + "/sub/g.txt")
        }
        let same = FileIdentity(device: 1, inode: 1)
        var tuning = FileSearch.Tuning()
        tuning.threads = 1
        tuning.identity = { ["/R/a/b/c/T", "/R/z"].contains($0.path) ? same : nil }
        var query = SearchQuery(directory: memory.url("/R"))
        query.maxDepth = 4
        let search = FileSearch(query, fileSystems: registry, tuning: tuning)
        var found: [String] = []
        search.run { found.append($0.url.path) }
        // Four levels down, `sub` of the far road is beyond the limit; near, it is not.
        #expect(found.contains("/R/z/sub/g.txt"))
        #expect(!found.contains("/R/a/b/c/T/sub/g.txt"))
    }
}
