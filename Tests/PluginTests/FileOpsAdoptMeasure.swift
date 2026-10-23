import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// The cache of measured folders.
@Suite
internal struct FileOpsAdoptMeasure {
    /// A big folder renamed inside a merge is not listed again, even when the measure cache is full.
    @Test
    internal func aBigFolderRenamedInsideAMergeIsNotCountedAgainEvenWhenTheCacheIsFull() {
        let base = MemoryFileSystem()
        for index in 1...5 { base.addFile("/src/A/small\(index)/one.txt") }
        for index in 0..<70 { base.addFile("/src/A/big/f\(index).txt") }
        base.addFile("/dst/A/existing.txt")
        let probe = ProbeFileSystem(base)
        let result = Replies()
            .run(
                .move,
                [base.url("/src/A")],
                to: TargetSpec(directory: base.url("/dst")),
                fileSystems: FileSystemRegistry.localDisk(and: probe)
            ) { job in
                job.rememberedLimit = 2
            }
        #expect(result.completed.count == 1)
        #expect(base.exists("/dst/A/big/f69.txt") && base.exists("/dst/A/existing.txt"))
        #expect(probe.count(of: "list /src/A/big") == 1)
    }
}
