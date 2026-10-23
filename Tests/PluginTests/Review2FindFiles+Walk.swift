import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FindFilesPlugin

/// The walk of Find Files: hits as they come, a memory budget, cancelling, the result limit, found items.
extension Review2FindFiles {
    /// The first hits of a folder are reported while its last files are still being tested.
    @Test
    internal func hitsOfAFolderComeBeforeItsLastFilesAreTested() {
        // 70 files; the tests of the last ones wait until the first hits have been reported.
        for index in 0..<70 {
            memory.addFile(String(format: "/many/f%02d.txt", index))
        }
        let release = DispatchSemaphore(value: 0)
        let columns = ColumnRegistry()
        columns.register(
            ContentColumn(id: "gate", title: "Gate") { item in
                if item.name >= "f64" {
                    _ = release.wait(timeout: .now() + Wait.ceiling)
                }
                return "open"
            }
        )
        var query = SearchQuery(directory: memory.url("/many"))
        query.fieldRules = FieldRules(isEnabled: true, rules: [FieldRule("gate", .equals, "open")])
        let search = FileSearch(query, fileSystems: fileSystems, columns: columns)
        let first = DispatchSemaphore(value: 0)
        // Counted by the thread that searches and read by the one that waits: under a lock.
        let lock = NSLock()
        // Guarded by `lock`.
        nonisolated(unsafe) var hits = 0
        let thread = Thread {
            search.run { _ in
                let isFirst = lock.withLock { () -> Bool in
                    hits += 1
                    return hits == 1
                }
                if isFirst {
                    first.signal()
                }
            }
        }
        thread.start()
        // The first hit arrives while the last files are still held back.
        let early = first.wait(timeout: .now() + Wait.ceiling) == .success
        for _ in 0..<8 {
            release.signal()
        }
        #expect(early)
        #expect(
            finishes(within: 600) {
                while lock.withLock({ hits }) < 70 {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        )
    }

    /// While the first file waits, the other threads list only a few folders ahead.
    @Test
    internal func aSlowFrontJobDoesNotLetTheOthersListTheWholeTree() {
        for folder in 0..<200 {
            for file in 0..<10 {
                memory.addFile(String(format: "/wide/d%03d/f%d.txt", folder, file))
            }
        }
        let release = DispatchSemaphore(value: 0)
        let columns = ColumnRegistry()
        columns.register(
            ContentColumn(id: "gate", title: "Gate") { item in
                if item.url.path == "/wide/d000/f0.txt" {
                    _ = release.wait(timeout: .now() + Wait.ceiling)
                }
                return "open"
            }
        )
        var query = SearchQuery(directory: memory.url("/wide"))
        query.fieldRules = FieldRules(isEnabled: true, rules: [FieldRule("gate", .equals, "open")])
        let search = FileSearch(
            query,
            fileSystems: fileSystems,
            columns: columns,
            now: Date(),
            tuning: .init(budget: 30)
        )
        // Written by the other thread before it signals, read here after the wait.
        nonisolated(unsafe) var count = 0
        let done = DispatchSemaphore(value: 0)
        Thread {
            search.run { _ in count += 1 }
            done.signal()
        }
        .start()
        // While the first folder's test is held, the other threads read a few folders ahead and then wait.
        Thread.sleep(forTimeInterval: 1)
        let listed = memory.listRequests.filter { $0.hasPrefix("/wide/d") }.count
        #expect(listed < 100)
        release.signal()
        // The 2,000 files and the 200 folders.
        #expect(done.wait(timeout: .now() + Wait.ceiling) == .success && count == 2_200)
    }

    /// A text search cancelled at any moment of its run ends.
    @Test
    internal func cancellingAContentSearchWhileItRunsIsSafe() {
        for folder in 0..<12 {
            for file in 0..<40 {
                memory.addFile("/tree/d\(folder)/f\(file).txt", String(repeating: "lorem ipsum ", count: 50))
            }
        }
        for round in 0..<20 {
            var query = SearchQuery(directory: memory.url("/tree"), text: "needle-\(round)")
            query.fieldRules = FieldRules(isEnabled: true, rules: [FieldRule("tc.size", .greater, "1")])
            let search = FileSearch(query, fileSystems: fileSystems)
            Thread {
                Thread.sleep(forTimeInterval: Double(round) / 2_000)
                search.cancel()
            }
            .start()
            #expect(
                finishes {
                    search.run { _ in
                        // Only the end counts.
                    }
                }
            )
        }
    }

    /// A walk stopped at the result limit reports no more; without the limit everything is found.
    @Test
    internal func aWalkThatIsClosedDoesNotComeBackToLife() {
        for index in 0..<30 {
            memory.addFile("/deep/a/b/c/d\(index)/e.txt", "x")
        }
        var query = SearchQuery(directory: memory.url("/deep"))
        query.resultLimit = 5
        let search = FileSearch(query, fileSystems: fileSystems)
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var found = 0
        #expect(finishes { search.run { _ in found += 1 } })
        #expect(found == 5 && search.reachedResultLimit)
        var all = SearchQuery(directory: memory.url("/deep"))
        all.resultLimit = 1_000
        let complete = FileSearch(all, fileSystems: fileSystems)
        var every = 0
        complete.run { _ in every += 1 }
        #expect(every > 30 && !complete.reachedResultLimit)
    }

    /// A search in 3,300 found items ends in time and finds each file once, by its folder.
    @Test
    internal func searchInFoundFilesDoesNotCompareEveryItemWithEveryFolder() {
        var items: [URL] = []
        for folder in 0..<300 {
            items.append(memory.url("/found/d\(folder)"))
            for file in 0..<10 {
                memory.addFile("/found/d\(folder)/n\(file).txt")
                items.append(memory.url("/found/d\(folder)/n\(file).txt"))
            }
        }
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var query = SearchQuery(directory: memory.url("/found"), names: "n1.txt")
        query.scope = .only(items)
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var hits: [String] = []
        #expect(finishes { hits = names(of: query) })
        // A file listed beside the folder that holds it is found once, by the folder.
        #expect(hits.count == 300)
    }
}
