import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FindFilesPlugin

/// "Find duplicate files": by name, size and contents, in groups, on all cores, and cancelled.
@Suite
internal struct Duplicates {
    /// The file systems the searches go through: the local disk and `memory`.
    internal let fileSystems: FileSystemRegistry
    /// A file system in memory with copies, files of one size and a single file.
    internal let memory: MemoryFileSystem

    /// The file systems of a test, with the files to compare.
    internal init() {
        (fileSystems, memory) = makeFileSystems()
        memory.addFile("/d/A/copy.txt", "same content")
        memory.addFile("/d/B/copy.txt", "same content")
        memory.addFile("/d/C/COPY.TXT", "other content")
        memory.addFile("/d/A/alpha.bin", "12345")
        memory.addFile("/d/B/beta.bin", "12345")
        memory.addFile("/d/B/gamma.bin", "54321")
        memory.addFile("/d/C/single.txt", "only one of its kind")
    }

    /// The groups of paths a search of `/d` with `options` finds.
    internal func groups(_ options: DuplicateOptions) -> [[String]] {
        var query = SearchQuery(directory: memory.url("/d"))
        query.duplicates = options
        return FileSearch(query, fileSystems: fileSystems).runForDuplicates().map { $0.map(\.url.path) }
    }

    /// By name and size, and by name alone, without regard to case.
    @Test
    internal func sameNameAndSize() {
        #expect(groups(DuplicateOptions(isEnabled: true)) == [["/d/A/copy.txt", "/d/B/copy.txt"]])
        #expect(
            groups(DuplicateOptions(isEnabled: true, sameName: true, sameSize: false))
                == [["/d/A/copy.txt", "/d/B/copy.txt", "/d/C/COPY.TXT"]]
        )
    }

    /// Groups by size come in the order of their sizes.
    @Test
    internal func sameSizeGroupsAreOrderedBySize() {
        #expect(
            groups(DuplicateOptions(isEnabled: true, sameName: false, sameSize: true))
                == [["/d/A/alpha.bin", "/d/B/beta.bin", "/d/B/gamma.bin"], ["/d/A/copy.txt", "/d/B/copy.txt"]]
        )
    }

    /// Equal contents are told by their digests, alone or with the name.
    @Test
    internal func sameContentsIsDecidedByHashing() {
        #expect(
            groups(DuplicateOptions(isEnabled: true, sameName: false, sameSize: false, sameContents: true))
                == [["/d/A/alpha.bin", "/d/B/beta.bin"], ["/d/A/copy.txt", "/d/B/copy.txt"]]
        )
        #expect(
            groups(DuplicateOptions(isEnabled: true, sameName: true, sameSize: false, sameContents: true))
                == [["/d/A/copy.txt", "/d/B/copy.txt"]]
        )
        #expect(
            DuplicateFinder.digest(
                of: memory.url("/d/A/copy.txt"),
                fileSystems: fileSystems,
                cancellation: CancellationFlag()
            )
                == DuplicateFinder.digest(
                    of: memory.url("/d/B/copy.txt"),
                    fileSystems: fileSystems,
                    cancellation: CancellationFlag()
                )
        )
        #expect(
            DuplicateFinder.digest(
                of: memory.url("/d/gone"),
                fileSystems: fileSystems,
                cancellation: CancellationFlag()
            ) == nil
        )
    }

    /// With no sub-criterion ticked the option is off and finds nothing.
    @Test
    internal func noSubCriterionSwitchesTheOptionOff() {
        let none = DuplicateOptions(isEnabled: true, sameName: false, sameSize: false, sameContents: false)
        #expect(!none.isActive && groups(none).isEmpty)
        #expect(!DuplicateOptions().isActive)
    }

    /// Many files are hashed on all cores, the progress counted once per file.
    @Test
    internal func manyFilesAreHashedOnAllCores() throws {
        let box = try Sandbox()
        for index in 0..<240 {
            try box.file(
                String(format: "set%d/file%03d.dat", index % 2, index),
                "payload \(index / 2 % 40)".padding(toLength: 16, withPad: " ", startingAt: 0)
            )
        }
        var query = SearchQuery(directory: box.root)
        query.duplicates = DuplicateOptions(isEnabled: true, sameName: false, sameSize: true, sameContents: true)
        // Used by the callbacks, which run one at a time while the calls below wait for them.
        nonisolated(unsafe) var steps: [Int] = []
        let found = FileSearch(query, fileSystems: fileSystems)
            .runForDuplicates(
                onDirectory: { _ in
                    // The folders do not matter here.
                },
                onHashing: { done, total in
                    steps.append(done)
                    #expect(total == 240)
                }
            )
        #expect(found.count == 40 && found.allSatisfy { $0.count == 6 })
        #expect(steps == Array(1...240))
        #expect(found.allSatisfy { group in group.map(\.url.path) == group.map(\.url.path).sorted() })
    }

    /// A cancelled run shows no groups.
    @Test
    internal func aCancelledRunShowsNothing() {
        var query = SearchQuery(directory: memory.url("/d"))
        query.duplicates = DuplicateOptions(isEnabled: true, sameName: false, sameSize: false, sameContents: true)
        let search = FileSearch(query, fileSystems: fileSystems)
        search.cancel()
        #expect(search.runForDuplicates().isEmpty)
        let items = ["/d/A/copy.txt", "/d/B/copy.txt"].compactMap { memory.item(at: memory.url($0)) }
        let cancelled = CancellationFlag()
        cancelled.cancel()
        #expect(
            DuplicateFinder.groups(
                of: items,
                options: query.duplicates,
                fileSystems: fileSystems,
                cancellation: cancelled
            )
            .isEmpty
        )
        #expect(DuplicateFinder.groups(of: items, options: query.duplicates, fileSystems: fileSystems).count == 1)
    }
}
