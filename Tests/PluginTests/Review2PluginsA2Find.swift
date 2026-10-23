import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FindFilesPlugin

/// Round 2 of the review, second pass, Find Files: folders that are listed in parts, and a share mounted twice.
@Suite
internal struct Review2PluginsA2Find {
    /// A folder of many files listed in parts reports its first hit long before its listing ends, each part in
    /// name order.
    @Test
    internal func aFolderOfManyFilesReportsItsFirstHitBeforeTheListingEnds() {
        let (fileSystems, memory) = makeFileSystems()
        for index in 0..<60 {
            memory.addFile(String(format: "/huge/f%02d.txt", index))
        }
        memory.listBatchSize = 10
        memory.listBatchDelay = 0.2
        let search = FileSearch(
            SearchQuery(directory: memory.url("/huge")),
            fileSystems: fileSystems,
            tuning: .init(partialListingAfter: 10)
        )
        let began = Date()
        // Written by the other thread before it signals, read here after the wait.
        nonisolated(unsafe) var firstAt: TimeInterval?
        // Written by the other thread before it signals, read here after the wait.
        nonisolated(unsafe) var found: [String] = []
        let done = DispatchSemaphore(value: 0)
        Thread {
            search.run { hit in
                if firstAt == nil {
                    firstAt = Date().timeIntervalSince(began)
                }
                found.append(hit.name)
            }
            done.signal()
        }
        .start()
        #expect(done.wait(timeout: .now() + Wait.ceiling) == .success)
        let total = Date().timeIntervalSince(began)
        // Five pauses of 0.2 s lie between the first batch and the last.
        #expect((firstAt ?? total) < total - 0.5)
        #expect(found.count == 60 && Set(found).count == 60)
        // Each part is in name order.
        #expect(found == found.sorted())
    }

    /// A folder listed in parts still gives every file that passes the tests, each once.
    @Test
    internal func aFolderListedInPartsStillGivesEveryHitOfTheTestsInOrderOfParts() {
        let (fileSystems, memory) = makeFileSystems()
        for index in 0..<45 {
            memory.addFile(String(format: "/parts/%@%02d.txt", index.isMultiple(of: 2) ? "a" : "b", index))
        }
        memory.listBatchSize = 7
        var query = SearchQuery(directory: memory.url("/parts"))
        query.names = "a*"
        var found: [String] = []
        let search = FileSearch(query, fileSystems: fileSystems, tuning: .init(partialListingAfter: 7))
        search.run { found.append($0.name) }
        #expect(
            Set(found) == Set((0..<45).filter { $0.isMultiple(of: 2) }.map { String(format: "a%02d.txt", $0) })
                && found.count == 23
        )
    }

    /// One share mounted at two mount points is one place to the duplicate search; another share is not.
    @Test
    internal func oneShareMountedTwiceIsOnePlace() {
        let first = DuplicateFinder.Mount(source: "smbfs://me@server/share", mountPoint: "/Volumes/share")
        let second = DuplicateFinder.Mount(source: "smbfs://me@server/share", mountPoint: "/Volumes/share-1")
        #expect(first.place(of: "/Volumes/share/docs/a.txt") == second.place(of: "/Volumes/share-1/docs/a.txt"))
        #expect(first.place(of: "/Volumes/share/docs/a.txt") != first.place(of: "/Volumes/share/docs/b.txt"))
        let other = DuplicateFinder.Mount(source: "smbfs://me@server/other", mountPoint: "/Volumes/other")
        #expect(other.place(of: "/Volumes/other/docs/a.txt") != first.place(of: "/Volumes/share/docs/a.txt"))
    }
}
