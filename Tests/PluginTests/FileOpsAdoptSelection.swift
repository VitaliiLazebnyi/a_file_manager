import AFMKernel
import Foundation
import Testing

@testable import FileOperationsPlugin

/// Finding the processed items in a panel's list.
@MainActor
@Suite
internal struct FileOpsAdoptSelection {
    /// Processed items are found by their location, also when their names are paths.
    @Test
    internal func processedItemsAreFoundByLocationWhoseNamesArePaths() {
        let inFolder = FileItem(url: URL(fileURLWithPath: "/x/sub/a.txt"), name: "sub/a.txt")
        let alsoNamedA = FileItem(url: URL(fileURLWithPath: "/x/a.txt"), name: "a.txt")
        let other = FileItem(url: URL(fileURLWithPath: "/x/other/b.txt"), name: "other/b.txt")
        let names = FileOperations.names(
            of: [URL(fileURLWithPath: "/x/sub/a.txt"), URL(fileURLWithPath: "/x/other/b.txt")],
            among: [inFolder, alsoNamedA, other]
        )
        #expect(names == ["sub/a.txt", "other/b.txt"])
        #expect(FileOperations.names(of: [], among: [inFolder]).isEmpty)
    }
}
